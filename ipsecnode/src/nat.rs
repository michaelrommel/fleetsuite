//! NAT record types and FRR /32 blackhole route management (Increment 6c).
//!
//! # Valkey key schema
//!   fleetipsec:nat:<tunnel_gw_ip>
//!   JSON: {
//!     "device_nat": [
//!       {"internal_ip": "10.67.1.5",   "global_ip": "198.51.100.5"}
//!     ],
//!     "backend_nat": [                          // optional
//!       {"customer_view_ip": "10.67.250.250", "real_ip": "194.138.39.18"}
//!     ]
//!   }
//!
//! # Route lifecycle
//!   CHILD_SA UP   -> ip route replace blackhole <global_ip>/32   (per device)
//!   CHILD_SA DOWN -> ip route del blackhole <global_ip>/32        (per device)
//!
//! FRR's `redistribute static route-map EXPORT-CUSTOMER` picks up the kernel
//! static routes and advertises them as /32 BGP prefixes to the Return GW.
//!
//! # Re-keying safety
//! A `PeerRouteState` tracks how many CHILD_SAs are currently active for each
//! peer.  Routes are only removed when the count drops to zero, so a brief
//! overlap during IKE re-keying (new CHILD_SA UP before old one goes DOWN)
//! never prematurely withdraws the BGP advertisement.

use std::collections::HashMap;

use anyhow::{Context, Result};
use redis::AsyncCommands;
use serde::Deserialize;
use tracing::{debug, info, warn};

// ── Valkey key prefix ─────────────────────────────────────────────────────────

pub const NAT_PREFIX: &str = "fleetipsec:nat:";

// ── Valkey record types ───────────────────────────────────────────────────────

/// Deserialized value of fleetipsec:nat:<peer_ip>.
#[derive(Debug, Deserialize)]
pub struct NatRecord {
	/// Per-device SNAT mappings: internal device IP -> globally routable IP.
	/// One /32 blackhole route is installed per entry (Increment 6c).
	/// VPP SNAT rules are built from these entries (Increment 6d).
	pub device_nat: Vec<DeviceNatEntry>,
	/// Optional per-backend DNAT mappings: customer's view of a backend IP
	/// -> the real backend IP.  Absent when the customer uses real addresses.
	/// Used by VPP DNAT only (Increment 6d); ignored in Increment 6c.
	#[serde(default)]
	#[allow(dead_code)]
	pub backend_nat: Vec<BackendNatEntry>,
}

#[derive(Debug, Deserialize, Clone)]
#[allow(dead_code)]
pub struct DeviceNatEntry {
	/// Customer device's internal (LAN) IP address.
	pub internal_ip: String,
	/// Globally routable IP mapped to this device.
	/// Advertised as a /32 BGP route via FRR; used as VPP SNAT source.
	pub global_ip: String,
}

#[derive(Debug, Deserialize, Clone)]
#[allow(dead_code)]
pub struct BackendNatEntry {
	/// IP address the customer uses to reach the backend (their view).
	pub customer_view_ip: String,
	/// Real backend IP address (our infrastructure).
	pub real_ip: String,
}

// ── Per-peer route state ──────────────────────────────────────────────────────

/// Route state held in memory for one peer (one VPN site).
/// Keyed by peer_ip in `RouteCache`.
pub struct PeerRouteState {
	/// Global IPs whose /32 blackhole routes are currently installed.
	pub global_ips: Vec<String>,
	/// Number of active CHILD_SAs for this peer.
	/// Routes are removed only when this drops to zero.
	pub child_sa_count: u32,
}

/// In-memory map: peer_ip -> active route state.
/// Owned by `event_listener_task`; not shared across threads.
pub type RouteCache = HashMap<String, PeerRouteState>;

// ── Valkey helper ─────────────────────────────────────────────────────────────

/// Fetch and deserialize the NAT record for `peer_ip` from Valkey.
/// Returns `None` if the key does not exist or the JSON cannot be parsed.
pub async fn get_nat_record(
	conn:    &mut redis::aio::MultiplexedConnection,
	peer_ip: &str,
) -> Option<NatRecord> {
	let key = format!("{NAT_PREFIX}{peer_ip}");
	let raw: redis::RedisResult<Option<String>> = conn.get(&key).await;
	match raw {
		Ok(Some(json)) => match serde_json::from_str(&json) {
			Ok(rec) => Some(rec),
			Err(e)  => {
				warn!(peer_ip, "cannot parse NAT record JSON: {e}");
				None
			}
		},
		Ok(None) => {
			debug!(peer_ip, "no NAT record in Valkey -- route management skipped");
			None
		}
		Err(e) => {
			warn!(peer_ip, "Valkey GET {key} failed: {e}");
			None
		}
	}
}

