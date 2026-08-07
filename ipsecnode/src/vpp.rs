//! VPP data-plane management for fleetnode (Increment 6e -- per-site VRFs).
//!
//! See Architecture Decision #15 in AGENTS.md for the full design rationale.
//!
//! Each active customer site gets its own VPP fib table (VRF), keyed by
//! if_id = u32::from(peer_ip as Ipv4Addr).  Per-site NAT mappings use
//! `vrf if_id` so two customers with the same internal_ip coexist without
//! conflict.  The shared vpp-outer tap handles the NAT outside interface.
//!
//! Forward path: xfrm-{hex} -> ip rule prio 100 -> fwd_table -> vpp-{hex}
//!   -> VPP SNAT in VRF if_id -> vpp-outer -> backend.
//! Return path: vpp-outer -> VPP DNAT -> vpp-{hex} -> nftables mark=if_id
//!   -> ip rule prio 200 -> table 9999 default dev ens5
//!   -> XFRM mark_out=if_id selects the right tunnel.

use std::collections::HashMap;
use std::time::Duration;

use anyhow::{Context, Result};
use redis::AsyncCommands;
use tracing::{debug, info, warn};

use crate::nat::{NAT_PREFIX, NatRecord};

// -- Constants ----------------------------------------------------------------

const VPPCTL:          &str = "/usr/bin/vppctl";
pub const VPP_OUTER_KERNEL: &str = "vpp-outer";
const OUTER_ADDR:      &str = "10.255.0.5/30";
const OUTER_VPP_ADDR:  &str = "10.255.0.6/30";
const OUTER_KERNEL_IP: &str = "10.255.0.5";
const NFT_TABLE:       &str = "ipsecnode";
/// nftables set: iface_index values of active per-site taps.
const NFT_VPP_SET:     &str = "vpp_taps";
/// nftables map: iface_index -> mark (if_id) for return-path XFRM selection.
const NFT_VPP_MAP:     &str = "vpp_mark";
/// TCP MSS clamped to this value to fit inner payload within
/// 1500-byte internet MTU after AES-256-GCM + UDP-NAT-T overhead (~100 bytes).
const TCP_MSS_CLAMP:   u32  = 1380;
const VPP_READY_SECS:  u64  = 30;

// -- Public types -------------------------------------------------------------

/// Minimal state produced by init() and passed to the event listener.
#[derive(Debug, Clone)]
pub struct VppState {
	/// VPP-side name of the shared outside tap (e.g. "tap0").
	pub outer_tap: String,
}

/// Per-site VRF state, created on CHILD_SA UP and destroyed on DOWN.
#[allow(dead_code)]
pub struct SiteVrfState {
	/// u32 from peer IPv4; also VPP fib table ID and XFRM if_id.
	pub if_id:           u32,
	/// Linux forward routing table ID (range 10000+).
	pub fwd_table:       u32,
	/// Linux return routing table ID (range 60000+).
	/// Routes `default dev xfrm-{hex}` so XFRM policy with if_id fires.
	pub ret_table:       u32,
	/// Tap /30 subnet index (for deallocation).
	pub tap_idx:         u32,
	/// VPP-side tap name (e.g. "tap1").
	pub vpp_tap:         String,
	/// Kernel-side tap name (e.g. "vpp-3eee6094").
	pub inner_if:        String,
	/// VPP-side tap IP, used as gateway in fwd_table.
	pub tap_vpp_ip:      String,
	/// Kernel-side tap IP with /30 prefix.
	pub tap_kern_prefix: String,
	/// Linux ifindex of inner_if (key in nftables mangle map).
	pub ifindex:         u32,
	/// Device NAT entries currently installed in VPP.
	pub devices:         Vec<DeviceVrfEntry>,
	/// Active CHILD_SA count (re-keying guard).
	pub child_sa_count:  u32,
}

#[derive(Debug, Clone)]
pub struct DeviceVrfEntry {
	pub internal_ip: String,
	pub global_ip:   String,
}

