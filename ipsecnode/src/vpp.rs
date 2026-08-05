//! VPP data-plane management for fleetnode (Increment 6d).
//!
//! # Interface topology
//!
//! Two tap interfaces are created once at ipsecnode startup:
//!
//!   vpp-inner (kernel) / tap0 (VPP): NAT inside  -- customer inner traffic
//!   vpp-outer (kernel) / tap1 (VPP): NAT outside -- backend-facing traffic
//!
//! IP addresses for reliable VPP next-hop routing:
//!   vpp-inner kernel side: 10.255.0.1/30   VPP tap0 side: 10.255.0.2/30
//!   vpp-outer kernel side: 10.255.0.5/30   VPP tap1 side: 10.255.0.6/30
//!
//! VPP FIB (global):
//!   0.0.0.0/0           via 10.255.0.5 tap1    (forward path: SNAT'd traffic out)
//!   <internal_ip>/32    via 10.255.0.1 tap0    (return path: DNAT'd traffic in)
//!
//! # Forward data path (per-tunnel)
//!   StrongSwan xfrm decap --> inner pkt: src=192.168.13.133, dst=backend
//!   Linux policy rule: from 192.168.13.133/32 lookup 200
//!   Table 200 default:  dev vpp-inner
//!   VPP receives on tap0 (inside), applies SNAT: src -> global_ip
//!   VPP routes via tap1 (default); kernel forwards to backend via ens5
//!
//! # Return data path (per-tunnel)
//!   Backend reply: src=backend, dst=global_ip
//!   Kernel route: global_ip/32 dev vpp-outer  (upgraded from blackhole by 6d)
//!   VPP receives on tap1 (outside), applies DNAT: dst -> internal_ip
//!   VPP routes via tap0 (per-device route); kernel forwards into xfrm tunnel

use std::collections::HashMap;
use std::time::Duration;

use anyhow::{Context, Result};
use redis::AsyncCommands;
use tracing::{debug, info, warn};

use crate::nat::{NAT_PREFIX, NatRecord};

// -- Constants -----------------------------------------------------------------

const VPPCTL: &str = "/usr/bin/vppctl";

/// Kernel-side name of the NAT-inside tap interface.
pub const VPP_INNER_KERNEL: &str = "vpp-inner";
/// Kernel-side name of the NAT-outside tap interface.
pub const VPP_OUTER_KERNEL: &str = "vpp-outer";

/// Kernel-side IP on the inner tap (next-hop for VPP return-path routes).
/// Reserved for future use when manual VPP FIB entries are needed.
#[allow(dead_code)]
const INNER_KERNEL_IP: &str = "10.255.0.1";
const INNER_ADDR: &str = "10.255.0.1/30";
/// VPP-side IP on the inner tap.
/// Used as the kernel's gateway for table-200 routes so the kernel ARPs for
/// VPP (which responds) rather than for the final destination (which doesn't).
const INNER_VPP_IP:  &str = "10.255.0.2";
const INNER_VPP_ADDR: &str = "10.255.0.2/30";

/// Kernel-side IP on the outer tap (next-hop for VPP forward-path default route).
const OUTER_KERNEL_IP: &str = "10.255.0.5";
const OUTER_ADDR: &str = "10.255.0.5/30";
/// VPP-side IP on the outer tap.
const OUTER_VPP_ADDR: &str = "10.255.0.6/30";

/// Linux policy routing table number used for inner-traffic interception.
/// Traffic from a customer internal IP is sent to this table, which routes
/// it to vpp-inner for VPP NAT processing.
const VPP_INNER_TABLE: u32 = 200;

/// How long to wait for VPP to be ready at startup before giving up.
const VPP_READY_TIMEOUT_SECS: u64 = 30;

// -- VppTaps -------------------------------------------------------------------

/// VPP-side interface names for the two tap interfaces.
/// Assigned by VPP sequentially (e.g., "tap0" and "tap1").
#[derive(Debug, Clone)]
pub struct VppTaps {
	/// VPP interface name for the inside (customer) tap, e.g., "tap0".
	#[allow(dead_code)]
	pub inner: String,
	/// VPP interface name for the outside (backend) tap, e.g., "tap1".
	/// Retained for logging and future vppctl calls that reference the VPP-side name.
	#[allow(dead_code)]
	pub outer: String,
}

