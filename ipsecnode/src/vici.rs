//! VICI protocol helpers for ipsecnode.
//!
//! Two connections are used:
//!   - Command connection: load-shared, unload-shared, load-cert.
//!     Owned by the credential manager task after startup.
//!   - Event connection: subscribe to child-updown events.
//!     Owned by event_listener_task; kept alive there.
//!
//! # Connection lifecycle
//! Both connections are established with connect_with_retry() which attempts
//! a connect every 2 s for up to `timeout_secs` seconds.  After the initial
//! connect, reconnection on socket failure is handled by the task owners
//! (they log an error and return, causing systemd to restart ipsecnode).

use std::collections::HashMap;
use std::path::Path;
use std::time::Duration;

use anyhow::{Context, Result};
use futures_util::{TryStreamExt, pin_mut};
use redis;
use serde::{Deserialize, Serialize};
use serde::de::{Deserializer, MapAccess, SeqAccess, Visitor};
use tracing::{debug, error, info, warn};

// Re-export Client so callers can name the type without importing rsvici.
pub use rsvici::Client;

// ── Raw VICI event value ────────────────────────────────────────────────────
//
// serde_vici emits VICI octet-strings as byte arrays (visit_bytes).
// serde_json::Value has no byte array variant and panics with
// "invalid type: byte array" when used as the event target.
// ViciRawValue handles all VICI element types:
//   octet-string  -> Text (bytes decoded as UTF-8)
//   bool yes/no   -> Text ("yes" / "no")
//   section       -> Section (BTreeMap)
//   list          -> List (Vec<String>)

/// Raw VICI event payload.  Use `RUST_LOG=ipsecnode=trace` to log it.
#[derive(Debug)]
pub enum ViciRawValue {
	Text(String),
	Section(std::collections::BTreeMap<String, ViciRawValue>),
	List(Vec<String>),
}

impl<'de> Deserialize<'de> for ViciRawValue {
	fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
		d.deserialize_any(ViciValueVisitor)
	}
}

struct ViciValueVisitor;

impl<'de> Visitor<'de> for ViciValueVisitor {
	type Value = ViciRawValue;

	fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
		write!(f, "a VICI octet-string, section, or list")
	}

	fn visit_str<E: serde::de::Error>(self, v: &str) -> Result<ViciRawValue, E> {
		Ok(ViciRawValue::Text(v.to_string()))
	}

	// serde_vici emits all octet-strings via visit_bytes
	fn visit_bytes<E: serde::de::Error>(self, v: &[u8]) -> Result<ViciRawValue, E> {
		Ok(ViciRawValue::Text(String::from_utf8_lossy(v).into_owned()))
	}

	fn visit_byte_buf<E: serde::de::Error>(self, v: Vec<u8>) -> Result<ViciRawValue, E> {
		Ok(ViciRawValue::Text(String::from_utf8_lossy(&v).into_owned()))
	}

	// serde_vici maps "yes"/"no" to bool
	fn visit_bool<E: serde::de::Error>(self, v: bool) -> Result<ViciRawValue, E> {
		Ok(ViciRawValue::Text(if v { "yes" } else { "no" }.to_string()))
	}

	fn visit_map<M: MapAccess<'de>>(self, mut map: M) -> Result<ViciRawValue, M::Error> {
		let mut result = std::collections::BTreeMap::new();
		while let Some(key) = map.next_key::<String>()? {
			let value: ViciRawValue = map.next_value()?;
			result.insert(key, value);
		}
		Ok(ViciRawValue::Section(result))
	}

	fn visit_seq<S: SeqAccess<'de>>(self, mut seq: S) -> Result<ViciRawValue, S::Error> {
		let mut items = Vec::new();
		while let Some(item) = seq.next_element::<ViciRawValue>()? {
			if let ViciRawValue::Text(s) = item {
				items.push(s);
			}
		}
		Ok(ViciRawValue::List(items))
	}
}

