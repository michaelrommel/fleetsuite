//! VPP data-plane management for fleetnode (Increment 6f-r -- per-site backend DNAT).
//!
//! See Architecture Decision #15 (per-site VRFs) and #16 (backend DNAT) in AGENTS.md.
//!
//! Each active customer site gets its own VPP fib table (VRF), keyed by
//! if_id = u32::from(peer_ip as Ipv4Addr).  Per-site NAT mappings use
//! `vrf if_id` so two customers with the same internal_ip coexist without
//! conflict.  The shared vpp-outer tap handles the NAT outside interface.
//!
//! Forward path (backend/VRF mode): xfrm-{hex} -> ipsecnode_bnat PREROUTING (customer_view_ip -> real_ip)
//!   -> ip rule prio 100 -> fwd_table -> vpp-{hex}
//!   -> VPP SNAT (internal_ip -> global_ip) in VRF if_id
//!   -> vpp-outer -> ipsecnode_svcroute PREROUTING (port-based split) -> backend.
//!
//! Forward path (customer/bypass mode -- the whole fleet): xfrm-{hex} ->
//!   ipsecnode_bnat PREROUTING: per-site split chain (access_server
//!   customer_view + port -> proxy pool / FTP VIP), else customer_view->real_ip
//!   map -> forwarded straight out ens5 (NO VPP, NO vpp-outer). The svcroute
//!   table is NOT traversed in bypass mode -- the port splits live in the bnat
//!   split chain instead (scoped to the access_server view; see AGENTS).
//! Return path: vpp-outer -> VPP DNAT (global_ip -> internal_ip) -> vpp-{hex}
//!   -> nftables mark=if_id -> ip rule prio 200 -> ret_table default dev xfrm-{hex}
//!   -> conntrack reverse SNAT (real_ip -> customer_view_ip)
//!   -> XFRM output policy (if_id) fires on xfrm-{hex}, encrypting the packet.
//!
//! Backend-initiated path (Increment 6g): backend -> ens5 -> route global_ip/32
//!   dev vpp-outer -> VPP static DNAT (global_ip -> internal_ip, o2i-first
//!   session) -> vpp-{hex} -> ret_table dev xfrm-{hex}
//!   -> POSTROUTING SNAT (backend_ip -> access_server customer_view_ip, ct new)
//!   -> XFRM encrypt -> device.  The device reply (i2o) is un-SNAT'd by
//!   conntrack and re-looked-up in the site VRF, which carries a recursive
//!   "lookup in table 0" default route so the reply can egress via vpp-outer
//!   (setup_site_vrf step 9b).

use std::collections::HashMap;
use std::time::Duration;

use anyhow::{Context, Result};
use redis::AsyncCommands;
use tracing::{debug, error, info, warn};

use crate::nat::{BackendNatRecord, NAT_PREFIX, NatRecord};
use crate::nodeconfig::{BackendConfig, SplitRule};

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
const NFT_VPP_MAP:        &str = "vpp_mark";
/// nftables table for per-site backend DNAT: customer_view_ip -> real_ip.
const NFT_BNAT_TABLE:     &str = "ipsecnode_bnat";
/// nftables table for global port-based service routing on vpp-outer.
const NFT_SVCROUTE_TABLE: &str = "ipsecnode_svcroute";
/// nftables ct-helper object (kernel `ftp` ALG) for the FTP control-connection
/// PASV/227 rewrite (see setup_site_bnat / add_bnat_ftp_helper).
const NFT_BNAT_HELPER:       &str = "ftp_ctrl";
/// Raw-priority prerouting chain holding the per-site `ct helper set` rules.
const NFT_BNAT_HELPER_CHAIN: &str = "helperpre";
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
	/// Global backend server config (real_ip + port-split rules per role).
	/// Cloned from IpsecnodeConfig at startup; used in on_child_up.
	pub backend: BackendConfig,
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
	/// Per-site backend DNAT state (nftables bnat map + PREROUTING rule).
	pub bnat:            SiteBnatState,
	/// True = 'customer' bypass site (no VPP VRF/tap/NAT44; only bnat + a
	/// per-device `global_ip/32 dev xfrm-{hex}` return route). fwd_table/
	/// ret_table/tap_idx/vpp_tap/inner_if/ifindex are unused when set.
	pub bypass:          bool,
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

// -- SiteBnatState ------------------------------------------------------------

/// Per-site backend DNAT state: one nftables map + one PREROUTING rule.
/// An empty map_name means no backend NAT was configured for this site.
pub struct SiteBnatState {
	/// Per-site DNAT map name, e.g. "bnat_3eee6094" (customer_view -> real_ip).
	/// Empty = nothing set up.
	pub map_name:          String,
	/// nftables PREROUTING rule handle; None if the rule was not added.
	pub rule_handle:       Option<u64>,
	/// Per-site SNAT map name, e.g. "bsnat_3eee6094" (sd/em real_ip ->
	/// customer_view) for the 6g backend->device source-matched SNAT. Empty = not
	/// set up. The access_server is NOT in this map -- it is the default catch-all.
	pub snat_map_name:     String,
	/// nftables POSTROUTING SNAT rule handles (Increment 6g): the sd/em
	/// source-matched rule and/or the access_server default rule.
	pub snat_handles:      Vec<u64>,
	/// Per-site port-split regular chain name (e.g. "split_3eee6094"), holding
	/// the access_server-scoped port splits; None if no splits were installed.
	pub split_chain:       Option<String>,
	/// PREROUTING handle of the `iifname xfrm-{hex} jump split_{hex}` rule.
	pub split_jump_handle: Option<u64>,
	/// Handle of the per-site `ct helper set "ftp_ctrl"` rule in the mangle-priority
	/// helperpre chain (FTP control-connection PASV rewrite); None if not added.
	pub helper_handle:     Option<u64>,
	/// customer_view_ips installed as map keys (for logging on teardown).
	pub customer_view_ips: Vec<String>,
}

impl SiteBnatState {
	fn empty() -> Self {
		Self {
			map_name: String::new(), rule_handle: None,
			snat_map_name: String::new(), snat_handles: Vec::new(),
			split_chain: None, split_jump_handle: None,
			helper_handle: None,
			customer_view_ips: Vec::new(),
		}
	}
}

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
fn bnat_map_name(if_id: u32)  -> String { format!("bnat_{if_id:08x}")  }
fn bnat_snat_map_name(if_id: u32) -> String { format!("bsnat_{if_id:08x}") }
fn bnat_split_chain(if_id: u32) -> String { format!("split_{if_id:08x}") }
fn inner_tap_name(if_id: u32) -> String { format!("vpp-{if_id:08x}")  }