// -- Per-peer VPP state (cache) ------------------------------------------------

/// Device entry cached in memory for one peer.
#[derive(Debug, Clone)]
pub struct VppDeviceEntry {
	pub internal_ip: String,
	pub global_ip:   String,
}

/// VPP state held per peer (one VPN site).
pub struct VppPeerState {
	/// Devices whose NAT mappings are currently installed in VPP.
	pub devices:        Vec<VppDeviceEntry>,
	/// Number of active CHILD_SAs for this peer (re-keying safety counter).
	pub child_sa_count: u32,
}

/// In-memory VPP state map: peer_ip -> active state.
/// Owned by `event_listener_task`; not shared across threads.
pub type VppCache = HashMap<String, VppPeerState>;

// -- vppctl helpers ------------------------------------------------------------

/// Run a vppctl command and return trimmed stdout.
/// VPP sometimes exits 0 but writes an error to stdout (e.g., "unknown input").
/// Both the exit-code path and the inline-error path are treated as failures.
async fn vppctl(args: &[&str]) -> Result<String> {
	let out = tokio::process::Command::new(VPPCTL)
		.args(args)
		.output()
		.await
		.with_context(|| format!("failed to spawn vppctl {}", args.join(" ")))?;

	let stdout = String::from_utf8_lossy(&out.stdout).trim().to_string();
	let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();

	if !out.status.success() {
		anyhow::bail!(
			"vppctl {} failed (exit {}): stderr={} stdout={}",
			args.join(" "), out.status, stderr, stdout,
		);
	}

	// VPP returns exit 0 but writes diagnostic errors in stdout.
	if stdout.starts_with("unknown input")
		|| stdout.starts_with("Failed:")
		|| stdout.contains("is not a valid value")
	{
		anyhow::bail!("vppctl {} returned error: {}", args.join(" "), stdout);
	}

	Ok(stdout)
}

/// Wait for VPP to be ready by polling `vppctl show version`.
/// Returns Ok(()) when VPP responds, Err if the timeout expires.
async fn wait_for_vpp() -> Result<()> {
	let deadline = tokio::time::Instant::now() + Duration::from_secs(VPP_READY_TIMEOUT_SECS);
	loop {
		let result = tokio::process::Command::new(VPPCTL)
			.args(["show", "version"])
			.output()
			.await;

		match result {
			Ok(out) if out.status.success() => {
				let ver = String::from_utf8_lossy(&out.stdout);
				info!("VPP ready: {}", ver.lines().next().unwrap_or("(no version)"));
				return Ok(());
			}
			_ => {
				if tokio::time::Instant::now() >= deadline {
					anyhow::bail!(
						"VPP did not become ready within {VPP_READY_TIMEOUT_SECS} s"
					);
				}
				debug!("VPP not ready yet -- retrying in 2 s");
				tokio::time::sleep(Duration::from_secs(2)).await;
			}
		}
	}
}

// -- ip helpers ----------------------------------------------------------------

/// Run an `ip` subcommand.  Failures are returned as errors.
async fn ip(args: &[&str]) -> Result<()> {
	let out = tokio::process::Command::new("ip")
		.args(args)
		.output()
		.await
		.with_context(|| format!("failed to spawn ip {}", args.join(" ")))?;

	if !out.status.success() {
		let stderr = String::from_utf8_lossy(&out.stderr);
		anyhow::bail!("ip {} failed: {}", args.join(" "), stderr.trim());
	}
	Ok(())
}

/// Same as `ip()` but treats failure as a warning (e.g., idempotent deletes).
async fn ip_warn(args: &[&str]) {
	if let Err(e) = ip(args).await {
		warn!("ip {} (non-fatal): {e:#}", args.join(" "));
	}
}

// -- Startup cleanup ---------------------------------------------------------