/// In-memory map: peer_ip -> per-site VRF state.  Owned by event_listener_task.
pub type VrfCache = HashMap<String, SiteVrfState>;

// -- VrfAllocator -------------------------------------------------------------

/// Allocates Linux routing table IDs and tap /30 subnet indices.
/// Task-local to event_listener_task -- no Arc<Mutex<>> needed.
pub struct VrfAllocator {
	next_fwd: u32,
	free_fwd: Vec<u32>,
	next_ret: u32,
	free_ret: Vec<u32>,
	next_tap: u32,
	free_tap: Vec<u32>,
}

impl VrfAllocator {
	pub fn new() -> Self {
		Self {
			next_fwd: 10_000, free_fwd: Vec::new(),
			next_ret: 60_000, free_ret: Vec::new(),
			next_tap: 0,      free_tap: Vec::new(),
		}
	}
	fn alloc_fwd(&mut self) -> u32 {
		self.free_fwd.pop().unwrap_or_else(|| { let t = self.next_fwd; self.next_fwd += 1; t })
	}
	fn free_fwd(&mut self, t: u32) { self.free_fwd.push(t); }
	fn alloc_ret(&mut self) -> u32 {
		self.free_ret.pop().unwrap_or_else(|| { let t = self.next_ret; self.next_ret += 1; t })
	}
	fn free_ret(&mut self, t: u32) { self.free_ret.push(t); }
	fn alloc_tap(&mut self) -> u32 {
		self.free_tap.pop().unwrap_or_else(|| { let i = self.next_tap; self.next_tap += 1; i })
	}
	fn free_tap(&mut self, i: u32) { self.free_tap.push(i); }
}

// -- Naming helpers -----------------------------------------------------------

fn if_id_from_peer(peer_ip: &str) -> Option<u32> {
	peer_ip.parse::<std::net::Ipv4Addr>().ok().map(u32::from)
}

fn xfrm_if_name(if_id: u32)  -> String { format!("xfrm-{if_id:08x}") }
fn inner_tap_name(if_id: u32) -> String { format!("vpp-{if_id:08x}")  }

struct TapIps { vpp_ip: String, vpp_prefix: String, kern_prefix: String }

/// Derive tap /30 IPs from subnet index n within 10.127.0.0/16.
/// Subnet n: base = 10.127.{n>>6}.{(n&63)*4}; VPP = base+1, kernel = base+2.
fn tap_ips_from_idx(n: u32) -> TapIps {
	let o3 = n >> 6;
	let b  = (n & 63) * 4;
	TapIps {
		vpp_ip:      format!("10.127.{o3}.{}", b + 1),
		vpp_prefix:  format!("10.127.{o3}.{}/30", b + 1),
		kern_prefix: format!("10.127.{o3}.{}/30", b + 2),
	}
}

// -- Process helpers ----------------------------------------------------------

async fn vppctl(args: &[&str]) -> Result<String> {
	let out = tokio::process::Command::new(VPPCTL).args(args).output().await
		.with_context(|| format!("spawn vppctl {}", args.join(" ")))?;
	let stdout = String::from_utf8_lossy(&out.stdout).trim().to_string();
	let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
	if !out.status.success() {
		anyhow::bail!("vppctl {} failed: stderr={stderr} stdout={stdout}", args.join(" "));
	}
	if stdout.starts_with("unknown input") || stdout.starts_with("Failed:") {
		anyhow::bail!("vppctl {} error: {stdout}", args.join(" "));
	}
	Ok(stdout)
}

async fn vppctl_warn(args: &[&str]) {
	if let Err(e) = vppctl(args).await { warn!("vppctl {} (non-fatal): {e:#}", args.join(" ")); }
}

async fn ip(args: &[&str]) -> Result<()> {
	let out = tokio::process::Command::new("ip").args(args).output().await
		.with_context(|| format!("spawn ip {}", args.join(" ")))?;
	if !out.status.success() {
		anyhow::bail!("ip {} failed: {}", args.join(" "),
			String::from_utf8_lossy(&out.stderr).trim());
	}
	Ok(())
}