impl std::fmt::Display for ViciRawValue {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		match self {
			ViciRawValue::Text(s) =>
				write!(f, "\"{}\"" , s),
			ViciRawValue::List(items) => {
				write!(f, "[")?;
				for (i, s) in items.iter().enumerate() {
					if i > 0 { write!(f, ",")?; }
					write!(f, "\"{}\"" , s)?;
				}
				write!(f, "]")
			}
			ViciRawValue::Section(map) => {
				write!(f, "{{")?;
				for (i, (k, v)) in map.iter().enumerate() {
					if i > 0 { write!(f, ",")?; }
					write!(f, "\"{}\":{}" , k, v)?;
				}
				write!(f, "}}")
			}
		}
	}
}

impl ViciRawValue {
	/// Look up a key in a Section variant.
	pub fn get(&self, key: &str) -> Option<&ViciRawValue> {
		if let ViciRawValue::Section(map) = self { map.get(key) } else { None }
	}

	/// Return the inner string of a Text variant.
	pub fn as_str(&self) -> Option<&str> {
		if let ViciRawValue::Text(s) = self { Some(s.as_str()) } else { None }
	}
}

// ── VICI socket path ──────────────────────────────────────────────────────────

#[allow(dead_code)]
pub const VICI_SOCKET: &str = "/var/run/charon.vici";

// ── Connection ────────────────────────────────────────────────────────────────

/// Connect to the VICI Unix socket, retrying every 2 s for up to
/// `timeout_secs` seconds (accommodates charon startup lag at boot).
pub async fn connect_with_retry(socket_path: &str, timeout_secs: u64) -> Result<Client> {
	let deadline = tokio::time::Instant::now() + Duration::from_secs(timeout_secs);

	loop {
		match rsvici::unix::connect(socket_path).await {
			Ok(client) => return Ok(client),
			Err(e) => {
				if tokio::time::Instant::now() >= deadline {
					return Err(anyhow::anyhow!(
						"VICI connect to {socket_path} timed out after {timeout_secs}s: {e}"
					));
				}
				debug!(%socket_path, "VICI connect failed ({e}), retrying in 2 s ...");
				tokio::time::sleep(Duration::from_secs(2)).await;
			}
		}
	}
}

// ── VICI command result ───────────────────────────────────────────────────────

/// Deserialised response for commands that return success/errmsg.
#[derive(Deserialize)]
struct ViciResult {
	success: Option<bool>,
	errmsg:  Option<String>,
}

impl ViciResult {
	fn into_result(self, cmd: &str) -> Result<()> {
		match self.success {
			Some(false) | Some(true) if !self.success.unwrap_or(true) => {
				anyhow::bail!(
					"VICI {cmd} failed: {}",
					self.errmsg.as_deref().unwrap_or("(no errmsg)")
				)
			}
			_ => Ok(()),
		}
	}
}

// ── load-shared ───────────────────────────────────────────────────────────────

/// VICI request message for the `load-shared` command.
///
/// VICI protocol reference:
///   id      -- unique identifier string (e.g. "psk-185.17.205.224")
///   type    -- secret type: "IKE"
///   data    -- PSK bytes (serialised as VICI octet-string via String)
///   owners  -- list of peer identities that may use this PSK
///              [device_public_ip] always present
///              + [ike_identity] if the device record has an ike_identity field
#[derive(Serialize)]
struct LoadSharedReq {
	id:     String,
	#[serde(rename = "type")]
	kind:   String,
	data:   String,
	owners: Vec<String>,
}

/// Load a PSK into charon via VICI.
///
/// `id`         -- unique identifier, conventionally "psk-<device_ip>"
/// `psk`        -- PSK string as stored in Valkey
/// `owners`     -- list of peer identities (IP strings, optional FQDN)
pub async fn load_shared(
	client:  &mut Client,
	id:      &str,
	psk:     &str,
	owners:  Vec<String>,
) -> Result<()> {
	let req = LoadSharedReq {
		id:    id.to_string(),
		kind:  "IKE".to_string(),
		data:  psk.to_string(),
		owners,
	};

	let res: ViciResult = client
		.request("load-shared", req)
		.await
		.context("VICI load-shared request failed")?;

	res.into_result("load-shared")
}

