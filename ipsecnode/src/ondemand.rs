//! Increment 6g phase 2 -- on-demand tunnel bring-up (backend-initiated).
//!
//! When a backend server sends traffic to a device whose tunnel is DOWN, the
//! packet is attracted to some concentrator by the covering aggregate the
//! concentrators advertise (see fleetnode/fleetroute frr.conf).  On the
//! concentrator it arrives on ens5 with an un-provisioned customer global_ip as
//! destination.  An nftables prerouting rule NFQUEUEs the FIRST such packet to
//! this task, which:
//!   1. reverse-maps global_ip -> site peer_ip via the shared device hash
//!        HGET systems:by-ip:<global_ip> gw  ->  <peer_ip>
//!   2. DROPs the packet (the sender retransmits once the tunnel is up), and
//!   3. VICI-initiates the CHILD_SA `site-<peer_ip>` (deduplicated per peer).
//!
//! Initiating the CHILD (not just the IKE) is REQUIRED so charon fires a
//! child-updown UP event; the existing handler then installs the data plane
//! (bypass or VPP VRF) exactly as for a site-initiated tunnel -- on_child_up is
//! direction-agnostic, so no initiator-specific code is needed downstream.
//!
//! Owner selection (Architecture Decision #17, P2):
//!   - OwnerMode::Any   (phase 2a, default) -- whichever concentrator the Return
//!     GW's ECMP delivered the packet to initiates; the LVS conntrack returns
//!     the customer's IKE reply to it.  This is the break-test baseline.
//!   - OwnerMode::Jhash (phase 2b, later)   -- initiate only from the
//!     jhash(customer_ip) owner, handing off otherwise.  Wired behind the same
//!     IPSECNODE_ONDEMAND_OWNER toggle so we can flip a/b without a rebuild.

use std::collections::HashMap;
use std::net::Ipv4Addr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::Result;
use redis::AsyncCommands;
use tokio::sync::mpsc;
use tracing::{debug, info, warn};

use crate::vici;

const NFT_TABLE:      &str = "ipsecnode_ondemand";
const NFT_ACTIVE_SET: &str = "active_globals";
const QUEUE_NUM:      u16  = 0;
const OUTER_IF:       &str = "ens5";

/// Backend/AWS-side networks that must NEVER be treated as a customer global_ip
/// (mirrors the frr complement): this VPC, the future AWS base, and link-local
/// (IMDS / Amazon Time Sync).
const PROTECTED_NETS: &str = "172.16.0.0/16, 10.183.0.0/16, 169.254.0.0/16";

/// Per-peer de-dupe window: ignore repeat triggers (SYN retransmits, several
/// devices on one site) for this long after we kick an initiate.
const INFLIGHT_TTL: Duration = Duration::from_secs(30);

/// Bound on the blocking VICI initiate call (charon returns after this even if
/// the peer never answers).
const INITIATE_TIMEOUT_MS: u32 = 20_000;

/// Set true by init_nftables(); gates active_globals maintenance so nat.rs
/// calls are no-ops when on-demand is disabled (the nft table is absent).
static ENABLED: AtomicBool = AtomicBool::new(false);

/// Owner-selection policy (P2).  See module docs.
#[derive(Clone, Copy, Debug)]
pub enum OwnerMode { Any, Jhash }

impl OwnerMode {
	pub fn from_env() -> Self {
		match std::env::var("IPSECNODE_ONDEMAND_OWNER").ok().as_deref() {
			Some("jhash") => OwnerMode::Jhash,
			_             => OwnerMode::Any,
		}
	}
}

/// True unless IPSECNODE_ONDEMAND=0 -- lets us run the new binary with on-demand
/// bring-up disabled (attraction/routing only) for staged A/B testing.
pub fn is_enabled() -> bool {
	std::env::var("IPSECNODE_ONDEMAND").map(|v| v != "0").unwrap_or(true)
}