async fn ip_warn(args: &[&str]) {
	if let Err(e) = ip(args).await { warn!("ip {} (non-fatal): {e:#}", args.join(" ")); }
}

async fn nft(args: &[&str]) -> Result<()> {
	let out = tokio::process::Command::new("nft").args(args).output().await
		.with_context(|| format!("spawn nft {}", args.join(" ")))?;
	if !out.status.success() {
		anyhow::bail!("nft {} failed: {}", args.join(" "),
			String::from_utf8_lossy(&out.stderr).trim());
	}
	Ok(())
}

async fn nft_warn(args: &[&str]) {
	if let Err(e) = nft(args).await { warn!("nft {} (non-fatal): {e:#}", args.join(" ")); }
}

async fn nft_batch(rules: &str) -> Result<()> {
	use tokio::io::AsyncWriteExt;
	let mut child = tokio::process::Command::new("nft")
		.arg("-f").arg("-")
		.stdin(std::process::Stdio::piped())
		.stderr(std::process::Stdio::piped())
		.spawn().context("spawn nft -f -")?;
	if let Some(mut stdin) = child.stdin.take() {
		stdin.write_all(rules.as_bytes()).await.context("write nft rules")?;
	}
	let out = child.wait_with_output().await.context("wait nft")?;
	if !out.status.success() {
		anyhow::bail!("nft batch failed: {}", String::from_utf8_lossy(&out.stderr).trim());
	}
	Ok(())
}

// -- VPP readiness + cleanup --------------------------------------------------

async fn wait_for_vpp() -> Result<()> {
	let deadline = tokio::time::Instant::now() + Duration::from_secs(VPP_READY_SECS);
	loop {
		let ok = tokio::process::Command::new(VPPCTL)
			.args(["show", "version"]).output().await
			.map(|o| o.status.success()).unwrap_or(false);
		if ok {
			info!("VPP ready");
			return Ok(());
		}
		if tokio::time::Instant::now() >= deadline {
			anyhow::bail!("VPP not ready after {VPP_READY_SECS} s");
		}
		debug!("VPP not ready -- retrying in 2 s");
		tokio::time::sleep(Duration::from_secs(2)).await;
	}
}

/// Remove tap interfaces, NAT44 state, nftables, and ip rules left by a
/// previous run.  All errors are ignored.
async fn cleanup_stale_state() {
	let _ = vppctl(&["nat44", "plugin", "disable"]).await;
	if let Ok(out) = vppctl(&["show", "interface"]).await {
		for line in out.lines() {
			let p: Vec<&str> = line.split_whitespace().collect();
			if p.len() >= 2 && p[0].starts_with("tap") && p[0] != "tap"
				&& p[1].parse::<u32>().is_ok()
			{
				let _ = vppctl(&["delete", "tap", "sw_if_index", p[1]]).await;
			}
		}
	}
	ip_warn(&["addr", "flush", "dev", VPP_OUTER_KERNEL]).await;
	let _ = nft(&["delete", "table", "ip", NFT_TABLE]).await;
	// Flush old shared return table 9999 if left by a pre-6e deployment.
	let _ = ip(&["route", "flush", "table", "9999"]).await;
	for prio in ["100", "200"] {
		loop {
			let ok = tokio::process::Command::new("ip")
				.args(["rule", "del", "prio", prio]).output().await
				.map(|o| o.status.success()).unwrap_or(false);
			if !ok { break; }
		}
	}
}

// -- Startup initialisation ---------------------------------------------------