// ── unload-shared ─────────────────────────────────────────────────────────────

#[derive(Serialize)]
struct UnloadSharedReq {
	id: String,
}

/// Remove a previously-loaded PSK from charon.
/// `id` must match the id used in the corresponding load_shared() call.
pub async fn unload_shared(client: &mut Client, id: &str) -> Result<()> {
	let req = UnloadSharedReq { id: id.to_string() };

	let res: ViciResult = client
		.request("unload-shared", req)
		.await
		.context("VICI unload-shared request failed")?;

	res.into_result("unload-shared")
}

// ── load-cert (CA certificates) ───────────────────────────────────────────────

/// VICI request message for the `load-cert` command.
///
/// type  -- "X509"
/// flag  -- "CA" for a CA certificate
/// data  -- DER or PEM bytes  (serde_bytes ensures Vec<u8> is a VICI octet-string)
#[derive(Serialize)]
struct LoadCertReq {
	#[serde(rename = "type")]
	kind: String,
	flag: String,
	#[serde(with = "serde_bytes")]
	data: Vec<u8>,
}

/// Load one CA certificate file into charon via VICI load-cert.
pub async fn load_cert(client: &mut Client, pem_bytes: Vec<u8>) -> Result<()> {
	let req = LoadCertReq {
		kind: "X509".to_string(),
		flag: "CA".to_string(),
		data: pem_bytes,
	};

	let res: ViciResult = client
		.request("load-cert", req)
		.await
		.context("VICI load-cert request failed")?;

	res.into_result("load-cert")
}

/// Scan `ca_cert_dir` for *.pem / *.crt files and load each as a CA cert.
/// Returns the number of certificates successfully loaded.
pub async fn load_ca_certs(client: &mut Client, ca_cert_dir: &str) -> Result<usize> {
	let dir = Path::new(ca_cert_dir);
	if !dir.exists() {
		info!(dir = ca_cert_dir, "CA cert directory does not exist -- skipping");
		return Ok(0);
	}

	let mut count = 0usize;
	let mut rd = tokio::fs::read_dir(dir)
		.await
		.with_context(|| format!("Cannot read CA cert directory: {ca_cert_dir}"))?;

	while let Some(entry) = rd.next_entry().await? {
		let path = entry.path();
		let ext  = path.extension().and_then(|e| e.to_str()).unwrap_or("");
		if ext != "pem" && ext != "crt" {
			continue;
		}

		let bytes = tokio::fs::read(&path)
			.await
			.with_context(|| format!("Cannot read CA cert file: {}", path.display()))?;

		match load_cert(client, bytes).await {
			Ok(()) => {
				info!(file = %path.display(), "CA certificate loaded");
				count += 1;
			}
			Err(e) => {
				warn!(file = %path.display(), "CA certificate load failed: {e:#}");
			}
		}
	}

	Ok(count)
}

// ── child-updown event ────────────────────────────────────────────────────────

/// Typed structs for the child-updown event -- kept as reference.
/// Currently unused because we deserialise to serde_json::Value first
/// (to trace-log the raw payload and discover the actual section key
/// StrongSwan 5.9.8 uses).  Once confirmed, replace Value with these.
#[allow(dead_code)]
#[derive(Debug, Deserialize)]
pub struct ViciPeer {
	/// IKE identity (may be IP string, FQDN, etc.)
	pub id:   Option<String>,
	/// Actual source IP of the peer (always present on updown events).
	pub host: Option<String>,
}

/// The child-sa section of a child-updown event.
#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct ViciChildSa {
	/// Name of the IKE connection (e.g. "fleetipsec-ikev2").
	pub name:    Option<String>,
	/// Unique ID of this CHILD_SA.
	pub uniqueid: Option<String>,
	/// IPSec mode: "tunnel", "transport", "beet".
	pub mode:    Option<String>,
	/// Remote traffic selectors (list of CIDR strings).
	#[serde(rename = "remote-ts")]
	pub remote_ts: Option<Vec<String>>,
	/// Remote peer info.
	pub remote: Option<ViciPeer>,
}