/// Create the ipsecnode_ondemand nft table: an empty active_globals set plus a
/// prerouting rule that queues the FIRST packet of any backend->device flow to
/// an un-provisioned (down-tunnel) customer global_ip to this task.
///
/// Match: ingress ens5 (backend transit from the Return GW), dst is a customer
/// global_ip (NOT one of our protected nets), the tunnel is NOT already up (dst
/// not in @active_globals), and it is a new flow.  `bypass` = if this task is
/// not listening the packet is accepted, never blackholed at the queue.
pub async fn init_nftables() -> Result<()> {
	let rules = format!(
		"add table ip {NFT_TABLE}\n\
		 add set ip {NFT_TABLE} {NFT_ACTIVE_SET} {{ type ipv4_addr; }}\n\
		 add chain ip {NFT_TABLE} prerouting \
		   {{ type filter hook prerouting priority mangle; policy accept; }}\n\
		 add rule ip {NFT_TABLE} prerouting \
		   iifname \"{OUTER_IF}\" \
		   ip daddr != {{ {PROTECTED_NETS} }} \
		   ip daddr != @{NFT_ACTIVE_SET} \
		   ct state new \
		   queue num {QUEUE_NUM} bypass\n"
	);
	crate::vpp::nft_batch(&rules).await?;
	ENABLED.store(true, Ordering::SeqCst);
	info!(table = NFT_TABLE, queue = QUEUE_NUM, iface = OUTER_IF,
	      "on-demand NFQUEUE attraction rule installed");
	Ok(())
}

/// Mark a global_ip as active (tunnel up) so the NFQUEUE rule stops matching it.
/// Called from nat::on_child_up for every device_nat entry.  No-op if disabled.
pub async fn add_active_global(global_ip: &str) {
	if !ENABLED.load(Ordering::SeqCst) { return; }
	let elem = format!("{{ {global_ip} }}");
	if let Err(e) = crate::vpp::nft(
		&["add", "element", "ip", NFT_TABLE, NFT_ACTIVE_SET, &elem]).await {
		warn!(global_ip, "on-demand: add active_global failed: {e:#}");
	}
}

/// Remove a global_ip from the active set (tunnel down) so future backend
/// traffic re-triggers an on-demand initiate.  No-op if disabled.
pub async fn remove_active_global(global_ip: &str) {
	if !ENABLED.load(Ordering::SeqCst) { return; }
	let elem = format!("{{ {global_ip} }}");
	if let Err(e) = crate::vpp::nft(
		&["delete", "element", "ip", NFT_TABLE, NFT_ACTIVE_SET, &elem]).await {
		debug!(global_ip, "on-demand: delete active_global failed (may be gone): {e:#}");
	}
}

/// Reverse-map a packet's destination global_ip to the site peer_ip (customer
/// gateway public IP) via the shared device hash written by the fleetshell
/// device spooler:  HGET systems:by-ip:<global_ip> gw  ->  <peer_ip>.
async fn resolve_peer(
	vk:  &mut redis::aio::MultiplexedConnection,
	gip: Ipv4Addr,
) -> Option<String> {
	let key = format!("systems:by-ip:{gip}");
	let res: redis::RedisResult<Option<String>> = vk.hget(&key, "gw").await;
	match res {
		Ok(Some(peer)) if !peer.is_empty() => Some(peer),
		Ok(_)  => { debug!(%gip, "on-demand: no gw field in {key}"); None }
		Err(e) => { warn!(%gip, "on-demand: HGET {key} gw failed: {e}"); None }
	}
}