struct TapIps { vpp_ip: String, vpp_prefix: String, kern_ip: String, kern_prefix: String }

/// Derive tap /30 IPs from subnet index n within 10.127.0.0/16.
/// Subnet n: base = 10.127.{n>>6}.{(n&63)*4}; VPP = base+1, kernel = base+2.
fn tap_ips_from_idx(n: u32) -> TapIps {
	let o3 = n >> 6;
	let b  = (n & 63) * 4;
	TapIps {
		vpp_ip:      format!("10.127.{o3}.{}", b + 1),
		vpp_prefix:  format!("10.127.{o3}.{}/30", b + 1),
		kern_ip:     format!("10.127.{o3}.{}", b + 2),
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

pub(crate) async fn nft(args: &[&str]) -> Result<()> {
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

/// Run nft and return stdout (used when we need --echo --handle output).
async fn nft_capture(args: &[&str]) -> Result<String> {
	let out = tokio::process::Command::new("nft").args(args).output().await
		.with_context(|| format!("spawn nft {}", args.join(" ")))?;
	let stdout = String::from_utf8_lossy(&out.stdout).trim().to_string();
	if !out.status.success() {
		anyhow::bail!("nft {} failed: {}", args.join(" "),
			String::from_utf8_lossy(&out.stderr).trim());
	}
	Ok(stdout)
}

/// Parse the rule handle from `nft --echo --handle` output.
/// The last token after `# handle ` on the output line is the handle number.
fn parse_nft_handle(output: &str) -> Result<u64> {
	output
		.trim()
		.rsplit_once("# handle ")
		.and_then(|(_, tail)| tail.split_whitespace().next())
		.ok_or_else(|| anyhow::anyhow!("no '# handle' in nft output: {output}"))?
		.parse::<u64>()
		.context("parse nft rule handle")
}

pub(crate) async fn nft_batch(rules: &str) -> Result<()> {
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
	let _ = nft(&["delete", "table", "ip", NFT_BNAT_TABLE]).await;
	let _ = nft(&["delete", "table", "ip", NFT_SVCROUTE_TABLE]).await;
	// Remove the obsolete conntrack-zone table from a prior deployment. It forced
	// xfrm-* ingress into zone 1, which breaks 'customer' bypass sites (the
	// forward SYN ingresses ens5 in zone 0, so the return could not associate).
	// Identity NAT is now handled by VPP bypass, so no zoning is needed.
	let _ = nft(&["delete", "table", "ip", "ipsecnode_ctzone"]).await;
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

pub async fn init(backend: BackendConfig) -> Result<Option<VppState>> {
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
	init_nftables_bnat(&backend).await?;
	// Clear any stale conntrack entries (e.g. zone-tagged bindings left by a prior
	// deployment's ipsecnode_ctzone) so every flow is tracked in the single
	// default zone. Safe here: init() runs at startup before ipsecnode loads any
	// connection, so there is no active data flow yet.
	if let Err(e) = conntrack_flush().await {
		warn!("conntrack flush at init failed: {e:#} -- stale entries persist until they expire");
	}
	// The port splits (proxy pool + FTP) are installed per-site in the bnat split
	// chain (setup_site_bnat), scoped to the access_server view. The old global
	// ipsecnode_svcroute table on vpp-outer is gone (bypass mode never traversed
	// it); cleanup_stale_state() deletes any leftover copy on upgrade.

	info!(outer_tap, outer_kernel = VPP_OUTER_KERNEL,
		  "VPP NAT44 initialised (per-site VRF mode)");
	Ok(Some(VppState { outer_tap, backend }))
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

async fn init_nftables_bnat(backend: &BackendConfig) -> Result<()> {
	// POSTROUTING chain registers conntrack nat hooks required for the automatic
	// reverse SNAT (real_ip -> customer_view_ip) on return packets.
	// Per-site maps and PREROUTING rules are added per-site on CHILD_SA UP.
	let rules = format!(
		"add table ip {NFT_BNAT_TABLE}\n\
		 add chain ip {NFT_BNAT_TABLE} prerouting \
		   {{ type nat hook prerouting priority dstnat; policy accept; }}\n\
		 add chain ip {NFT_BNAT_TABLE} postrouting \
		   {{ type nat hook postrouting priority srcnat; policy accept; }}\n"
	);
	nft_batch(&rules).await.context("init nftables bnat table")?;

	// FTP control-connection ALG. Assign the kernel `ftp` conntrack helper to
	// port-21 control flows (per-site rules added in setup_site_bnat, scoped to
	// the access_view) so nf_nat_ftp rewrites the PASV/227 embedded IP from the
	// aeroftp VIP -- already normalised there by the LVM's ip_vs_ftp -- to the
	// per-site access_server customer_view. Works in BOTH bypass and VPP-VRF
	// modes because the customer_view->VIP DNAT lives on xfrm-{hex} in both; the
	// helper keys off that dest DNAT, never the (VPP) source SNAT.
	//
	// The helperpre chain is `mangle` priority (-150) -- NOT raw. nftables
	// `ct helper set` (unlike the iptables raw CT --helper target) does NOT
	// allocate a template conntrack; it assigns the helper to the EXISTING ct
	// (`nf_ct_get(skb)`), so it must run AFTER the conntrack hook (-200) or it is
	// a silent no-op. mangle (-150) runs after conntrack yet BEFORE dstnat (-100),
	// so the ct exists (helper attaches) and `ip daddr` is still the pre-DNAT
	// customer_view (the per-site rule matches). Modules are best-effort loaded
	// here (also in modules-load.d); the ct helper object needs nf_conntrack_ftp.
	let _ = modprobe("nf_conntrack_ftp").await;
	let _ = modprobe("nf_nat_ftp").await;
	let helper = format!(
		"add ct helper ip {NFT_BNAT_TABLE} {NFT_BNAT_HELPER} \
		   {{ type \"ftp\" protocol tcp; }}\n\
		 add chain ip {NFT_BNAT_TABLE} {NFT_BNAT_HELPER_CHAIN} \
		   {{ type filter hook prerouting priority mangle; policy accept; }}\n"
	);
	if let Err(e) = nft_batch(&helper).await {
		warn!("bnat ftp ct-helper setup failed (FTP PASV rewrite disabled): {e:#}");
	} else {
		info!(table = NFT_BNAT_TABLE, helper = NFT_BNAT_HELPER,
		      "nftables FTP ct-helper ready (PASV/227 rewrite)");
	}

	// Create the (initially empty) dynamic pool chains referenced by the
	// access_server splits. proxy_pool_task fills them; the per-site split chains
	// (added in setup_site_bnat, scoped to the access_view) jump to them.
	for binding in proxy_pool_bindings(backend) {
		let chain = pool_chain(&binding.name);
		if let Err(e) = nft_batch(&format!("add chain ip {NFT_BNAT_TABLE} {chain}\n")).await {
			warn!(pool = %binding.name, "bnat pool chain create failed: {e:#}");
		} else {
			info!(pool = %binding.name, %chain, "bnat dynamic pool chain created");
		}
	}
	info!(table = NFT_BNAT_TABLE, "nftables per-site backend DNAT table created");
	Ok(())
}

async fn conntrack_flush() -> Result<()> {
	let out = tokio::process::Command::new("conntrack")
		.arg("-F")
		.output().await.context("spawn conntrack -F")?;
	if !out.status.success() {
		anyhow::bail!("conntrack -F failed: {}", String::from_utf8_lossy(&out.stderr).trim());
	}
	Ok(())
}

/// Best-effort `modprobe <module>`. Returns Err on failure so callers can decide
/// whether it is fatal; used non-fatally for the FTP conntrack/NAT helpers.
async fn modprobe(module: &str) -> Result<()> {
	let out = tokio::process::Command::new("modprobe")
		.arg(module)
		.output().await.with_context(|| format!("spawn modprobe {module}"))?;
	if !out.status.success() {
		anyhow::bail!("modprobe {module}: {}", String::from_utf8_lossy(&out.stderr).trim());
	}
	Ok(())
}

// NOTE: the old `init_nftables_svcroute` (global port splits on vpp-outer) was
// removed. Bypass mode (customer NAT) forwards decapsulated traffic straight out
// ens5 and never traverses vpp-outer, so those global rules only ever applied to
// backend/VPP-VRF-mode traffic -- and even there they were global-by-port with
// the sd/em scoping problem. The port splits now live in the per-site bnat split
// chain (access_server-scoped -- see setup_site_bnat and AGENTS "PORT-SPLIT
// SCOPING CONTRACT"). cleanup_stale_state() still deletes any leftover
// ipsecnode_svcroute table so an upgraded-in-place node self-heals.
// TODO(backend-mode): if the VPP-VRF ('backend') path is ever used, it needs its
// own port splits on vpp-outer scoped by real_ip (the post-SNAT dst), not the
// old global-by-port rules.

/// nft port match for a split: an explicit `tcp dport { .. }` / `tcp sport { .. }`
/// list, or a contiguous `tcp dport <from>-<to>` range (passive-FTP data ports).
fn port_match(split: &SplitRule) -> Result<String> {
	if !split.ports.is_empty() {
		let p: Vec<String> = split.ports.iter().map(|n| n.to_string()).collect();
		Ok(format!("tcp dport {{ {} }}", p.join(", ")))
	} else if !split.src_ports.is_empty() {
		let p: Vec<String> = split.src_ports.iter().map(|n| n.to_string()).collect();
		Ok(format!("tcp sport {{ {} }}", p.join(", ")))
	} else if let (Some(f), Some(t)) = (split.port_from, split.port_to) {
		if f > t {
			anyhow::bail!("split rule port_from {f} > port_to {t}");
		}
		Ok(format!("tcp dport {f}-{t}"))
	} else {
		anyhow::bail!("split rule has no ports, src_ports, or port_from/port_to range");
	}
}

// -- Dynamic ECMP pools (proxy) ------------------------------------------------

/// nft regular chain that holds a dynamic pool's DNAT rule (in the bnat table).
fn pool_chain(pool: &str) -> String { format!("pool_{pool}") }

/// Valkey key carrying the membership snapshot for a dynamic pool
/// (written by ipsecscale on the LVS master).
fn pool_key(pool: &str) -> String { format!("fleetipsec:{pool}:pool") }

/// Rebuild a dynamic pool's DNAT chain from the current member set. Atomic:
/// one nft batch flushes then repopulates the chain. An empty set leaves the
/// chain with no rule, so matching traffic falls through to the role's real_ip.
/// New connections are ECMP-split by `jhash ip saddr` (source affinity); in-flight
/// connections stay pinned by conntrack.
pub async fn apply_proxy_pool(pool: &str, ips: &[String]) -> Result<()> {
	let chain = pool_chain(pool);
	let mut batch = format!("flush chain ip {NFT_BNAT_TABLE} {chain}\n");
	if ips.is_empty() {
		warn!(pool, %chain, "proxy pool EMPTY -- no DNAT (traffic falls back to real_ip)");
	} else {
		let n = ips.len();
		let elems: Vec<String> = ips.iter().enumerate()
			.map(|(i, ip)| format!("{i} : {ip}")).collect();
		batch += &format!(
			"add rule ip {NFT_BNAT_TABLE} {chain} \
			 dnat to jhash ip saddr mod {n} map {{ {} }}\n",
			elems.join(", "),
		);
	}
	nft_batch(&batch).await
		.with_context(|| format!("apply proxy pool {pool} ({} members)", ips.len()))?;
	info!(pool, members = ips.len(), "proxy pool DNAT chain updated");
	Ok(())
}

/// A dynamic pool declared in config: its name and its Valkey membership key.
#[derive(Debug, Clone)]
pub struct PoolBinding {
	pub name: String,
	pub key:  String,
}

/// Distinct dynamic pools referenced by any split in the backend config.
pub fn proxy_pool_bindings(backend: &BackendConfig) -> Vec<PoolBinding> {
	let mut seen = std::collections::BTreeSet::new();
	let mut out  = Vec::new();
	for role in ["access_server", "sd_server", "em_server"] {
		if let Some(server) = backend.server_for(role) {
			for split in &server.split {
				if let Some(pool) = &split.pool {
					if seen.insert(pool.clone()) {
						out.push(PoolBinding { name: pool.clone(), key: pool_key(pool) });
					}
				}
			}
		}
	}
	out
}

/// Membership snapshot written by ipsecscale to `fleetipsec:<pool>:pool`.
#[derive(serde::Deserialize)]
struct ProxyPoolSnapshot {
	#[serde(default)]
	gen: i64,
	#[serde(default)]
	ips: Vec<String>,
}

/// Consume proxy-pool membership snapshots from Valkey and keep the local
/// svcroute DNAT chains in sync. Reacts to keyspace SET/DEL events and
/// reconciles periodically as a backstop for missed events. Runs forever.
pub async fn proxy_pool_task(valkey_client: redis::Client, pools: Vec<PoolBinding>) {
	const RECONCILE_SECS: u64 = 30;
	let mut conn = match redis::aio::ConnectionManager::new(valkey_client.clone()).await {
		Ok(c)  => c,
		Err(e) => { error!("proxy_pool_task: Valkey connect failed: {e} -- exiting"); return; }
	};
	let mut last: HashMap<String, Vec<String>> = HashMap::new();
	for p in &pools { reconcile_pool(&mut conn, p, &mut last).await; }

	loop {
		let pubsub = match valkey_client.get_async_pubsub().await {
			Ok(ps) => ps,
			Err(e) => {
				error!("proxy_pool_task: pubsub open failed: {e} -- retry in 5 s");
				tokio::time::sleep(Duration::from_secs(5)).await;
				continue;
			}
		};
		match run_pool_pubsub(&mut conn, pubsub, &pools, &mut last, RECONCILE_SECS).await {
			Ok(())  => warn!("proxy_pool_task: pubsub stream ended -- reconnect in 5 s"),
			Err(e)  => error!("proxy_pool_task: pubsub loop error: {e:#} -- reconnect in 5 s"),
		}
		tokio::time::sleep(Duration::from_secs(5)).await;
	}
}

async fn run_pool_pubsub(
	conn:    &mut redis::aio::ConnectionManager,
	mut pubsub: redis::aio::PubSub,
	pools:   &[PoolBinding],
	last:    &mut HashMap<String, Vec<String>>,
	reconcile_secs: u64,
) -> Result<()> {
	use futures_util::StreamExt;
	pubsub.psubscribe("__keyevent@0__:set").await.context("psubscribe set")?;
	pubsub.psubscribe("__keyevent@0__:del").await.context("psubscribe del")?;
	info!("proxy pool pubsub active");
	let mut ticker = tokio::time::interval(Duration::from_secs(reconcile_secs));
	ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
	let mut stream = pubsub.on_message();
	loop {
		tokio::select! {
			msg = stream.next() => {
				let Some(msg) = msg else { return Ok(()); };
				let key: String = msg.get_payload().unwrap_or_default();
				if let Some(p) = pools.iter().find(|p| p.key == key) {
					reconcile_pool(conn, p, last).await;
				}
			}
			_ = ticker.tick() => {
				for p in pools { reconcile_pool(conn, p, last).await; }
			}
		}
	}
}

/// GET the pool snapshot, parse+sort it, and (only if changed) apply it.
async fn reconcile_pool(
	conn: &mut redis::aio::ConnectionManager,
	p:    &PoolBinding,
	last: &mut HashMap<String, Vec<String>>,
) {
	let raw: redis::RedisResult<Option<String>> = conn.get(&p.key).await;
	let ips = match raw {
		Ok(Some(json)) => match serde_json::from_str::<ProxyPoolSnapshot>(&json) {
			Ok(s) => {
				let mut v: Vec<String> = s.ips.into_iter()
					.filter(|ip| ip.parse::<std::net::Ipv4Addr>().is_ok())
					.collect();
				v.sort_by_key(|ip| ip.parse::<std::net::Ipv4Addr>().map(u32::from).unwrap_or(0));
				v.dedup();
				debug!(pool = %p.name, gen = s.gen, members = v.len(), "proxy pool snapshot");
				v
			}
			Err(e) => { warn!(pool = %p.name, "cannot parse proxy pool snapshot: {e}"); return; }
		},
		Ok(None) => { debug!(pool = %p.name, "no proxy pool snapshot -- treating as empty"); Vec::new() }
		Err(e)   => { warn!(pool = %p.name, "Valkey GET {} failed: {e}", p.key); return; }
	};
	if last.get(&p.name) == Some(&ips) {
		return; // no change since last apply
	}
	// Detect members that LEFT the pool: their device->proxy conntrack entries
	// (pinned by the pool_proxy jhash DNAT) still point at the departed proxy and
	// would black-hole in-flight flows. Flush conntrack on removal so those flows
	// re-hash to a survivor. NOT on scale-out (pinning keeps device sessions on
	// their proxy). See AGENTS Open TODO for the surgical (conntrack -D) variant.
	let had_removal = last.get(&p.name)
		.map(|prev| prev.iter().any(|ip| !ips.contains(ip)))
		.unwrap_or(false);
	if let Err(e) = apply_proxy_pool(&p.name, &ips).await {
		warn!(pool = %p.name, "apply proxy pool failed: {e:#}");
		return;
	}
	if had_removal {
		match conntrack_flush().await {
			Ok(())  => info!(pool = %p.name, "flushed conntrack after proxy removal (stale DNAT bindings)"),
			Err(e)  => warn!(pool = %p.name, "conntrack flush after proxy removal failed: {e:#}"),
		}
	}
	last.insert(p.name.clone(), ips);
}

// -- Per-CHILD_SA event handlers ----------------------------------------------

pub async fn on_child_up(
	conn:    &mut redis::aio::ConnectionManager,
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

	// Option 1: 'customer' sites need NO VPP NAT44 -- decapsulated traffic is
	// forwarded straight through (single kernel pass), which also sidesteps the
	// identity-NAT conntrack collision. Only 'backend' sites build the VPP VRF.
	if record.is_customer_mode() {
		match setup_site_bypass(peer_ip, if_id, &record, state).await {
			Ok(site) => {
				info!(peer_ip, vrf = if_id, devices = site.devices.len(),
				      "VPP bypass: customer-mode site active (no VRF/NAT44)");
				cache.insert(peer_ip.to_string(), site);
			}
			Err(e) => {
				warn!(peer_ip, "customer-mode setup failed: {e:#} -- freeing partial state");
				teardown_site_bypass_routes(if_id, &record).await;
			}
		}
		return;
	}

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
	if site.bypass {
		teardown_site_bypass(peer_ip, &site).await;
		return;
	}
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
	// `ip table add` is idempotent here: on an in-place restart the VPP fib table
	// can outlive cleanup_stale_state (which deletes taps, not tables), so tolerate
	// "already exists" -- a genuinely-down VPP surfaces on the next vppctl call.
	if let Err(e) = vppctl(&["ip", "table", "add", &vrf_str]).await {
		debug!(vrf = %vrf_str, "VPP ip table add tolerated (may already exist): {e:#}");
	}

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
		match install_device_nat(&vrf_str, &entry.internal_ip, &entry.global_ip,
		                         &tap_ips.kern_ip, &vpp_tap).await {
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

	// 9b. Outside default route in the site VRF (Increment 6g).
	//     Backend-initiated (o2i-first) NAT sessions re-look-up the device
	//     reply's destination in THIS VRF after i2o SNAT.  Without a route to
	//     the backend the reply hits null-node (dpo-drop) and is silently lost.
	//     Use a recursive "lookup in table 0" DPO -- do NOT use
	//     "via <ip> <vpp-outer>".  A cross-VRF next-hop adjacency (a route in
	//     fib N via an interface that lives in fib 0) SIGSEGVs VPP 26.06:
	//       adj_nbr_add_or_lock -> adj_delegate_adj_created -> ip_pmtu_get_ip
	//       -> fib_table_get_table_id_for_sw_if_index  (null deref)
	//     The lookup DPO does a second lookup in fib 0 instead, so no
	//     adjacency is created and the pmtu delegate never fires.
	//     The more-specific internal_ip/32 route (installed above by
	//     install_device_nat) still wins for the forward o2i direction, so
	//     device-initiated traffic is unaffected.
	//     del-then-add for the same fib-survives-cleanup reason as above.
	let _ = vppctl(&["ip", "route", "del", "0.0.0.0/0", "table", &vrf_str]).await;
	if let Err(e) = vppctl(&["ip", "route", "add", "0.0.0.0/0", "table", &vrf_str,
	                        "via", "lookup", "in", "table", "0"]).await {
		warn!(peer_ip, vrf = if_id,
		      "site-VRF lookup route add failed: {e:#} -- backend->device replies will drop");
	}

	// 10. Per-site backend DNAT (nftables bnat map + PREROUTING rule).
	let bnat = setup_site_bnat(
		peer_ip,
		if_id,
		record.backend_nat.as_ref(),
		&state.backend,
	).await;

	Ok(SiteVrfState {
		if_id, fwd_table, ret_table, tap_idx, vpp_tap,
		inner_if:        inner_if.to_string(),
		tap_vpp_ip:      tap_ips.vpp_ip.clone(),
		tap_kern_prefix: tap_ips.kern_prefix.clone(),
		ifindex, devices, bnat, bypass: false, child_sa_count: 1,
	})
}

async fn teardown_site_vrf(peer_ip: &str, site: &SiteVrfState) {
	// 0. Remove per-site backend DNAT before touching VPP NAT.
	teardown_site_bnat(peer_ip, &site.bnat).await;
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

	// 5b. Site-VRF recursive default route (added in setup_site_vrf step 9b).
	//     Must be removed before `ip table del` -- it references fib 0, not the
	//     per-site tap, so tap deletion above does not clear it.
	vppctl_warn(&["ip", "route", "del", "0.0.0.0/0", "table", &vrf_str,
	              "via", "lookup", "in", "table", "0"]).await;

	// 6. VPP fib table (now empty after tap + default-route deletion).
	vppctl_warn(&["ip", "table", "del", &vrf_str]).await;

	info!(peer_ip, vrf = site.if_id, "VPP: per-site VRF torn down");
}

// -- Customer-mode bypass (Option 1) ------------------------------------------
//
// 'customer' sites have addresses that are already unique in our view, so no VPP
// NAT44 is needed. Decapsulated traffic on xfrm-{hex} is forwarded straight out
// ens5 (device->backend, after the bnat DNAT) and backend->device is routed
// `dst=global_ip/32 dev xfrm-{hex}` -- a single kernel forwarding pass per
// direction. This avoids the VPP hairpin entirely, so the identity-NAT conntrack
// collision (global_ip == internal_ip) cannot occur. The 6g backend->device SNAT
// and the backend DNAT (setup_site_bnat) still apply, now single-pass.

async fn setup_site_bypass(
	peer_ip: &str,
	if_id:   u32,
	record:  &NatRecord,
	state:   &VppState,
) -> Result<SiteVrfState> {
	let xfrm_if = xfrm_if_name(if_id);

	// Per-device: route the (already unique) global_ip straight into the tunnel
	// interface, replacing the /32 blackhole installed by nat::on_child_up (6c).
	// In customer mode internal_ip == global_ip, so there is nothing to translate.
	let mut devices = Vec::new();
	for entry in &record.device_nat {
		match ip(&["route", "replace", &format!("{}/32", entry.global_ip),
		          "dev", &xfrm_if]).await {
			Ok(()) => {
				info!(peer_ip, global_ip = %entry.global_ip, xfrm = %xfrm_if,
				      "bypass: global_ip routed into tunnel (no NAT)");
				devices.push(DeviceVrfEntry {
					internal_ip: entry.internal_ip.clone(),
					global_ip:   entry.global_ip.clone(),
				});
			}
			Err(e) => warn!(peer_ip, global_ip = %entry.global_ip,
			                "bypass: global_ip route failed: {e:#}"),
		}
	}

	// Backend DNAT + 6g backend->device SNAT (single-pass in bypass mode).
	let bnat = setup_site_bnat(
		peer_ip,
		if_id,
		record.backend_nat.as_ref(),
		&state.backend,
	).await;

	Ok(SiteVrfState {
		if_id,
		fwd_table: 0, ret_table: 0, tap_idx: 0,
		vpp_tap:         String::new(),
		inner_if:        String::new(),
		tap_vpp_ip:      String::new(),
		tap_kern_prefix: String::new(),
		ifindex: 0,
		devices, bnat, bypass: true, child_sa_count: 1,
	})
}

async fn teardown_site_bypass(peer_ip: &str, site: &SiteVrfState) {
	teardown_site_bnat(peer_ip, &site.bnat).await;
	for d in &site.devices {
		// Revert to blackhole so nat::on_child_down then deletes it (mirrors the
		// VRF path's remove_device_nat).
		ip_warn(&["route", "replace", "blackhole", &format!("{}/32", d.global_ip)]).await;
	}
	info!(peer_ip, vrf = site.if_id, "VPP bypass: customer-mode site torn down");
}

/// Best-effort route cleanup after a partial setup_site_bypass failure.
async fn teardown_site_bypass_routes(_if_id: u32, record: &NatRecord) {
	for entry in &record.device_nat {
		ip_warn(&["route", "replace", "blackhole", &format!("{}/32", entry.global_ip)]).await;
	}
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

// -- Per-site backend DNAT (nftables bnat) -----------------------------------

async fn setup_site_bnat(
	peer_ip:     &str,
	if_id:       u32,
	backend_nat: Option<&BackendNatRecord>,
	backend:     &BackendConfig,
) -> SiteBnatState {
	let map_name = bnat_map_name(if_id);

	// Build (customer_view_ip, real_ip) pairs from Valkey roles + config roles.
	let mut pairs: Vec<(String, String)> = Vec::new();
	if let Some(rec) = backend_nat {
		for (role, view_ip) in rec.present_roles() {
			match backend.real_ip_for(role) {
				Some(real) => pairs.push((view_ip.to_string(), real.to_string())),
				None => warn!(peer_ip, role,
					"backend_nat role in Valkey has no real_ip in ipsecnode.toml -- skipping"),
			}
		}
	}
	if pairs.is_empty() {
		return SiteBnatState::empty();
	}

	// Create the per-site nftables map.
	if let Err(e) = nft(&[
		"add", "map", "ip", NFT_BNAT_TABLE, &map_name,
		"{ type ipv4_addr : ipv4_addr; }",
	]).await {
		warn!(peer_ip, "bnat map create failed: {e:#}");
		return SiteBnatState::empty();
	}

	// Add (customer_view_ip : real_ip) elements.
	let mut installed: Vec<String> = Vec::new();
	for (view_ip, real_ip) in &pairs {
		let elem = format!("{{ {view_ip} : {real_ip} }}");
		match nft(&["add", "element", "ip", NFT_BNAT_TABLE, &map_name, &elem]).await {
			Ok(()) => {
				info!(peer_ip, %view_ip, %real_ip, "backend NAT entry installed");
				installed.push(view_ip.clone());
			}
			Err(e) => warn!(peer_ip, %view_ip, "bnat element add failed: {e:#}"),
		}
	}
	if installed.is_empty() {
		nft_warn(&["delete", "map", "ip", NFT_BNAT_TABLE, &map_name]).await;
		return SiteBnatState::empty();
	}

	// Add the PREROUTING rule scoped to xfrm-{hex}.
	// ct state new: only new connections; conntrack handles ESTABLISHED replies
	// automatically (also required for the 6g backend->device SNAT to work).
	let xfrm_if = xfrm_if_name(if_id);

	// Per-site port splits, SCOPED to the access_server customer_view (sd/em
	// traffic is NEVER split -- see AGENTS "PORT-SPLIT SCOPING CONTRACT"). Built
	// as a regular chain jumped from PREROUTING BEFORE the default
	// customer_view->real_ip map rule; nf_nat once-only makes the specific split
	// win. Pool splits jump the shared dynamic pool_proxy chain; fixed splits
	// (FTP VIP) dnat inline. In bypass mode this is the ONLY place the splits
	// fire (there is no vpp-outer / svcroute hop).
	let (split_chain, split_jump_handle) =
		add_bnat_splits(peer_ip, if_id, &xfrm_if, backend_nat, backend).await;

	let map_ref = format!("@{map_name}");
	let rule_out = nft_capture(&[
		"--echo", "--handle",
		"add", "rule", "ip", NFT_BNAT_TABLE, "prerouting",
		"iifname", &xfrm_if,
		"ct", "state", "new",
		"dnat", "ip", "to", "ip", "daddr", "map", &map_ref,
	]).await;

	let rule_handle = match rule_out {
		Ok(out) => match parse_nft_handle(&out) {
			Ok(h)  => { info!(peer_ip, handle = h, "bnat PREROUTING rule added"); Some(h) }
			Err(e) => { warn!(peer_ip, "parse bnat rule handle: {e:#}"); None }
		},
		Err(e) => { warn!(peer_ip, "bnat PREROUTING rule add failed: {e:#}"); None }
	};

	// 6g: backend->device SNAT.  A backend server initiating a NEW connection to a
	// device egresses xfrm-{hex}; SNAT its source to that server's customer_view so
	// the customer firewall accepts it.
	//   - sd_server / em_server are SINGLE FIXED IPs (ipsecnode.toml real_ip), so
	//     they are source-matched via a map (real_ip -> customer_view).
	//   - access_server is the DEFAULT catch-all (no source scoping): its backend
	//     may present multiple/dynamic source IPs (proxy pool, scaled tasks), so any
	//     backend->device source that is NOT sd/em is SNAT'd to the access_view.
	// Rule order: sd/em map rule FIRST, access default AFTER -- nf_nat once-only
	// makes the specific sd/em match win; everything else falls to the default.
	// Discriminator `oifname xfrm-{hex} ct state new`: device forward-NEW flows
	// egress vpp-{hex}/ens5 (not xfrm), and device replies are ct-established.
	let (snat_map_name, snat_handles) =
		add_bnat_snat(peer_ip, if_id, &xfrm_if, backend_nat, backend).await;

	// FTP control-connection ALG: assign the `ftp` ct helper to port-21 flows to
	// the access_server view so nf_nat_ftp rewrites the PASV/227 IP to the
	// customer_view (the LVM already normalised it to the aeroftp VIP).
	let helper_handle = add_bnat_ftp_helper(peer_ip, &xfrm_if, backend_nat).await;

	SiteBnatState {
		map_name, rule_handle, snat_map_name, snat_handles,
		split_chain, split_jump_handle,
		helper_handle,
		customer_view_ips: installed,
	}
}

/// Build the per-site 6g backend->device SNAT rules. Two rules:
///
/// - an `ip saddr` map (sd/em fixed real_ip -> customer_view), matched first;
/// - a default `snat to <access_view>` catch-all for every other source.
///
/// Returns (map_name, rule_handles). map_name empty if no sd/em roles.
async fn add_bnat_snat(
	peer_ip:     &str,
	if_id:       u32,
	xfrm_if:     &str,
	backend_nat: Option<&BackendNatRecord>,
	backend:     &BackendConfig,
) -> (String, Vec<u64>) {
	let mut handles: Vec<u64> = Vec::new();

	// -- sd/em source-matched map (fixed IPs) ---------------------------------
	// (real_ip, customer_view) for every present role EXCEPT access_server.
	let mut sdem: Vec<(String, String)> = Vec::new();
	if let Some(rec) = backend_nat {
		for (role, view) in rec.present_roles() {
			if role == "access_server" { continue; }
			if let Some(real) = backend.real_ip_for(role) {
				sdem.push((real.to_string(), view.to_string()));
			}
		}
	}
	let mut snat_map = String::new();
	if !sdem.is_empty() {
		let map = bnat_snat_map_name(if_id);
		if let Err(e) = nft(&[
			"add", "map", "ip", NFT_BNAT_TABLE, &map, "{ type ipv4_addr : ipv4_addr; }",
		]).await {
			warn!(peer_ip, "bnat SNAT map create failed: {e:#}");
		} else {
			for (real_ip, view_ip) in &sdem {
				let elem = format!("{{ {real_ip} : {view_ip} }}");
				if let Err(e) = nft(&["add", "element", "ip", NFT_BNAT_TABLE, &map, &elem]).await {
					warn!(peer_ip, %real_ip, %view_ip, "bnat SNAT element add failed: {e:#}");
				} else {
					info!(peer_ip, %real_ip, %view_ip, "6g sd/em SNAT mapping installed");
				}
			}
			let map_ref = format!("@{map}");
			match nft_capture(&[
				"--echo", "--handle",
				"add", "rule", "ip", NFT_BNAT_TABLE, "postrouting",
				"oifname", xfrm_if, "ct", "state", "new",
				"snat", "ip", "to", "ip", "saddr", "map", &map_ref,
			]).await {
				Ok(o) => match parse_nft_handle(&o) {
					Ok(h)  => { info!(peer_ip, handle = h, roles = sdem.len(),
						"6g sd/em source-matched SNAT rule added"); handles.push(h); snat_map = map; }
					Err(e) => { warn!(peer_ip, "parse sd/em SNAT handle: {e:#}");
						nft_warn(&["delete", "map", "ip", NFT_BNAT_TABLE, &map]).await; }
				},
				Err(e) => { warn!(peer_ip, "sd/em SNAT rule add failed: {e:#}");
					nft_warn(&["delete", "map", "ip", NFT_BNAT_TABLE, &map]).await; }
			}
		}
	}

	// -- access_server default catch-all (no source scoping) ------------------
	if let Some(access_view) = backend_nat.and_then(|r| r.access_server.as_deref()) {
		match nft_capture(&[
			"--echo", "--handle",
			"add", "rule", "ip", NFT_BNAT_TABLE, "postrouting",
			"oifname", xfrm_if, "ct", "state", "new",
			"snat", "ip", "to", access_view,
		]).await {
			Ok(o) => match parse_nft_handle(&o) {
				Ok(h)  => { info!(peer_ip, handle = h, %access_view,
					"6g access_server default SNAT rule added"); handles.push(h); }
				Err(e) => warn!(peer_ip, "parse access SNAT handle: {e:#}"),
			},
			Err(e) => warn!(peer_ip, "access default SNAT rule add failed: {e:#}"),
		}
	}

	(snat_map, handles)
}

/// Build the per-site access_server-scoped port-split chain and its PREROUTING
/// jump. Returns (chain_name, jump_handle); both None if there is nothing to
/// split (no access_server role, or the role has no splits configured).
///
/// The split chain is jumped unconditionally for the site's xfrm interface;
/// each rule inside is scoped to `ip daddr <access_view>` + a port match, so
/// only the access_server's traffic on the split ports is diverted -- sd/em
/// customer_view traffic and all other ports fall through to the default
/// customer_view->real_ip map (added by the caller AFTER this jump).
/// Assign the kernel `ftp` conntrack helper to this site's FTP control channel
/// (tcp dport 21 to the access_server customer_view) in the mangle-priority
/// helperpre chain. This makes nf_nat_ftp rewrite the PASV/227 embedded IP --
/// already normalised to the aeroftp VIP by the LVM's ip_vs_ftp -- to the
/// per-site access_view, and installs the data-channel expectation. Scoped to
/// the access_view + port 21 per the PORT-SPLIT SCOPING CONTRACT (sd/em are
/// never touched). Returns the rule handle, or None if there is no access_view
/// or the assignment failed (non-fatal: FTP just keeps the wrong PASV IP).
async fn add_bnat_ftp_helper(
	peer_ip:     &str,
	xfrm_if:     &str,
	backend_nat: Option<&BackendNatRecord>,
) -> Option<u64> {
	let access_view = backend_nat.and_then(|r| r.access_server.as_deref())?;

	let out = nft_capture(&[
		"--echo", "--handle",
		"add", "rule", "ip", NFT_BNAT_TABLE, NFT_BNAT_HELPER_CHAIN,
		"iifname", xfrm_if,
		"ip", "daddr", access_view,
		"tcp", "dport", "21",
		"ct", "helper", "set", NFT_BNAT_HELPER,
	]).await;
	match out {
		Ok(o) => match parse_nft_handle(&o) {
			Ok(h) => {
				info!(peer_ip, %access_view, handle = h,
				      "FTP ct-helper assigned to port-21 control channel (PASV rewrite)");
				Some(h)
			}
			Err(e) => { warn!(peer_ip, "parse ftp helper rule handle: {e:#}"); None }
		},
		Err(e) => { warn!(peer_ip, "ftp ct-helper assign failed: {e:#}"); None }
	}
}

async fn add_bnat_splits(
	peer_ip:     &str,
	if_id:       u32,
	xfrm_if:     &str,
	backend_nat: Option<&BackendNatRecord>,
	backend:     &BackendConfig,
) -> (Option<String>, Option<u64>) {
	let Some(access_view) = backend_nat.and_then(|r| r.access_server.as_deref()) else {
		return (None, None);
	};
	let Some(srv) = backend.access_server.as_ref() else { return (None, None); };
	if srv.split.is_empty() {
		return (None, None);
	}

	let chain = bnat_split_chain(if_id);
	let mut batch = format!("add chain ip {NFT_BNAT_TABLE} {chain}\n");
	let mut rule_count = 0u32;
	for split in &srv.split {
		let pm = match port_match(split) {
			Ok(p)  => p,
			Err(e) => { warn!(peer_ip, "bnat split skipped: {e:#}"); continue; }
		};
		let target = if let Some(pool) = &split.pool {
			format!("jump {}", pool_chain(pool))
		} else if let Some(dnat_to) = &split.dnat_to {
			format!("dnat to {dnat_to}")
		} else {
			warn!(peer_ip, "bnat split has neither pool nor dnat_to -- skipping");
			continue;
		};
		batch += &format!(
			"add rule ip {NFT_BNAT_TABLE} {chain} ip daddr {access_view} {pm} {target}\n"
		);
		rule_count += 1;
	}
	if rule_count == 0 {
		return (None, None);
	}
	if let Err(e) = nft_batch(&batch).await {
		warn!(peer_ip, "bnat split chain create failed: {e:#}");
		return (None, None);
	}

	// Jump to the split chain from PREROUTING (before the default map rule the
	// caller adds next). Simple rule -> nft_capture argv is fine (no braces).
	let jump = nft_capture(&[
		"--echo", "--handle",
		"add", "rule", "ip", NFT_BNAT_TABLE, "prerouting",
		"iifname", xfrm_if, "jump", &chain,
	]).await;
	match jump {
		Ok(out) => match parse_nft_handle(&out) {
			Ok(h)  => {
				info!(peer_ip, %chain, handle = h, rules = rule_count, %access_view,
				      "bnat access_server port-split chain installed");
				(Some(chain), Some(h))
			}
			Err(e) => {
				warn!(peer_ip, "parse bnat split jump handle: {e:#}");
				nft_warn(&["delete", "chain", "ip", NFT_BNAT_TABLE, &chain]).await;
				(None, None)
			}
		},
		Err(e) => {
			warn!(peer_ip, "bnat split jump rule add failed: {e:#}");
			nft_warn(&["delete", "chain", "ip", NFT_BNAT_TABLE, &chain]).await;
			(None, None)
		}
	}
}

async fn teardown_site_bnat(peer_ip: &str, bnat: &SiteBnatState) {
	if bnat.map_name.is_empty() { return; }

	// Delete rules first (releases the map reference), then the map itself.
	for h in &bnat.snat_handles {
		let h_str = h.to_string();
		nft_warn(&["delete", "rule", "ip", NFT_BNAT_TABLE, "postrouting",
				   "handle", &h_str]).await;
		info!(peer_ip, handle = *h, "6g backend->device SNAT rule removed");
	}
	if !bnat.snat_map_name.is_empty() {
		nft_warn(&["delete", "map", "ip", NFT_BNAT_TABLE, &bnat.snat_map_name]).await;
	}
	if let Some(h) = bnat.rule_handle {
		let h_str = h.to_string();
		nft_warn(&["delete", "rule", "ip", NFT_BNAT_TABLE, "prerouting",
				   "handle", &h_str]).await;
		info!(peer_ip, handle = h, "bnat PREROUTING rule removed");
	}
	// Remove the FTP ct-helper assign rule (mangle-priority helperpre chain).
	if let Some(h) = bnat.helper_handle {
		let h_str = h.to_string();
		nft_warn(&["delete", "rule", "ip", NFT_BNAT_TABLE, NFT_BNAT_HELPER_CHAIN,
				   "handle", &h_str]).await;
		info!(peer_ip, handle = h, "FTP ct-helper rule removed");
	}
	// Remove the port-split jump (frees the split chain reference) then the chain.
	if let Some(h) = bnat.split_jump_handle {
		let h_str = h.to_string();
		nft_warn(&["delete", "rule", "ip", NFT_BNAT_TABLE, "prerouting",
				   "handle", &h_str]).await;
	}
	if let Some(chain) = &bnat.split_chain {
		nft_warn(&["delete", "chain", "ip", NFT_BNAT_TABLE, chain]).await;
		info!(peer_ip, %chain, "bnat port-split chain removed");
	}
	nft_warn(&["delete", "map", "ip", NFT_BNAT_TABLE, &bnat.map_name]).await;
	info!(peer_ip, map = %bnat.map_name,
		  entries = bnat.customer_view_ips.len(), "bnat map removed");
}

// -- Per-device NAT -----------------------------------------------------------

async fn install_device_nat(
	vrf_str:     &str,
	internal_ip: &str,
	global_ip:   &str,
	kern_ip:     &str,
	vpp_tap:     &str,
) -> Result<()> {
	// NAT44 static 1:1 mapping in the per-site VRF.
	// Note: VPP does NOT auto-insert a FIB entry for internal_ip in the VRF
	// when using the `vrf` parameter; we must add it explicitly (see below).
	vppctl(&[
		"nat44", "add", "static", "mapping",
		"local", internal_ip, "external", global_ip, "vrf", vrf_str,
	]).await.context("VPP nat44 add static mapping")?;

	// Explicit FIB route so VPP can forward the DNAT'd return packet
	// (dst=internal_ip) to the kernel via the per-site tap.  del-then-add: the
	// VPP fib table OUTLIVES cleanup_stale_state (which deletes taps + nat state
	// but NOT fib tables), so a route left by a prior process can survive here,
	// and a bare `ip route add` would APPEND a second, UNRESOLVED ECMP path (via
	// the deleted old tap, sometimes even another site's tap IP), turning the
	// route into a dpo-drop.  Deleting first keeps exactly one clean, resolvable
	// path.  Without this VPP has no usable route for internal_ip and drops it.
	let _ = vppctl(&["ip", "route", "del", &format!("{internal_ip}/32"), "table", vrf_str]).await;
	vppctl(&[
		"ip", "route", "add",
		&format!("{internal_ip}/32"),
		"table", vrf_str,
		"via", kern_ip, vpp_tap,
	]).await.context("VPP FIB route for internal_ip in site VRF")?;

	// Upgrade global_ip route: blackhole (6c) -> dev vpp-outer (return path).
	ip(&["route", "replace", &format!("{global_ip}/32"), "dev", VPP_OUTER_KERNEL])
		.await.context("ip route replace global_ip dev vpp-outer")?;
	Ok(())
}

async fn remove_device_nat(vrf_str: &str, internal_ip: &str, global_ip: &str) {
	// Revert to blackhole; nat::on_child_down will then delete it.
	ip_warn(&["route", "replace", "blackhole", &format!("{global_ip}/32")]).await;
	// Remove explicit FIB route for internal_ip.
	if let Err(e) = vppctl(&[
		"ip", "route", "del",
		&format!("{internal_ip}/32"),
		"table", vrf_str,
	]).await {
		warn!(internal_ip, vrf = vrf_str, "VPP FIB route del: {e:#}");
	}
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
	conn:    &mut redis::aio::ConnectionManager,
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