/// Deserialised child-updown event from charon.
///
/// VICI serialises bool as "yes"/"no"; rsvici / serde_vici maps these to bool.
#[allow(dead_code)]
#[derive(Debug, Deserialize)]
pub struct ChildUpdownEvent {
	/// true = tunnel came up, false = tunnel went down.
	pub up:       bool,
	/// Unique ID of the parent IKE SA.
	pub uniqueid: Option<String>,
	/// The CHILD_SA that changed state.
	#[serde(rename = "child-sa")]
	pub child_sa: Option<ViciChildSa>,
}

// ── Event listener task ─────────────────────────────────────────────────────
//
// The child-updown subscription uses serde_json::Value as the raw type so
// that we can trace-log the exact VICI payload before trying to extract
// fields.  This also avoids breakage if StrongSwan uses the child SA name
// as the section key instead of the literal string "child-sa".
//
// Enable trace logging with: RUST_LOG=ipsecnode=trace

/// Long-running task: subscribes to child-updown events, manages FRR /32
/// blackhole routes (Increment 6c) and VPP NAT/routing (Increment 6d).
///
/// `_keep_alive` is the VICI event Client.  It MUST be kept in scope here --
/// dropping it aborts the internal Listener task and the stream ends.
pub async fn event_listener_task(
	_keep_alive:   Client,
	stream:        impl futures_util::Stream<Item = Result<ViciRawValue, rsvici::Error>>,
	valkey_client: redis::Client,
	vpp_state:     Option<crate::vpp::VppState>,
) {
	// One auto-reconnecting Valkey connection shared for all NAT record lookups.
	// ConnectionManager transparently re-establishes the underlying multiplexed
	// connection after a drop (Connection reset by peer / broken pipe), so a
	// Valkey blip no longer permanently breaks NAT/route installation on
	// subsequent CHILD_SA UP events.
	let mut valkey_conn = match redis::aio::ConnectionManager::new(valkey_client).await {
		Ok(c)  => c,
		Err(e) => {
			error!("event_listener_task: Valkey connect failed: {e} -- exiting");
			return;
		}
	};

	let mut route_cache = crate::nat::RouteCache::new();
	let mut vpp_cache   = crate::vpp::VrfCache::new();
	let mut vrf_alloc   = crate::vpp::VrfAllocator::new();

	pin_mut!(stream);

	loop {
		match stream.try_next().await {
			Ok(Some(raw)) => {
				tracing::trace!(payload = %raw, "VICI child-updown raw");
				handle_child_updown(
					raw,
					&mut valkey_conn,
					&mut route_cache,
					vpp_state.as_ref(),
					&mut vpp_cache,
					&mut vrf_alloc,
				).await;
			}
			Ok(None) => {
				warn!("VICI child-updown stream ended (charon closed the connection?)");
				return;
			}
			Err(e) => {
				error!("VICI child-updown stream error: {e}");
				return;
			}
		}
	}
}

/// Find the IKE SA section -- the top-level Section value (not "up").
fn find_ike_section(raw: &ViciRawValue) -> Option<&ViciRawValue> {
	if let ViciRawValue::Section(map) = raw {
		map.values().find(|v| matches!(v, ViciRawValue::Section(_)))
	} else {
		None
	}
}

/// Find the first child SA section inside an IKE SA section's "child-sas" key.
fn find_child_sa(ike: &ViciRawValue) -> Option<&ViciRawValue> {
	if let ViciRawValue::Section(child_sas) = ike.get("child-sas")? {
		child_sas.values().next()
	} else {
		None
	}
}

