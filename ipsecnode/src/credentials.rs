//! Credential management: PSK loading from Valkey and incremental updates.
//!
//! # Valkey key schema (from AGENTS.md Architecture Decision #12)
//!
//!   fleetipsec:psk:<site_public_ip>
//!     PSK string (plain text)
//!
//!   fleetipsec:site:<site_public_ip>
//!     JSON: {
//!       "mapped_global_ip": "...",
//!       "customer_id":      "...",
//!       "ike_identity":     "..."   // optional; see Architecture Decision #13
//!     }
//!
//! # VICI load-shared payload (one per site)
//!   id:     "psk-<site_public_ip>"
//!   type:   "IKE"
//!   data:   <PSK bytes>
//!   owners: [<site_public_ip>]       -- always
//!           + [<ike_identity>]         -- if site record has ike_identity
//!
//! # Keyspace notifications
//! Valkey keyspace events (KEg$) are enabled at startup.
//! The pubsub listener subscribes to __keyevent@0__:set and __keyevent@0__:del
//! and reacts to changes on fleetipsec:psk:* and fleetipsec:site:* keys.

use std::time::Duration;

use anyhow::{Context, Result};
use redis::{AsyncCommands, RedisResult};
use serde::Deserialize;
use futures_util::StreamExt as _;
use tracing::{debug, error, info, warn};

use crate::vici::{self, Client};

use crate::proposals::{self, OneOrMany};

// ── Key schema constants ──────────────────────────────────────────────────────

pub const PSK_PREFIX:    &str = "fleetipsec:psk:";
pub const SITE_PREFIX: &str = "fleetipsec:site:";

/// Keyevent channel patterns for psubscribe.
const KEYEVENT_SET: &str = "__keyevent@0__:set";
const KEYEVENT_DEL: &str = "__keyevent@0__:del";

// ── Device record ─────────────────────────────────────────────────────────────

/// JSON value stored at fleetipsec:site:<ip>.
///
/// Every device in Valkey receives an explicit per-site VICI load-conn.
/// There is NO catch-all fallback: any device not in Valkey cannot connect.
///
/// Crypto fields accept either a single value ("aes256") or a JSON array
/// (["aes256","aes128"]).  See proposals::OneOrMany for the serde handling
/// and proposals::build_ike_proposals / build_esp_proposals for translation
/// to StrongSwan proposal strings via cartesian product.
#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct SiteRecord {
	/// Globally-routable IP used by VPP 1:1 NAT for this device's traffic.
	/// REMOVED -- per-site NAT mappings are in fleetipsec:nat:<site_gw_ip>.
	/// Kept as Option so existing Valkey records that still contain it
	/// deserialise without error.  ipsecnode ignores the value.
	#[allow(dead_code)]
	pub mapped_global_ip: Option<String>,
	pub customer_id:      Option<String>,
	/// IKE identity for PSK owner registration (Architecture Decision #13).
	pub ike_identity:     Option<String>,

	/// true = device has a stable public IP; false = dynamic (CGNAT, etc.).
	/// Dynamic-IP devices use remote_addrs = "%any" in their connection.
	pub static_ip:    Option<bool>,
	/// Per-site NAT ownership (Option 1). 'backend' = we translate -> the VPP VRF
	/// path needs a return-path packet mark (mark_out = if_id). 'customer'/absent
	/// = VPP bypass; the return is routed straight to xfrm-{hex}, so mark_out is
	/// omitted and the SA is selected by if_id alone.
	pub nat_mode:     Option<String>,
	/// IKE protocol version: 1 or 2.  Absent = accept both (version=0).
	pub ike_version:  Option<u8>,

	// Phase 1 (IKE SA) crypto -- each field accepts single value or list.
	/// Encryption: "aes128", "aes192", "aes256".
	pub ike_enc:  Option<OneOrMany<String>>,
	/// Integrity/PRF: "sha256", "sha384", "sha512".
	pub ike_auth: Option<OneOrMany<String>>,
	/// DH group number(s): 1,2,5,14,15,16,19,20,21,24.
	pub ike_dh:   Option<OneOrMany<u16>>,

	// Phase 2 (CHILD SA / ESP) crypto -- each field accepts single value or list.
	/// Encryption: "aes128","aes192","aes256","aes128gcm","aes192gcm","aes256gcm".
	pub esp_enc:  Option<OneOrMany<String>>,
	/// HMAC: "sha256","sha384","sha512","none".
	pub esp_auth: Option<OneOrMany<String>>,
	/// PFS DH group number(s); 0 or absent = no PFS.
	pub esp_pfs:  Option<OneOrMany<u16>>,

	/// Customer-side traffic selectors (remote_ts in VICI terms).
	/// What the customer's network looks like on their side.
	/// Absent = ["0.0.0.0/0"].
	pub remote_ts: Option<Vec<String>>,

	/// VPN-node-side traffic selectors (local_ts in VICI terms).
	/// For customers that assign their own addresses to our backend servers
	/// this must match that customer-specific range (e.g. ["10.67.250.0/24"]).
	/// Absent = ["0.0.0.0/0"] -- correct before VPP NAT is active and for
	/// customers that use the global backend addresses directly.
	pub local_ts: Option<Vec<String>>,
}