pub async fn init() -> Result<Option<VppState>> {
	if let Err(e) = wait_for_vpp().await {
		warn!("VPP not available: {e:#} -- running without data plane");
		return Ok(None);
	}
	cleanup_stale_state().await;

	let outer_tap = match create_tap(VPP_OUTER_KERNEL).await {
		Ok(n)  => n,
		Err(e) => { warn!("VPP outer tap failed: {e:#}"); return Ok(None); }
	};

	vppctl(&["set", "interface", "ip", "address", &outer_tap, OUTER_VPP_ADDR]).await
		.context("set IP on vpp-outer (VPP)")?;
	vppctl(&["set", "interface", "state", &outer_tap, "up"]).await
		.context("bring vpp-outer up (VPP)")?;
	ip(&["addr", "add", OUTER_ADDR, "dev", VPP_OUTER_KERNEL]).await
		.context("set IP on vpp-outer (kernel)")?;
	ip(&["link", "set", VPP_OUTER_KERNEL, "up"]).await
		.context("bring vpp-outer up (kernel)")?;

	// Default route BEFORE nat44 enable -- avoids ECMP second path.
	vppctl(&["ip", "route", "add", "0.0.0.0/0", "via", OUTER_KERNEL_IP]).await
		.context("VPP default route")?;

	// 500000 sessions: production value for 180k devices (dev default 65536 too low).
	vppctl(&["nat44", "plugin", "enable", "sessions", "500000"]).await
		.context("enable NAT44")?;
	vppctl(&["set", "interface", "nat44", "out", &outer_tap]).await
		.context("set NAT44 outside interface")?;

	// Per-site return tables (range 60000+) are created per-site in
	// setup_site_vrf and route `default dev xfrm-{hex}` so that the
	// XFRM output policy (if_id) fires on the correct tunnel.

	init_nftables_mangle().await?;

	info!(outer_tap, outer_kernel = VPP_OUTER_KERNEL,
		  "VPP NAT44 initialised (per-site VRF mode)");
	Ok(Some(VppState { outer_tap }))
}

async fn create_tap(kernel_name: &str) -> Result<String> {
	let out = vppctl(&["create", "tap", "host-if-name", kernel_name]).await
		.with_context(|| format!("create tap {kernel_name}"))?;
	let iface = out.trim().to_string();
	if iface.is_empty() {
		anyhow::bail!("VPP create tap returned empty name for {kernel_name}");
	}
	info!(vpp_iface = %iface, %kernel_name, "VPP tap created");
	Ok(iface)
}

async fn init_nftables_mangle() -> Result<()> {
	let mss = TCP_MSS_CLAMP.to_string();
	let rules = format!(
		"add table ip {NFT_TABLE}\n\
		 add set ip {NFT_TABLE} {NFT_VPP_SET} {{ type iface_index; }}\n\
		 add map ip {NFT_TABLE} {NFT_VPP_MAP} {{ type iface_index : mark; }}\n\
		 add chain ip {NFT_TABLE} mangle_pre \
		   {{ type filter hook prerouting priority mangle; policy accept; }}\n\
		 add rule ip {NFT_TABLE} mangle_pre \
		   iif @{NFT_VPP_SET} meta mark set iif map @{NFT_VPP_MAP}\n\
		 add chain ip {NFT_TABLE} tcp_mss \
		   {{ type filter hook forward priority mangle; policy accept; }}\n\
		 add rule ip {NFT_TABLE} tcp_mss \
		   tcp flags & (syn | rst) == syn \
		   tcp option maxseg size > {mss} \
		   tcp option maxseg size set {mss}\n"
	);
	nft_batch(&rules).await.context("init nftables mangle table")?;
	info!(table = NFT_TABLE, tcp_mss = TCP_MSS_CLAMP, "nftables mangle table initialised");
	Ok(())
}

// -- Per-CHILD_SA event handlers ----------------------------------------------