// ── Kernel route helpers ──────────────────────────────────────────────────────

/// Install a /32 blackhole route for `global_ip`.
/// Uses `ip route replace` so it is idempotent if the route already exists
/// (e.g. during IKE re-keying when the new CHILD_SA comes UP before the old
/// one goes DOWN).
async fn route_add(global_ip: &str) -> Result<()> {
	let prefix = format!("{global_ip}/32");
	let out = tokio::process::Command::new("ip")
		.args(["route", "replace", "blackhole", &prefix])
		.output()
		.await
		.context("failed to spawn `ip route replace`")?;

	if !out.status.success() {
		let stderr = String::from_utf8_lossy(&out.stderr);
		anyhow::bail!("`ip route replace blackhole {prefix}` failed: {stderr}");
	}
	Ok(())
}

/// Remove the /32 route for `global_ip`, regardless of route type.
/// After Increment 6d the route is `dev vpp-outer` (not blackhole), so we
/// omit the type specifier to handle both cases cleanly.
/// A missing route (already gone) is logged as a warning, not an error.
async fn route_del(global_ip: &str) -> Result<()> {
	let prefix = format!("{global_ip}/32");
	let out = tokio::process::Command::new("ip")
		.args(["route", "del", &prefix])
		.output()
		.await
		.context("failed to spawn `ip route del`")?;

	if !out.status.success() {
		let stderr = String::from_utf8_lossy(&out.stderr);
		// "No such process" is what iproute2 returns for a missing route.
		if stderr.contains("No such process") || stderr.contains("RTNETLINK answers") {
			warn!(global_ip, "route already absent on teardown (ok)");
			return Ok(());
		}
		anyhow::bail!("`ip route del blackhole {prefix}` failed: {stderr}");
	}
	Ok(())
}

// ── Public event handlers ─────────────────────────────────────────────────────

/// Called on CHILD_SA UP.
///
/// Fetches the NAT record from Valkey, installs a /32 blackhole route for
/// each `global_ip`, and increments the active CHILD_SA count for this peer.
/// If no NAT record exists the function is a no-op (not all sites have
/// NAT mappings configured yet).
pub async fn on_child_up(
	conn:    &mut redis::aio::MultiplexedConnection,
	peer_ip: &str,
	cache:   &mut RouteCache,
) {
	// If routes are already installed for this peer (concurrent CHILD_SAs or
	// re-keying), just increment the count -- routes are already in the kernel.
	if let Some(state) = cache.get_mut(peer_ip) {
		state.child_sa_count += 1;
		debug!(
			peer_ip,
			child_sa_count = state.child_sa_count,
			"CHILD_SA UP: routes already installed, incrementing refcount"
		);
		return;
	}

	let record = match get_nat_record(conn, peer_ip).await {
		Some(r) => r,
		None    => return,
	};

	let mut installed = Vec::new();
	for entry in &record.device_nat {
		match route_add(&entry.global_ip).await {
			Ok(()) => {
				info!(
					peer_ip,
					global_ip   = %entry.global_ip,
					internal_ip = %entry.internal_ip,
					"installed /32 blackhole route (FRR will advertise via BGP)"
				);
				installed.push(entry.global_ip.clone());
			}
			Err(e) => {
				warn!(peer_ip, global_ip = %entry.global_ip, "failed to add /32 route: {e:#}");
			}
		}
	}

	if !installed.is_empty() {
		cache.insert(peer_ip.to_string(), PeerRouteState {
			global_ips:      installed,
			child_sa_count:  1,
		});
	}
}

/// Called on CHILD_SA DOWN.
///
/// Decrements the active CHILD_SA count for this peer.  Routes are only
/// removed once the count reaches zero (last CHILD_SA gone).
pub async fn on_child_down(peer_ip: &str, cache: &mut RouteCache) {
	let state = match cache.get_mut(peer_ip) {
		Some(s) => s,
		None    => {
			debug!(peer_ip, "CHILD_SA DOWN: no cached routes -- nothing to remove");
			return;
		}
	};

	state.child_sa_count = state.child_sa_count.saturating_sub(1);
	if state.child_sa_count > 0 {
		debug!(
			peer_ip,
			child_sa_count = state.child_sa_count,
			"CHILD_SA DOWN: other CHILD_SAs still active, keeping routes"
		);
		return;
	}

	// Count reached zero -- remove routes and clear the cache entry.
	let global_ips = cache.remove(peer_ip).unwrap().global_ips;
	for global_ip in &global_ips {
		match route_del(global_ip).await {
			Ok(()) => info!(peer_ip, %global_ip, "removed /32 blackhole route"),
			Err(e) => warn!(peer_ip, %global_ip, "failed to remove /32 route: {e:#}"),
		}
	}
}