async fn handle_child_updown(
	raw:         ViciRawValue,
	conn:        &mut redis::aio::ConnectionManager,
	route_cache: &mut crate::nat::RouteCache,
	vpp_state:   Option<&crate::vpp::VppState>,
	vrf_cache:   &mut crate::vpp::VrfCache,
	vrf_alloc:   &mut crate::vpp::VrfAllocator,
) {
	// "up" is at the top level; absent on DOWN events.
	let up = raw.get("up")
		.and_then(|v| v.as_str())
		.map(|s| s == "yes")
		.unwrap_or(false);
	let direction = if up { "UP" } else { "DOWN" };

	let ike   = find_ike_section(&raw);
	let child = ike.and_then(find_child_sa);

	// Peer IP and identity live on the IKE SA section.
	let peer_ip = ike
		.and_then(|i| i.get("remote-host"))
		.and_then(|h| h.as_str())
		.unwrap_or("unknown");

	let peer_id = ike
		.and_then(|i| i.get("remote-id"))
		.and_then(|i| i.as_str())
		.unwrap_or("-");

	let ike_sa = ike
		.and_then(|i| i.get("uniqueid"))
		.and_then(|u| u.as_str())
		.unwrap_or("-");

	// Connection name and child SA ID live inside child-sas.<child-name>.
	let conn_name = child
		.and_then(|c| c.get("name"))
		.and_then(|n| n.as_str())
		.unwrap_or("-");

	let child_id = child
		.and_then(|c| c.get("uniqueid"))
		.and_then(|u| u.as_str())
		.unwrap_or("-");

	info!(
		direction,
		peer_ip,
		peer_id,
		conn_name,
		child_id,
		ike_sa,
		"CHILD_SA {direction}"
	);

	// Increment 6c: /32 blackhole route (FRR BGP signal).
	// Increment 6e: per-customer VRF + VPP NAT (replaces 6d global table).
	if up {
		crate::nat::on_child_up(conn, peer_ip, route_cache).await;
		if let Some(state) = vpp_state {
			crate::vpp::on_child_up(conn, peer_ip, state, vrf_cache, vrf_alloc).await;
		}
	} else {
		if let Some(state) = vpp_state {
			crate::vpp::on_child_down(peer_ip, state, vrf_cache, vrf_alloc).await;
		}
		crate::nat::on_child_down(peer_ip, route_cache).await;
	}

	// Increment 6e: ASG lifecycle hook heartbeat.
	// Increment 6f: Valkey half-open IKE SA state.
}

// ── Connection management (load-conn / unload-conn) ───────────────────────────
//
// Per-device connections are loaded for devices that have custom crypto
// parameters or explicit traffic selectors.  Devices without these fields
// fall through to the catch-all connection baked into the AMI.
//
// Connection naming convention: "device-<device_ip>"
// Child SA naming convention:   same as the connection (one child per conn).

/// Canonical per-site VICI connection identifier.
pub fn conn_id(site_ip: &str) -> String {
	format!("site-{site_ip}")
}

// ── initiate (on-demand CHILD_SA bring-up, Increment 6g phase 2) ───────────────

/// VICI request message for the `initiate` command.
///
/// `child`   -- the CHILD SA config name to raise (here == conn_id == the child
///              name, since load_conn inserts the child under the conn name).
///              Raising the CHILD (not just the IKE) is REQUIRED so charon fires
///              a child-updown UP event and ipsecnode installs the data plane.
/// `timeout` -- milliseconds as a string; positive bounds the call, so the
///              request returns even if the peer never answers.
#[derive(Serialize)]
struct InitiateReq {
	child:   String,
	#[serde(skip_serializing_if = "Option::is_none")]
	timeout: Option<String>,
}

/// Initiate a CHILD_SA on demand (backend-initiated bring-up).
///
/// Direction-agnostic downstream: once the CHILD comes up, the normal
/// child-updown UP handler installs the VRF/bypass/route data plane exactly as
/// for a site-initiated tunnel.  `timeout_ms` bounds the blocking VICI call.
pub async fn initiate_child(client: &mut Client, child: &str, timeout_ms: u32) -> Result<()> {
	let req = InitiateReq {
		child:   child.to_string(),
		timeout: Some(timeout_ms.to_string()),
	};

	let res: ViciResult = client
		.request("initiate", req)
		.await
		.context("VICI initiate request failed")?;

	res.into_result("initiate")
}