pub async fn on_child_up(
	conn:    &mut redis::aio::MultiplexedConnection,
	peer_ip: &str,
	state:   &VppState,
	cache:   &mut VrfCache,
	alloc:   &mut VrfAllocator,
) {
	if let Some(s) = cache.get_mut(peer_ip) {
		s.child_sa_count += 1;
		debug!(peer_ip, count = s.child_sa_count, "VPP CHILD_SA UP: VRF active");
		return;
	}

	let if_id = match if_id_from_peer(peer_ip) {
		Some(id) => id,
		None     => { warn!(peer_ip, "cannot derive VRF id -- skipping VPP"); return; }
	};

	let record = match get_nat_record(conn, peer_ip).await {
		Some(r) => r,
		None    => return,
	};

	let fwd_table = alloc.alloc_fwd();
	let ret_table = alloc.alloc_ret();
	let tap_idx   = alloc.alloc_tap();
	let tap_ips   = tap_ips_from_idx(tap_idx);
	let inner_if  = inner_tap_name(if_id);

	match setup_site_vrf(peer_ip, if_id, &inner_if, fwd_table, ret_table, tap_idx,
	                     &tap_ips, &record, state).await {
		Ok(site) => {
			info!(peer_ip, vrf = if_id, fwd_table, ret_table,
			      inner_if, tap_vpp = %site.vpp_tap, "VPP: per-site VRF active");
			cache.insert(peer_ip.to_string(), site);
		}
		Err(e) => {
			warn!(peer_ip, "VRF setup failed: {e:#} -- freeing resources");
			alloc.free_fwd(fwd_table);
			alloc.free_ret(ret_table);
			alloc.free_tap(tap_idx);
			teardown_partial(&inner_if, fwd_table, ret_table, if_id).await;
		}
	}
}

pub async fn on_child_down(
	peer_ip: &str,
	_state:  &VppState,
	cache:   &mut VrfCache,
	alloc:   &mut VrfAllocator,
) {
	let site = match cache.get_mut(peer_ip) {
		Some(s) => s,
		None    => { debug!(peer_ip, "VPP CHILD_SA DOWN: no VRF state"); return; }
	};

	site.child_sa_count = site.child_sa_count.saturating_sub(1);
	if site.child_sa_count > 0 {
		debug!(peer_ip, count = site.child_sa_count, "VPP CHILD_SA DOWN: other SAs active");
		return;
	}

	let site = cache.remove(peer_ip).unwrap();
	let (fwd, ret, tap) = (site.fwd_table, site.ret_table, site.tap_idx);
	teardown_site_vrf(peer_ip, &site).await;
	alloc.free_fwd(fwd);
	alloc.free_ret(ret);
	alloc.free_tap(tap);
}

// -- Per-site VRF setup / teardown --------------------------------------------