/// Remove any tap interfaces and NAT44 state left by a previous ipsecnode run.
/// Called at the start of init() to make startup idempotent.
/// All errors are ignored -- if VPP is fresh there is nothing to clean up.
async fn cleanup_stale_state() {
	// Disable NAT44 plugin first (clears mappings + interface assignments).
	let _ = vppctl(&["nat44", "plugin", "disable"]).await;

	// Parse `show interface` and delete every tap interface found.
	// ipsecnode is the only process that creates tap interfaces on these nodes,
	// so deleting all taps is safe.
	if let Ok(output) = vppctl(&["show", "interface"]).await {
		for line in output.lines() {
			let parts: Vec<&str> = line.split_whitespace().collect();
			// Each line: "<name> <sw_if_index> <state> ..."
			if parts.len() >= 2
				&& parts[0].starts_with("tap")
				&& parts[0] != "tap"
			{
				if let Ok(_idx) = parts[1].parse::<u32>() {
					let sw_if_index = parts[1];
					debug!(iface = parts[0], sw_if_index, "removing stale tap");
					let _ = vppctl(&["delete", "tap", "sw_if_index", sw_if_index]).await;
				}
			}
		}
	}

	// Remove stale kernel-side state (IPs, policy rules, routes).
	// These are all best-effort -- ignore errors for missing entries.
	ip_warn(&["addr", "flush", "dev", VPP_INNER_KERNEL]).await;
	ip_warn(&["addr", "flush", "dev", VPP_OUTER_KERNEL]).await;
}

// -- Startup initialisation ----------------------------------------------------

/// Initialize the VPP data plane.
///
/// Idempotent: any tap interfaces left by a previous ipsecnode run are
/// detected and removed before fresh ones are created.
/// Returns `Ok(Some(taps))` on success.
/// Returns `Ok(None)` if VPP is not available (degraded mode -- no data plane).
pub async fn init() -> Result<Option<VppTaps>> {
	// Wait for VPP to be ready.  If it doesn't start in time, run without VPP.
	if let Err(e) = wait_for_vpp().await {
		warn!("VPP not available: {e:#} -- running without VPP data plane");
		return Ok(None);
	}

	// Remove any tap interfaces and NAT44 state left by a previous run.
	cleanup_stale_state().await;

	let inner = match create_tap(VPP_INNER_KERNEL).await {
		Ok(n)  => n,
		Err(e) => {
			warn!("VPP tap create failed: {e:#} -- running without VPP data plane");
			return Ok(None);
		}
	};
	let outer = match create_tap(VPP_OUTER_KERNEL).await {
		Ok(n)  => n,
		Err(e) => {
			warn!("VPP tap create failed: {e:#} -- running without VPP data plane");
			return Ok(None);
		}
	};

	// Assign IPs on the VPP side of both taps.
	vppctl(&["set", "interface", "ip", "address", &inner, INNER_VPP_ADDR]).await
		.context("failed to set IP on inner tap (VPP side)")?;
	vppctl(&["set", "interface", "ip", "address", &outer, OUTER_VPP_ADDR]).await
		.context("failed to set IP on outer tap (VPP side)")?;

	// Bring both VPP interfaces up.
	vppctl(&["set", "interface", "state", &inner, "up"]).await
		.context("failed to bring inner tap up in VPP")?;
	vppctl(&["set", "interface", "state", &outer, "up"]).await
		.context("failed to bring outer tap up in VPP")?;

	// Assign IPs on the kernel side of both taps.
	ip(&["addr", "add", INNER_ADDR, "dev", VPP_INNER_KERNEL]).await
		.context("failed to set IP on vpp-inner (kernel side)")?;
	ip(&["addr", "add", OUTER_ADDR, "dev", VPP_OUTER_KERNEL]).await
		.context("failed to set IP on vpp-outer (kernel side)")?;

	// Bring both kernel interfaces up.
	ip(&["link", "set", VPP_INNER_KERNEL, "up"]).await?;
	ip(&["link", "set", VPP_OUTER_KERNEL, "up"]).await?;

	// VPP default route: all post-SNAT traffic exits via the outer tap.
	// Added BEFORE enabling NAT44 so the NAT plugin does not add a second
	// path to this entry (which would create ECMP and send half the traffic
	// back via vpp-inner).  Nexthop only, no interface name: VPP resolves
	// 10.255.0.5 via the connected 10.255.0.4/30 route on tap1.
	vppctl(&["ip", "route", "add", "0.0.0.0/0", "via", OUTER_KERNEL_IP]).await
		.context("failed to add VPP default route via outer tap")?;

	// Enable NAT44 with a reasonable session limit.
	vppctl(&["nat44", "plugin", "enable", "sessions", "65536"]).await
		.context("failed to enable NAT44")?;

	// Set NAT interface roles (inside + outside in one command -- VPP 26.x syntax).
	vppctl(&["set", "interface", "nat44", "in", &inner, "out", &outer]).await
		.context("failed to set NAT44 inside/outside interfaces")?;

	// Table 200 default route: inner traffic intercepted by policy rules
	// goes to VPP via the gateway 10.255.0.2 (VPP-side IP on tap0).
	// Using an explicit gateway prevents the kernel from ARPing for final
	// destinations on vpp-inner; instead it ARPs for VPP's own IP (which
	// VPP answers), then delivers the frame to VPP for NAT + forwarding.
	let table_str = VPP_INNER_TABLE.to_string();
	ip(&["route", "replace", "default",
		"via", INNER_VPP_IP, "dev", VPP_INNER_KERNEL,
		"table", &table_str]).await
		.context("failed to add table 200 default route to vpp-inner")?;

	info!(
		inner, outer,
		inner_kernel = VPP_INNER_KERNEL,
		outer_kernel = VPP_OUTER_KERNEL,
		"VPP NAT44 data plane initialised"
	);

	Ok(Some(VppTaps { inner, outer }))
}