/// On-demand bring-up task: drain the NFQUEUE, reverse-map each un-provisioned
/// destination to its site, and initiate the CHILD_SA (deduplicated per peer).
pub async fn ondemand_task(
	vici_socket:   String,
	valkey_client: redis::Client,
	owner:         OwnerMode,
) {
	let mut vk = match valkey_client.get_multiplexed_async_connection().await {
		Ok(c)  => c,
		Err(e) => { warn!("on-demand: Valkey connect failed: {e} -- task exiting"); return; }
	};

	// Blocking NFQUEUE reader on a dedicated OS thread -> async channel of dsts.
	let (tx, mut rx) = mpsc::channel::<Ipv4Addr>(1024);
	std::thread::Builder::new()
		.name("nfq-reader".into())
		.spawn(move || nfq_reader_loop(QUEUE_NUM, tx))
		.expect("spawn nfq-reader thread");

	info!(?owner, "on-demand task running");
	let mut inflight: HashMap<String, Instant> = HashMap::new();

	while let Some(dst) = rx.recv().await {
		let now = Instant::now();
		inflight.retain(|_, t| now.duration_since(*t) < INFLIGHT_TTL);

		let peer = match resolve_peer(&mut vk, dst).await {
			Some(p) => p,
			None    => continue,
		};

		if inflight.contains_key(&peer) {
			debug!(%dst, %peer, "on-demand: initiate already in flight -- skipping");
			continue;
		}

		// Owner selection (P2).  Approach (a): any node that caught the packet
		// initiates.  Approach (b) (jhash owner + handoff) branches here later.
		match owner {
			OwnerMode::Any => {}
			OwnerMode::Jhash => {
				// TODO(6g phase 2b): if this node is not jhash(peer) owner, hand
				// off to the owner (Valkey signal) instead of initiating locally.
			}
		}

		inflight.insert(peer.clone(), now);
		let child = vici::conn_id(&peer);
		let sock  = vici_socket.clone();
		info!(%dst, %peer, %child, "on-demand: initiating CHILD_SA");
		tokio::spawn(async move {
			match vici::connect_with_retry(&sock, 5).await {
				Ok(mut c) => match vici::initiate_child(&mut c, &child, INITIATE_TIMEOUT_MS).await {
					Ok(())  => info!(%child, "on-demand initiate returned (CHILD up or timed out)"),
					Err(e)  => warn!(%child, "on-demand initiate failed: {e:#}"),
				},
				Err(e) => warn!(%child, "on-demand: VICI connect failed: {e:#}"),
			}
		});
	}
	warn!("on-demand: NFQUEUE channel closed -- task exiting");
}

/// Blocking loop: receive packets from NFQUEUE, DROP them (the sender
/// retransmits once the tunnel is up), and forward the parsed IPv4 destination
/// to the async handler.  Reopens the queue on error with a short backoff.
fn nfq_reader_loop(queue_num: u16, tx: mpsc::Sender<Ipv4Addr>) {
	loop {
		if let Err(e) = nfq_reader_once(queue_num, &tx) {
			warn!("on-demand: NFQUEUE reader error: {e} -- reopening in 2s");
			std::thread::sleep(Duration::from_secs(2));
		}
		if tx.is_closed() { return; }
	}
}

fn nfq_reader_once(queue_num: u16, tx: &mpsc::Sender<Ipv4Addr>) -> Result<()> {
	use nfq::{Queue, Verdict};
	let mut queue = Queue::open()?;
	queue.bind(queue_num)?;
	loop {
		let mut msg = queue.recv()?;
		let dst = parse_ipv4_dst(msg.get_payload());
		msg.set_verdict(Verdict::Drop);
		queue.verdict(msg)?;
		if let Some(d) = dst {
			if tx.blocking_send(d).is_err() { return Ok(()); }
		}
	}
}

/// Extract the IPv4 destination from a raw IPv4 packet (the NFQUEUE payload
/// starts at the IP header).  None if it is not a valid IPv4 header.
fn parse_ipv4_dst(pkt: &[u8]) -> Option<Ipv4Addr> {
	if pkt.len() < 20 || (pkt[0] >> 4) != 4 { return None; }
	Some(Ipv4Addr::new(pkt[16], pkt[17], pkt[18], pkt[19]))
}