// ── load-conn types ───────────────────────────────────────────────────────────

/// Top-level load-conn message: { "<conn_name>": { <IKE SA config> } }
/// serde_vici serialises HashMap<String, V> as named VICI sections.
type LoadConnMsg = HashMap<String, IkeConnConfig>;

#[derive(Serialize)]
struct LocalAuth {
	auth: &'static str,  // always "psk"
	/// Local IKE identity (IDi/IDr) presented to the peer.
	/// Set to the customer-facing EIP when this node INITIATES, so CPE that key
	/// their PSK to our public IP (Cisco `crypto isakmp key ... address <EIP>`)
	/// can find it.  None = StrongSwan falls back to the node's own IP.
	#[serde(skip_serializing_if = "Option::is_none")]
	id: Option<String>,
}

#[derive(Serialize)]
struct RemoteAuth {
	auth: &'static str,  // always "psk"
	/// Peer IKE identity.  "%any" accepts any identity;
	/// a specific value (IP string or FQDN) pins the match.
	#[serde(skip_serializing_if = "Option::is_none")]
	id: Option<String>,
}

/// CHILD SA (IPSec SA) configuration within a connection.
#[derive(Serialize)]
struct ChildConnConfig {
	/// Remote traffic selectors (customer subnets).
	remote_ts:     Vec<String>,
	/// Local traffic selector: the mapped global IP assigned to this device.
	local_ts:      Vec<String>,
	/// ESP proposals.  Never empty (defaults applied by proposals module).
	#[serde(skip_serializing_if = "Vec::is_empty")]
	esp_proposals: Vec<String>,
	/// Never auto-initiate; we are always the responder.
	start_action:  &'static str,
	mode:          &'static str,
	/// Restart the CHILD SA if DPD detects the peer is gone.
	dpd_action:    &'static str,
	/// XFRM interface ID for inbound SA (Architecture Decision #15).
	/// Decapsulated packets appear on the xfrm-{hex} kernel interface.
	/// Absent (None) = no XFRM interface binding (dev/test only).
	#[serde(skip_serializing_if = "Option::is_none")]
	if_id_in:  Option<u32>,
	/// XFRM interface ID for outbound SA.
	#[serde(skip_serializing_if = "Option::is_none")]
	if_id_out: Option<u32>,
	/// Mark required on outbound packets for XFRM policy selection.
	/// Set by nftables mangle on vpp-{hex} input; disambiguates tunnels
	/// whose customers share the same internal_ip.
	#[serde(skip_serializing_if = "Option::is_none")]
	mark_out:  Option<u32>,
}

/// IKE SA configuration for one per-device connection.
#[derive(Serialize)]
struct IkeConnConfig {
	/// 0 = any, 1 = IKEv1, 2 = IKEv2.
	version:      u8,
	/// Peer IP address(es).  VICI requires a list even for a single address.
	remote_addrs: Vec<String>,
	/// IKE proposals.  Never empty (defaults applied by proposals module).
	#[serde(skip_serializing_if = "Vec::is_empty")]
	proposals:    Vec<String>,
	/// Force NAT-T encapsulation (required for IKEv1 devices).
	#[serde(skip_serializing_if = "Option::is_none")]
	encap:        Option<bool>,
	/// DPD keepalive interval in seconds (no unit suffix in VICI).
	dpd_delay:    u32,
	local:        LocalAuth,
	remote:       RemoteAuth,
	children:     HashMap<String, ChildConnConfig>,
}

// ── load-conn ─────────────────────────────────────────────────────────────────