/// Create a VPP tap interface with the given kernel-side name.
/// Returns the VPP-side interface name (e.g., "tap0").
/// VPP 26.x (TAPv2 / virtio): `create tap host-if-name <name>`
async fn create_tap(kernel_name: &str) -> Result<String> {
	let output = vppctl(&["create", "tap", "host-if-name", kernel_name]).await
		.with_context(|| format!("create tap host-if-name {kernel_name}"))?;

	let iface = output.trim().to_string();
	if iface.is_empty() {
		anyhow::bail!("VPP tap create returned empty interface name for kernel={kernel_name}");
	}
	info!(vpp_iface = %iface, %kernel_name, "VPP tap interface created");
	Ok(iface)
}

// -- Per-CHILD_SA handlers -----------------------------------------------------

/// Called on CHILD_SA UP.
///
/// Fetches the NAT record, installs VPP static NAT mappings, adds VPP
/// per-device return-path routes, and sets up Linux policy routing so
/// that inner traffic is intercepted by VPP.
/// Also upgrades each global_ip route from blackhole (6c) to dev vpp-outer
/// so that return traffic is received by VPP rather than dropped.
pub async fn on_child_up(
	conn:    &mut redis::aio::MultiplexedConnection,
	peer_ip: &str,
	taps:    &VppTaps,
	cache:   &mut VppCache,
) {
	// Re-keying: NAT entries already installed, just increment the refcount.
	if let Some(state) = cache.get_mut(peer_ip) {
		state.child_sa_count += 1;
		debug!(peer_ip, child_sa_count = state.child_sa_count,
			"VPP CHILD_SA UP: NAT already installed, incrementing refcount");
		return;
	}

	let record = match get_nat_record(conn, peer_ip).await {
		Some(r) => r,
		None    => return,
	};

	let mut installed = Vec::new();
	for entry in &record.device_nat {
		let int_ip = &entry.internal_ip;
		let glo_ip = &entry.global_ip;

		if let Err(e) = install_device_nat(taps, int_ip, glo_ip).await {
			warn!(peer_ip, int_ip, glo_ip, "VPP NAT install failed: {e:#}");
			continue;
		}

		info!(
			peer_ip,
			internal_ip = int_ip,
			global_ip   = glo_ip,
			"VPP: NAT mapping + routing installed"
		);
		installed.push(VppDeviceEntry {
			internal_ip: int_ip.clone(),
			global_ip:   glo_ip.clone(),
		});
	}

	if !installed.is_empty() {
		cache.insert(peer_ip.to_string(), VppPeerState {
			devices:        installed,
			child_sa_count: 1,
		});
	}
}