async fn setup_site_vrf(
	peer_ip:   &str,
	if_id:     u32,
	inner_if:  &str,
	fwd_table: u32,
	ret_table: u32,
	tap_idx:   u32,
	tap_ips:   &TapIps,
	record:    &NatRecord,
	state:     &VppState,
) -> Result<SiteVrfState> {
	let vrf_str = if_id.to_string();
	let fwd_str = fwd_table.to_string();
	let ret_str = ret_table.to_string();
	let xfrm_if = xfrm_if_name(if_id);

	// 1. VPP fib table for this site.
	vppctl(&["ip", "table", "add", &vrf_str]).await.context("VPP ip table add")?;

	// 2. Per-site inside tap in the site VRF.
	//    VRF assignment must precede NAT interface assignment.
	let vpp_tap = create_tap(inner_if).await.context("create per-site VPP tap")?;
	vppctl(&["set", "interface", "ip", "table", &vpp_tap, &vrf_str])
		.await.context("assign VPP tap to site VRF")?;

	// 3. IPs and link state.
	vppctl(&["set", "interface", "ip", "address", &vpp_tap, &tap_ips.vpp_prefix])
		.await.context("set VPP tap IP")?;
	vppctl(&["set", "interface", "state", &vpp_tap, "up"])
		.await.context("bring VPP tap up")?;
	ip(&["addr", "add", &tap_ips.kern_prefix, "dev", inner_if])
		.await.context("assign kernel tap IP")?;
	ip(&["link", "set", inner_if, "up"]).await.context("bring kernel tap up")?;

	// 4. NAT44 inside.  vpp-outer is already the outside interface.
	vppctl(&["set", "interface", "nat44", "in", &vpp_tap, "out", &state.outer_tap])
		.await.context("set NAT44 inside interface")?;

	// 5. Kernel ifindex -- key in the nftables mangle map.
	let ifindex  = get_ifindex(inner_if).await.context("read kernel tap ifindex")?;
	let idx_str  = ifindex.to_string();
	let mark_str = if_id.to_string();

	// 6. nftables mangle map: mark return-path packets with if_id.
	nft(&["add", "element", "ip", NFT_TABLE, NFT_VPP_SET, &format!("{{ {idx_str} }}")])
		.await.context("nft: add to vpp_taps set")?;
	nft(&["add", "element", "ip", NFT_TABLE, NFT_VPP_MAP,
		  &format!("{{ {idx_str} : {mark_str} }}")])
		.await.context("nft: add to vpp_mark map")?;

	// 7. Forward routing: iif xfrm-{hex} -> fwd_table -> per-site tap.
	ip(&["rule", "add", "iif", &xfrm_if, "prio", "100", "lookup", &fwd_str])
		.await.context("ip rule add (forward)")?;
	ip(&["route", "replace", "default",
		 "via", &tap_ips.vpp_ip, "dev", inner_if, "table", &fwd_str])
		.await.context("ip route default (forward table)")?;

	// 8. Return routing: iif vpp-{hex} -> per-site return table -> xfrm-{hex}.
	//    Routing via xfrm-{hex} is required: the XFRM output policy has
	//    if_id set, so it only fires when the output interface carries that id.
	ip(&["rule", "add", "iif", inner_if, "prio", "200", "lookup", &ret_str])
		.await.context("ip rule add (return)")?;
	ip(&["route", "replace", "default", "dev", &xfrm_if, "table", &ret_str])
		.await.context("ip route default (return table via xfrm)")?;

	// 9. VPP NAT static mappings, one per device_nat entry.
	let mut devices = Vec::new();
	for entry in &record.device_nat {
		match install_device_nat(&vrf_str, &entry.internal_ip, &entry.global_ip).await {
			Ok(()) => {
				info!(peer_ip, internal_ip = %entry.internal_ip,
				      global_ip = %entry.global_ip, vrf = if_id, "VPP: NAT mapping installed");
				devices.push(DeviceVrfEntry {
					internal_ip: entry.internal_ip.clone(),
					global_ip:   entry.global_ip.clone(),
				});
			}
			Err(e) => warn!(peer_ip, internal_ip = %entry.internal_ip,
			                "VPP NAT install failed: {e:#}"),
		}
	}

	Ok(SiteVrfState {
		if_id, fwd_table, ret_table, tap_idx, vpp_tap,
		inner_if:        inner_if.to_string(),
		tap_vpp_ip:      tap_ips.vpp_ip.clone(),
		tap_kern_prefix: tap_ips.kern_prefix.clone(),
		ifindex, devices, child_sa_count: 1,
	})
}

async fn teardown_site_vrf(peer_ip: &str, site: &SiteVrfState) {
	let fwd_str = site.fwd_table.to_string();
	let ret_str = site.ret_table.to_string();
	let vrf_str = site.if_id.to_string();
	let xfrm_if = xfrm_if_name(site.if_id);
	let idx_str = site.ifindex.to_string();

	// 1. Remove VPP NAT mappings; revert global_ip routes to blackhole so
	//    nat::on_child_down can then delete them entirely.
	for d in &site.devices {
		remove_device_nat(&vrf_str, &d.internal_ip, &d.global_ip).await;
		info!(peer_ip, internal_ip = %d.internal_ip, global_ip = %d.global_ip,
		      "VPP: NAT mapping removed");
	}

	// 2. ip rules, forward route, and return route.
	ip_warn(&["rule", "del", "iif", &xfrm_if,      "prio", "100", "lookup", &fwd_str]).await;
	ip_warn(&["rule", "del", "iif", &site.inner_if, "prio", "200", "lookup", &ret_str]).await;
	ip_warn(&["route", "del", "default", "table", &fwd_str]).await;
	ip_warn(&["route", "del", "default", "table", &ret_str]).await;

	// 3. nftables mangle map entries.
	nft_warn(&["delete", "element", "ip", NFT_TABLE, NFT_VPP_SET,
			   &format!("{{ {idx_str} }}")]).await;
	nft_warn(&["delete", "element", "ip", NFT_TABLE, NFT_VPP_MAP,
			   &format!("{{ {idx_str} }}")]).await;

	// 4. Kernel-side tap.
	ip_warn(&["link", "set", &site.inner_if, "down"]).await;
	ip_warn(&["link", "del", &site.inner_if]).await;

	// 5. VPP tap (also removes NAT inside assignment and FIB entries).
	delete_vpp_tap(&site.vpp_tap).await;

	// 6. VPP fib table (now empty after tap deletion).
	vppctl_warn(&["ip", "table", "del", &vrf_str]).await;

	info!(peer_ip, vrf = site.if_id, "VPP: per-site VRF torn down");
}