/// Build and issue a VICI load-conn for a single device.
///
/// `conn_name`     -- identifier (e.g. "device-185.17.205.224")
/// `device_ip`     -- peer IP used for remote_addrs when static_ip is true
/// `static_ip`     -- true: pin remote_addrs; false: use %any
/// `ike_version`   -- 0 = any, 1 = IKEv1, 2 = IKEv2
/// `ike_identity`  -- optional; pinned in remote.id when present
/// `ike_proposals` -- ordered list from proposals::build_ike_proposals()
/// `esp_proposals` -- ordered list from proposals::build_esp_proposals()
/// `remote_ts`     -- customer subnets; defaults to ["0.0.0.0/0"]
/// `local_ts`      -- VPN-node-side selectors: customer's view of our backends
///                    or ["0.0.0.0/0"] when not customised
/// `if_id`         -- optional XFRM interface ID (u32 from peer IPv4 address).
///                    When Some, sets if_id_in, if_id_out, and mark_out on the
///                    child SA for per-customer VRF isolation (AD #15).
///                    None = legacy global-table mode (dev/test only).
/// `local_id`      -- optional stable local IKE identity (customer-facing EIP)
///                    presented as IDi when this node INITIATES.  Required for
///                    standard CPE that key their PSK to our public IP.
///                    None = StrongSwan falls back to the node's own IP.
#[allow(clippy::too_many_arguments)]
pub async fn load_conn(
	client:          &mut Client,
	conn_name:       &str,
	device_ip:       &str,
	static_ip:       bool,
	ike_version:     u8,
	ike_identity:    Option<&str>,
	ike_proposals:   Vec<String>,
	esp_proposals:   Vec<String>,
	remote_ts:       Vec<String>,
	local_ts:        Vec<String>,
	if_id:           Option<u32>,
	mark_out:        Option<u32>,
	local_id:        Option<&str>,
) -> Result<()> {
	let remote_addrs = if static_ip {
		vec![device_ip.to_string()]
	} else {
		vec!["%any".to_string()]
	};

	// IKEv1 devices may not negotiate NAT-T automatically;
	// encap=yes forces UDP encapsulation proactively.
	let encap = if ike_version == 1 { Some(true) } else { None };

	let child = ChildConnConfig {
		remote_ts,
		local_ts,
		esp_proposals,
		start_action:  "none",
		mode:          "tunnel",
		dpd_action:    "restart",
		if_id_in:  if_id,
		if_id_out: if_id,
		mark_out,
	};

	let mut children = HashMap::new();
	children.insert(conn_name.to_string(), child);

	let ike = IkeConnConfig {
		version: ike_version,
		remote_addrs,
		proposals: ike_proposals,
		encap,
		dpd_delay: 30,
		local:  LocalAuth {
			auth: "psk",
			id:   local_id.map(str::to_string),
		},
		remote: RemoteAuth {
			auth: "psk",
			// Pin remote.id so PSK lookup on OUTBOUND initiate resolves the
			// per-customer key by the peer identity (owner = customer IP),
			// exactly as the responder path does.  ike_identity wins when set;
			// otherwise a static-IP customer is identified by its public IP.
			id:   ike_identity.map(str::to_string)
				.or_else(|| if static_ip { Some(device_ip.to_string()) } else { None }),
		},
		children,
	};

	let mut msg: LoadConnMsg = HashMap::new();
	msg.insert(conn_name.to_string(), ike);

	let res: ViciResult = client
		.request("load-conn", msg)
		.await
		.context("VICI load-conn request failed")?;

	res.into_result("load-conn")
}

// ── unload-conn ───────────────────────────────────────────────────────────────

#[derive(Serialize)]
struct UnloadConnReq {
	name: String,
}

/// Remove a per-device connection from charon.
/// Returns Ok(()) even if the connection was not loaded (not an error;
/// e.g. device previously had no custom config).
pub async fn unload_conn(client: &mut Client, conn_name: &str) -> Result<()> {
	let req = UnloadConnReq { name: conn_name.to_string() };

	match client.request::<_, ViciResult>("unload-conn", req).await {
		Ok(res) => {
			// success=false just means the connection wasn't loaded -- not an error.
			if res.success == Some(false) {
				tracing::debug!(conn_name, "unload-conn: connection was not loaded (ok)");
			}
			Ok(())
		}
		Err(e) => Err(anyhow::anyhow!("VICI unload-conn failed: {e}")),
	}
}