/// Called on CHILD_SA DOWN.
///
/// Decrements the active CHILD_SA count.  When the count reaches zero,
/// removes VPP NAT mappings, VPP return-path routes, and Linux policy rules.
/// The global_ip kernel route is removed by nat::on_child_down; no need
/// to explicitly delete it here.
pub async fn on_child_down(peer_ip: &str, taps: &VppTaps, cache: &mut VppCache) {
	let state = match cache.get_mut(peer_ip) {
		Some(s) => s,
		None    => {
			debug!(peer_ip, "VPP CHILD_SA DOWN: no cached state -- nothing to remove");
			return;
		}
	};

	state.child_sa_count = state.child_sa_count.saturating_sub(1);
	if state.child_sa_count > 0 {
		debug!(peer_ip, child_sa_count = state.child_sa_count,
			"VPP CHILD_SA DOWN: other CHILD_SAs still active, keeping NAT");
		return;
	}

	let devices = cache.remove(peer_ip).unwrap().devices;
	for d in &devices {
		if let Err(e) = remove_device_nat(taps, &d.internal_ip, &d.global_ip).await {
			warn!(peer_ip, internal_ip = %d.internal_ip, global_ip = %d.global_ip,
				"VPP NAT remove failed (may already be gone): {e:#}");
		} else {
			info!(peer_ip, internal_ip = %d.internal_ip, global_ip = %d.global_ip,
				"VPP: NAT mapping + routing removed");
		}
	}
}

// -- Per-device NAT install / remove ------------------------------------------

async fn install_device_nat(
	_taps:       &VppTaps,
	internal_ip: &str,
	global_ip:   &str,
) -> Result<()> {
	// 1. VPP static 1:1 NAT mapping (bidirectional: SNAT forward + DNAT return).
	//    VPP NAT automatically manages the FIB entries for the internal and
	//    external addresses -- do NOT add manual ip routes for internal_ip or
	//    global_ip in VPP, as that creates ECMP with the NAT-internal routes.
	vppctl(&[
		"nat44", "add", "static", "mapping",
		"local", internal_ip, "external", global_ip,
	]).await.context("VPP nat44 add static mapping")?;

	// 2. Linux policy rule: forward-path src=internal_ip --> table 200 --> vpp-inner.
	let int_prefix = format!("{internal_ip}/32");
	let table_str = VPP_INNER_TABLE.to_string();
	ip(&["rule", "add", "from", &int_prefix, "lookup", &table_str]).await
		.context("ip rule add from internal_ip")?;

	// 3. Upgrade global_ip kernel route: blackhole (6c) --> dev vpp-outer.
	//    nat::on_child_up installed a blackhole; replace it so return traffic
	//    reaches VPP instead of being dropped.
	let glo_prefix = format!("{global_ip}/32");
	ip(&["route", "replace", &glo_prefix, "dev", VPP_OUTER_KERNEL]).await
		.context("ip route replace global_ip dev vpp-outer")?;

	Ok(())
}

async fn remove_device_nat(
	_taps:       &VppTaps,
	internal_ip: &str,
	global_ip:   &str,
) -> Result<()> {
	// Revert global_ip route to blackhole so FRR signal remains until
	// nat::on_child_down deletes it entirely.
	ip_warn(&[
		"route", "replace", &format!("{global_ip}/32"), "type", "blackhole",
	]).await;

	let int_prefix = format!("{internal_ip}/32");

	// Remove Linux policy rule.
	let table_str = VPP_INNER_TABLE.to_string();
	ip_warn(&["rule", "del", "from", &int_prefix, "lookup", &table_str]).await;

	// Remove VPP NAT static mapping.
	// VPP NAT manages the internal FIB entries; no manual ip route del needed.
	if let Err(e) = vppctl(&[
		"nat44", "del", "static", "mapping",
		"local", internal_ip, "external", global_ip,
	]).await {
		warn!(internal_ip, global_ip, "VPP nat44 del static mapping: {e:#}");
	}

	Ok(())
}

// -- Valkey helper (mirrors nat.rs) --------------------------------------------

async fn get_nat_record(
	conn:    &mut redis::aio::MultiplexedConnection,
	peer_ip: &str,
) -> Option<NatRecord> {
	let key = format!("{NAT_PREFIX}{peer_ip}");
	let raw: redis::RedisResult<Option<String>> = conn.get(&key).await;
	match raw {
		Ok(Some(json)) => match serde_json::from_str(&json) {
			Ok(rec) => Some(rec),
			Err(e)  => { warn!(peer_ip, "cannot parse NAT record: {e}"); None }
		},
		Ok(None) => { debug!(peer_ip, "no NAT record in Valkey"); None }
		Err(e)   => { warn!(peer_ip, "Valkey GET {key} failed: {e}"); None }
	}
}