// ── VICI PSK id ───────────────────────────────────────────────────────────────

/// Canonical VICI shared-secret identifier for a device.
fn psk_id(device_ip: &str) -> String {
	format!("psk-{device_ip}")
}

// ── Enable keyspace notifications ─────────────────────────────────────────────

/// Enable Valkey keyspace event notifications so the pubsub listener works.
/// KEg$: Keyspace + Keyevent, generic commands (DEL/EXPIRE) + string (SET).
///
/// On self-managed Redis/Valkey this succeeds immediately.
/// On AWS MemoryDB, CONFIG SET is blocked; keyspace events must be enabled
/// via a parameter group instead (see infrastructure/make_valkey_params.sh).
/// The failure is non-fatal: startup bulk-load is unaffected, and pubsub
/// will deliver events once the parameter group is applied to the cluster.
pub async fn enable_keyspace_notifications(
	conn: &mut redis::aio::MultiplexedConnection,
) -> Result<()> {
	let result: redis::RedisResult<()> = redis::cmd("CONFIG")
		.arg("SET")
		.arg("notify-keyspace-events")
		.arg("KEg$")
		.query_async(conn)
		.await;

	match result {
		Ok(()) => {
			info!("Valkey keyspace notifications enabled (KEg$)");
		}
		Err(e) if e.to_string().contains("unknown command") => {
			warn!(
				"CONFIG SET not supported on this Valkey endpoint (managed MemoryDB). \
				 Keyspace notifications must be enabled via the cluster parameter group \
				 (see infrastructure/make_valkey_params.sh). \
				 Startup bulk-load is unaffected; runtime PSK pubsub updates will not \
				 fire until the parameter group is applied."
			);
		}
		Err(e) => {
			return Err(e).context("CONFIG SET notify-keyspace-events failed");
		}
	}

	Ok(())
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Fetch the site record for `device_ip` from Valkey.
/// Returns None if the key does not exist or the JSON cannot be parsed.
async fn get_site_record(
	conn:      &mut redis::aio::MultiplexedConnection,
	device_ip: &str,
) -> Option<SiteRecord> {
	let key = format!("{SITE_PREFIX}{device_ip}");
	let raw: RedisResult<Option<String>> = conn.get(&key).await;
	match raw {
		Ok(Some(json)) => match serde_json::from_str(&json) {
			Ok(rec) => Some(rec),
			Err(e)  => {
				warn!(device_ip, "cannot parse site record JSON: {e}");
				None
			}
		},
		Ok(None) => None,
		Err(e)   => {
			warn!(device_ip, "Valkey GET {key} failed: {e}");
			None
		}
	}
}

/// Build the owners list for a device.
/// Always includes the site_public_ip; adds ike_identity if present.
fn build_owners(device_ip: &str, record: Option<&SiteRecord>) -> Vec<String> {
	let mut owners = vec![device_ip.to_string()];
	if let Some(rec) = record {
		if let Some(ref identity) = rec.ike_identity {
			owners.push(identity.clone());
		}
	}
	owners
}

// ── Bulk load ─────────────────────────────────────────────────────────────────

/// Scan all fleetipsec:psk:* keys in Valkey and load each PSK into charon
/// via VICI load-shared.  Returns the count of successfully loaded PSKs.
///
/// Called once at startup before the pubsub listener is started.
pub async fn bulk_load(
	vici_client:  &mut Client,
	valkey:       &mut redis::aio::MultiplexedConnection,
	local_ike_id: Option<&str>,
) -> Result<usize> {
	info!("scanning Valkey for {PSK_PREFIX}* keys ...");

	// SCAN with a MATCH pattern.  Use a cursor loop so we handle large
	// key-spaces without blocking the server.
	let mut cursor: u64 = 0;
	let pattern = format!("{PSK_PREFIX}*");
	let mut loaded = 0usize;
	let mut errors = 0usize;

	loop {
		let (next_cursor, keys): (u64, Vec<String>) = redis::cmd("SCAN")
			.arg(cursor)
			.arg("MATCH")
			.arg(&pattern)
			.arg("COUNT")
			.arg(100u32)
			.query_async(valkey)
			.await
			.context("Valkey SCAN failed")?;

		for key in keys {
			let device_ip = key
				.strip_prefix(PSK_PREFIX)
				.unwrap_or(&key)
				.to_string();

			match load_one_device(vici_client, valkey, &device_ip, local_ike_id).await {
				Ok(())  => loaded += 1,
				Err(e)  => {
					warn!(device_ip, "failed to load PSK: {e:#}");
					errors += 1;
				}
			}
		}

		cursor = next_cursor;
		if cursor == 0 {
			break;
		}
	}

	if errors > 0 {
		warn!(loaded, errors, "bulk PSK load completed with errors");
	} else {
		info!(loaded, "bulk PSK load complete");
	}

	Ok(loaded)
}

/// Load (or reload) the PSK and optional per-site connection for a
/// single device into charon.
///
/// Idempotent: VICI load-shared and load-conn replace any existing entries
/// with the same id/name, so this is safe to call on both initial bulk load
/// and on pubsub update events.
async fn load_one_device(
	vici_client:  &mut Client,
	valkey:       &mut redis::aio::MultiplexedConnection,
	device_ip:    &str,
	local_ike_id: Option<&str>,
) -> Result<()> {
	let psk_key = format!("{PSK_PREFIX}{device_ip}");
	let psk: Option<String> = valkey.get(&psk_key).await
		.with_context(|| format!("Valkey GET {psk_key} failed"))?;

	let psk = match psk {
		Some(p) => p,
		None    => {
			debug!(device_ip, "PSK key not found in Valkey -- skipping");
			return Ok(());
		}
	};

	let record = get_site_record(valkey, device_ip).await;
	let owners = build_owners(device_ip, record.as_ref());

	let id = psk_id(device_ip);
	vici::load_shared(vici_client, &id, &psk, owners)
		.await
		.with_context(|| format!("VICI load-shared for {device_ip} failed"))?;
	debug!(device_ip, %id, "PSK loaded into charon");

	// Per-device VICI connection (if any custom config is present).
	if let Some(ref rec) = record {
		info!(
			device_ip,
			static_ip     = ?rec.static_ip,
			has_ike_enc   = rec.ike_enc.is_some(),
			has_esp_enc   = rec.esp_enc.is_some(),
			has_remote_ts = rec.remote_ts.is_some(),
			"loading per-site VICI connection"
		);
		load_device_conn(vici_client, device_ip, rec, local_ike_id).await
			.with_context(|| format!("VICI load-conn for {device_ip} failed"))?;
	}

	Ok(())
}

/// Build remote_ts for a device: explicit list or default to accept-all.
fn device_remote_ts(rec: &SiteRecord) -> Vec<String> {
	rec.remote_ts
		.clone()
		.unwrap_or_else(|| vec!["0.0.0.0/0".to_string()])
}

/// Build local_ts for a device: explicit list (customer's view of our backends)
/// or default to accept-all.  VPP handles the actual NAT; the local_ts only
/// needs to be specific for customers that use custom backend addressing.
fn device_local_ts(rec: &SiteRecord) -> Vec<String> {
	rec.local_ts
		.clone()
		.unwrap_or_else(|| vec!["0.0.0.0/0".to_string()])
}

async fn load_device_conn(
	vici_client:  &mut Client,
	device_ip:    &str,
	rec:          &SiteRecord,
	local_ike_id: Option<&str>,
) -> Result<()> {
	let conn_name   = vici::conn_id(device_ip);
	let static_ip   = rec.static_ip.unwrap_or(false);
	let ike_version = rec.ike_version.unwrap_or(0);
	let remote_ts   = device_remote_ts(rec);
	let local_ts    = device_local_ts(rec);

	let ike_proposals = proposals::build_ike_proposals(rec);
	let esp_proposals = proposals::build_esp_proposals(rec);

	// Compute if_id = IPv4 address as u32 (Architecture Decision #15).
	// None if device_ip is not a valid IPv4 (should never happen in practice).
	let if_id: Option<u32> = device_ip
		.parse::<std::net::Ipv4Addr>()
		.ok()
		.map(u32::from);

	// Return-path packet mark: only the 'backend' (VPP VRF) path needs it -- the
	// nftables mangle sets it from the vpp-{hex} tap so the right tunnel is chosen
	// when two customers share an internal_ip. In 'customer' bypass mode the return
	// is routed straight to xfrm-{hex} (dst=global_ip/32), so the SA is selected by
	// the interface's if_id alone; a mark_out requirement would then never match.
	let mark_out: Option<u32> = if rec.nat_mode.as_deref() == Some("backend") { if_id } else { None };

	// Create the per-site XFRM interface before loading the connection so
	// it exists when StrongSwan installs the first XFRM state for this site.
	if let Some(id) = if_id {
		let xfrm_if = format!("xfrm-{id:08x}");
		create_xfrm_if(&xfrm_if, id).await;
	}

	debug!(device_ip, %conn_name, ?ike_proposals, ?esp_proposals,
		   if_id, "issuing VICI load-conn");

	vici::load_conn(
		vici_client,
		&conn_name,
		device_ip,
		static_ip,
		ike_version,
		rec.ike_identity.as_deref(),
		ike_proposals,
		esp_proposals,
		remote_ts,
		local_ts,
		if_id,
		mark_out,
		local_ike_id,
	)
	.await?;

	debug!(device_ip, %conn_name, "per-site connection loaded into charon");
	Ok(())
}

/// Remove the PSK and per-site connection for a site from charon.
async fn unload_one_device(
	vici_client: &mut Client,
	device_ip:   &str,
) -> Result<()> {
	let id = psk_id(device_ip);
	vici::unload_shared(vici_client, &id)
		.await
		.with_context(|| format!("VICI unload-shared for {device_ip} failed"))?;

	let conn_name = vici::conn_id(device_ip);
	if let Err(e) = vici::unload_conn(vici_client, &conn_name).await {
		debug!(device_ip, %conn_name, "unload-conn (may not have been loaded): {e:#}");
	}

	// Delete the per-site XFRM interface (best-effort; ignore if absent).
	if let Some(id) = device_ip.parse::<std::net::Ipv4Addr>().ok().map(u32::from) {
		let xfrm_if = format!("xfrm-{id:08x}");
		delete_xfrm_if(&xfrm_if).await;
	}

	debug!(device_ip, %id, "PSK and XFRM interface removed");
	Ok(())
}

// ── Pubsub task ───────────────────────────────────────────────────────────────

/// Long-running task: listens to Valkey keyevent notifications and updates
/// charon PSK state incrementally.
///
/// Reconnects automatically on connection loss (Valkey restart, blip).
///
/// `vici_cmd_client`: the command VICI connection.  Owned here for the
///                    lifetime of the task.
/// `valkey_client`:   used to open a fresh multiplex connection for reading
///                    PSK/device values on each credential change event.
/// `pubsub`:          the already-open pubsub connection from main().
pub async fn pubsub_task(
	mut vici_client: Client,
	valkey_client:   redis::Client,
	pubsub:          redis::aio::PubSub,
	local_ike_id:    Option<String>,
) {
	// First run uses the pubsub connection passed from main; on reconnect
	// we open a fresh one from valkey_client.
	let mut current_pubsub = Some(pubsub);

	loop {
		let ps = match current_pubsub.take() {
			Some(ps) => ps,
			None => {
				info!("reopening Valkey pubsub connection ...");
				match valkey_client.get_async_pubsub().await {
					Ok(ps)  => ps,
					Err(e)  => {
						error!("Valkey pubsub reconnect failed: {e} -- retry in 5 s");
						tokio::time::sleep(Duration::from_secs(5)).await;
						continue;
					}
				}
			}
		};

		match run_pubsub_loop(&mut vici_client, &valkey_client, ps, local_ike_id.as_deref()).await {
			Ok(())  => warn!("Valkey pubsub stream ended -- reconnecting in 5 s"),
			Err(e)  => error!("Valkey pubsub error: {e:#} -- reconnecting in 5 s"),
		}

		tokio::time::sleep(Duration::from_secs(5)).await;
	}
}

/// One pubsub connection lifetime.
async fn run_pubsub_loop(
	vici_client:   &mut Client,
	valkey_client: &redis::Client,
	mut pubsub:    redis::aio::PubSub,
	local_ike_id:  Option<&str>,
) -> Result<()> {
	// Subscribe to SET and DEL keyevent notifications for all keys.
	// We filter by prefix in the handler.
	pubsub.psubscribe(KEYEVENT_SET).await
		.context("psubscribe to keyevent set failed")?;
	pubsub.psubscribe(KEYEVENT_DEL).await
		.context("psubscribe to keyevent del failed")?;

	info!("Valkey keyevent pubsub active ({KEYEVENT_SET}, {KEYEVENT_DEL})");

	let mut stream = pubsub.on_message();

	while let Some(msg) = stream.next().await {
		// For pattern subscriptions the channel name is the keyevent type
		// (e.g. "__keyevent@0__:set") and the payload is the key name.
		let event_channel: String = match msg.get_channel() {
			Ok(c)  => c,
			Err(e) => { warn!("keyevent: cannot read channel: {e}"); continue; }
		};
		let key: String = match msg.get_payload() {
			Ok(k)  => k,
			Err(e) => { warn!("keyevent: cannot read payload: {e}"); continue; }
		};

		debug!(channel = %event_channel, %key, "Valkey keyevent");

		// Determine event type from the channel name.
		let is_set = event_channel.ends_with(":set");
		let is_del = event_channel.ends_with(":del")
			|| event_channel.ends_with(":expired");

		if key.starts_with(PSK_PREFIX) {
			let device_ip = &key[PSK_PREFIX.len()..];
			handle_psk_event(vici_client, valkey_client, device_ip, is_set, is_del, local_ike_id).await;
		} else if key.starts_with(SITE_PREFIX) {
			let device_ip = &key[SITE_PREFIX.len()..];
			// Device record changed: re-register the PSK with updated owners.
			// This handles ike_identity changes (Architecture Decision #13).
			handle_site_event(vici_client, valkey_client, device_ip, local_ike_id).await;
		}
		// Keys outside our namespaces are silently ignored.
	}

	Ok(())
}

// ── Event handlers ────────────────────────────────────────────────────────────

async fn handle_psk_event(
	vici_client:   &mut Client,
	valkey_client: &redis::Client,
	device_ip:     &str,
	is_set:        bool,
	is_del:        bool,
	local_ike_id:  Option<&str>,
) {
	if is_set {
		info!(device_ip, "PSK created/updated -- reloading into charon");
		match valkey_client.get_multiplexed_async_connection().await {
			Ok(mut conn) => {
				if let Err(e) = load_one_device(vici_client, &mut conn, device_ip, local_ike_id).await {
					error!(device_ip, "PSK reload failed: {e:#}");
				}
			}
			Err(e) => error!(device_ip, "Valkey connect for PSK reload failed: {e}"),
		}
	} else if is_del {
		info!(device_ip, "PSK deleted -- removing from charon");
		if let Err(e) = unload_one_device(vici_client, device_ip).await {
			warn!(device_ip, "PSK unload failed (may already be gone): {e:#}");
		}
	}
}

async fn handle_site_event(
	vici_client:   &mut Client,
	valkey_client: &redis::Client,
	device_ip:     &str,
	local_ike_id:  Option<&str>,
) {
	// Unload the old per-site connection first (if any), then reload.
	// This handles the case where a device loses its custom config fields
	// (needs_custom_conn() was true before, false after).
	let conn_name = vici::conn_id(device_ip);
	if let Err(e) = vici::unload_conn(vici_client, &conn_name).await {
		debug!(device_ip, "unload-conn on device update (may not have been loaded): {e:#}");
	}

	info!(device_ip, "site record updated -- refreshing PSK owners and connection");
	match valkey_client.get_multiplexed_async_connection().await {
		Ok(mut conn) => {
			if let Err(e) = load_one_device(vici_client, &mut conn, device_ip, local_ike_id).await {
				error!(device_ip, "PSK/conn refresh failed: {e:#}");
			}
		}
		Err(e) => error!(device_ip, "Valkey connect for device event failed: {e}"),
	}
}

// -- XFRM interface lifecycle (Architecture Decision #15) --------------------

/// Create the per-site XFRM kernel interface.
/// Idempotent: if the interface already exists the error is silently ignored
/// (handles ipsecnode restart without instance replacement).
async fn create_xfrm_if(xfrm_if: &str, if_id: u32) {
	let id_str = if_id.to_string();
	let out = tokio::process::Command::new("ip")
		.args(["link", "add", xfrm_if, "type", "xfrm",
		       "dev", "ens5", "if_id", &id_str])
		.output().await;

	match out {
		Ok(o) if o.status.success() => {
			// Bring the interface up.
			let _ = tokio::process::Command::new("ip")
				.args(["link", "set", xfrm_if, "up"])
				.output().await;
			// Set MTU to account for IPsec (AES-256-GCM) + UDP-NAT-T overhead
			// (~80 bytes).  1420 = 1500 - 80; allows clamp-mss-to-pmtu to
			// compute MSS = 1420 - 40 = 1380, matching TCP_MSS_CLAMP in vpp.rs.
			let _ = tokio::process::Command::new("ip")
				.args(["link", "set", xfrm_if, "mtu", "1420"])
				.output().await;
			info!(xfrm_if, if_id, "XFRM interface created (mtu 1420)");
		}
		Ok(o) => {
			let stderr = String::from_utf8_lossy(&o.stderr);
			// "RTNETLINK answers: File exists" means already present -- ok.
			if stderr.contains("File exists") || stderr.contains("already exists") {
				debug!(xfrm_if, "XFRM interface already exists (ok on restart)");
			} else {
				warn!(xfrm_if, if_id, "XFRM interface create failed: {}", stderr.trim());
			}
		}
		Err(e) => warn!(xfrm_if, "failed to spawn ip link add: {e}"),
	}
}

/// Delete the per-site XFRM kernel interface (best-effort).
async fn delete_xfrm_if(xfrm_if: &str) {
	let out = tokio::process::Command::new("ip")
		.args(["link", "del", xfrm_if])
		.output().await;
	match out {
		Ok(o) if o.status.success() => info!(xfrm_if, "XFRM interface deleted"),
		Ok(o) => debug!(xfrm_if, "XFRM interface delete (non-fatal): {}",
		                String::from_utf8_lossy(&o.stderr).trim()),
		Err(e) => warn!(xfrm_if, "failed to spawn ip link del: {e}"),
	}
}