/// Best-effort cleanup after a partial setup_site_vrf failure.
async fn teardown_partial(inner_if: &str, fwd_table: u32, ret_table: u32, if_id: u32) {
	let fwd_str = fwd_table.to_string();
	let ret_str = ret_table.to_string();
	let xfrm_if = xfrm_if_name(if_id);
	ip_warn(&["rule", "del", "iif", &xfrm_if,  "prio", "100", "lookup", &fwd_str]).await;
	ip_warn(&["rule", "del", "iif", inner_if,   "prio", "200", "lookup", &ret_str]).await;
	ip_warn(&["route", "del", "default", "table", &fwd_str]).await;
	ip_warn(&["route", "del", "default", "table", &ret_str]).await;
	ip_warn(&["link", "set", inner_if, "down"]).await;
	ip_warn(&["link", "del", inner_if]).await;
}

// -- Per-device NAT -----------------------------------------------------------

async fn install_device_nat(vrf_str: &str, internal_ip: &str, global_ip: &str) -> Result<()> {
	vppctl(&[
		"nat44", "add", "static", "mapping",
		"local", internal_ip, "external", global_ip, "vrf", vrf_str,
	]).await.context("VPP nat44 add static mapping")?;

	// Upgrade global_ip route: blackhole (6c) -> dev vpp-outer (return path).
	ip(&["route", "replace", &format!("{global_ip}/32"), "dev", VPP_OUTER_KERNEL])
		.await.context("ip route replace global_ip dev vpp-outer")?;
	Ok(())
}

async fn remove_device_nat(vrf_str: &str, internal_ip: &str, global_ip: &str) {
	// Revert to blackhole; nat::on_child_down will then delete it.
	ip_warn(&["route", "replace", &format!("{global_ip}/32"), "type", "blackhole"]).await;
	if let Err(e) = vppctl(&[
		"nat44", "del", "static", "mapping",
		"local", internal_ip, "external", global_ip, "vrf", vrf_str,
	]).await {
		warn!(internal_ip, global_ip, "VPP nat44 del: {e:#}");
	}
}

// -- VPP tap deletion ---------------------------------------------------------

async fn delete_vpp_tap(vpp_tap_name: &str) {
	if let Ok(out) = vppctl(&["show", "interface", vpp_tap_name]).await {
		for line in out.lines() {
			let p: Vec<&str> = line.split_whitespace().collect();
			if p.len() >= 2 && p[0] == vpp_tap_name && p[1].parse::<u32>().is_ok() {
				vppctl_warn(&["delete", "tap", "sw_if_index", p[1]]).await;
				return;
			}
		}
	}
	warn!(vpp_tap = vpp_tap_name, "could not find sw_if_index to delete tap");
}

// -- Kernel helpers -----------------------------------------------------------

async fn get_ifindex(iface: &str) -> Result<u32> {
	let path = format!("/sys/class/net/{iface}/ifindex");
	let s = tokio::fs::read_to_string(&path).await
		.with_context(|| format!("read {path}"))?;
	s.trim().parse::<u32>().with_context(|| format!("parse ifindex from {path}"))
}

// -- Valkey helper ------------------------------------------------------------

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
