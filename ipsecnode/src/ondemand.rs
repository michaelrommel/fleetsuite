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
use futures_util::StreamExt;
use redis::AsyncCommands;
use serde::{Deserialize, Serialize};
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

/// Valkey pub/sub channel for owner handoff: a non-owner that caught the trigger
/// publishes {owner, peer} here; the addressed owner initiates (phase 2b).
const INITIATE_CHANNEL: &str = "fleetipsec:initiate";

/// How often ipsecnode re-reads the LVS ring from Valkey.  The ring changes only
/// on a VPN scale event, so a slow poll is fine and costs no AWS calls.
const RING_REFRESH: Duration = Duration::from_secs(30);

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

/// Handoff message on INITIATE_CHANNEL: the computed jhash `owner` should
/// initiate the tunnel to `peer` (customer gateway public IP).
#[derive(Serialize, Deserialize)]
struct Handoff {
	owner: String,
	peer:  String,
}

/// Work item consumed by the single ondemand task loop.
enum Trigger {
	/// NFQUEUE caught a backend->device packet; value is the destination global_ip.
	Local(Ipv4Addr),
	/// Another node handed this site's peer_ip to us because we are its jhash owner.
	HandedOff(String),
}

/// Where an on-demand trigger should be actioned.
enum Decision {
	/// Initiate here.
	Local,
	/// Hand off to the jhash owner at this IP.
	HandOff(String),
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

/// Reconcile the active_globals set to EXACTLY `desired` in a single atomic
/// nftables transaction (flush + add applied together, so the datapath never
/// observes an empty set -- active clients are undisturbed).  Used at startup to
/// drop entries left stale by a prior process while keeping every currently-up
/// tunnel.  No-op if on-demand is disabled.
pub async fn replace_active_globals(desired: &std::collections::HashSet<String>) {
	if !ENABLED.load(Ordering::SeqCst) { return; }
	let mut batch = format!("flush set ip {NFT_TABLE} {NFT_ACTIVE_SET}\n");
	if !desired.is_empty() {
		let elems = desired.iter().cloned().collect::<Vec<_>>().join(", ");
		batch.push_str(&format!("add element ip {NFT_TABLE} {NFT_ACTIVE_SET} {{ {elems} }}\n"));
	}
	match crate::vpp::nft_batch(&batch).await {
		Ok(())  => info!(live = desired.len(), "on-demand: active_globals reconciled to live tunnels"),
		Err(e)  => warn!("on-demand: active_globals reconcile failed: {e:#}"),
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

/// On-demand bring-up task: drain the NFQUEUE and the handoff channel, pick the
/// jhash owner, and initiate the CHILD_SA on the right node (deduplicated).
pub async fn ondemand_task(
	vici_socket:   String,
	valkey_client: redis::Client,
	owner:         OwnerMode,
	my_ip:         Option<String>,
) {
	let mut vk = match valkey_client.get_multiplexed_async_connection().await {
		Ok(c)  => c,
		Err(e) => { warn!("on-demand: Valkey connect failed: {e} -- task exiting"); return; }
	};

	// Unified trigger channel: NFQUEUE reader (Local) + handoff subscriber (HandedOff).
	let (tx, mut rx) = mpsc::channel::<Trigger>(1024);

	// Blocking NFQUEUE reader on a dedicated OS thread.
	let nfq_tx = tx.clone();
	std::thread::Builder::new()
		.name("nfq-reader".into())
		.spawn(move || nfq_reader_loop(QUEUE_NUM, nfq_tx))
		.expect("spawn nfq-reader thread");

	// Handoff subscriber (only useful when we know our own pool IP).
	if let Some(ip) = my_ip.clone() {
		tokio::spawn(initiate_sub_task(valkey_client.clone(), ip, tx.clone()));
	}

	let mut ring = get_ring(&mut vk).await;
	let mut refresh = tokio::time::interval(RING_REFRESH);
	refresh.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
	info!(?owner, my_ip = ?my_ip, ring_nodes = ring.as_ref().map(|r| r.nodes.len()),
	      "on-demand task running");

	let mut inflight: HashMap<String, Instant> = HashMap::new();

	loop {
		tokio::select! {
			_ = refresh.tick() => {
				if let Some(r) = get_ring(&mut vk).await { ring = Some(r); }
			}
			msg = rx.recv() => {
				let Some(trigger) = msg else {
					warn!("on-demand: trigger channel closed -- task exiting");
					return;
				};
				let now = Instant::now();
				inflight.retain(|_, t| now.duration_since(*t) < INFLIGHT_TTL);

				let peer = match trigger {
					Trigger::HandedOff(peer) => peer,      // we are the owner by construction
					Trigger::Local(dst) => {
						let Some(peer) = resolve_peer(&mut vk, dst).await else { continue };
						match decide(owner, &ring, &my_ip, &peer) {
							Decision::Local => peer,
							Decision::HandOff(owner_ip) => {
								let payload = serde_json::to_string(
									&Handoff { owner: owner_ip.clone(), peer: peer.clone() }
								).unwrap_or_default();
								let r: redis::RedisResult<i64> =
									vk.publish(INITIATE_CHANNEL, payload).await;
								match r {
									Ok(_)  => info!(%dst, %peer, owner = %owner_ip,
									                "on-demand: handed off to jhash owner"),
									Err(e) => warn!(%peer, owner = %owner_ip,
									                "on-demand: handoff publish failed: {e}"),
								}
								continue;
							}
						}
					}
				};

				if inflight.contains_key(&peer) {
					debug!(%peer, "on-demand: initiate already in flight -- skipping");
					continue;
				}
				inflight.insert(peer.clone(), now);
				spawn_initiate(vici_socket.clone(), peer);
			}
		}
	}
}

/// Decide whether this node initiates the tunnel or hands it to the jhash owner.
fn decide(mode: OwnerMode, ring: &Option<ipseccore::LvsRing>, my_ip: &Option<String>, peer: &str) -> Decision {
	let OwnerMode::Jhash = mode else { return Decision::Local };
	// Need the ring, our own pool IP, and a parseable customer IP; else degrade to
	// approach (a) -- initiate locally (still correct, just not owner-optimal).
	let (Some(ring), Some(my_ip)) = (ring, my_ip) else { return Decision::Local };
	let Ok(ip) = peer.parse::<Ipv4Addr>() else { return Decision::Local };
	match ipseccore::owner_of(ip, &ring.nodes) {
		Some(o) if o == my_ip => Decision::Local,
		Some(o)               => Decision::HandOff(o.to_string()),
		None                  => Decision::Local,
	}
}

/// Fire a bounded VICI initiate of `site-<peer>` on its own short-lived VICI
/// connection (concurrent-safe; dedup is handled by the caller).
fn spawn_initiate(vici_socket: String, peer: String) {
	let child = vici::conn_id(&peer);
	info!(%peer, %child, "on-demand: initiating CHILD_SA");
	tokio::spawn(async move {
		match vici::connect_with_retry(&vici_socket, 5).await {
			Ok(mut c) => match vici::initiate_child(&mut c, &child, INITIATE_TIMEOUT_MS).await {
				Ok(())  => info!(%child, "on-demand initiate returned (CHILD up or timed out)"),
				Err(e)  => warn!(%child, "on-demand initiate failed: {e:#}"),
			},
			Err(e) => warn!(%child, "on-demand: VICI connect failed: {e:#}"),
		}
	});
}

/// Read the current LVS ring from Valkey (None if absent/unparseable, in which
/// case Jhash owner selection degrades to local initiate).
async fn get_ring(vk: &mut redis::aio::MultiplexedConnection) -> Option<ipseccore::LvsRing> {
	let json: redis::RedisResult<Option<String>> = vk.get(ipseccore::LVSRING_KEY).await;
	match json {
		Ok(Some(j)) => match serde_json::from_str(&j) {
			Ok(r)  => Some(r),
			Err(e) => { warn!("on-demand: cannot parse {}: {e}", ipseccore::LVSRING_KEY); None }
		},
		Ok(None) => None,
		Err(e)   => { debug!("on-demand: GET {} failed: {e}", ipseccore::LVSRING_KEY); None }
	}
}

/// Subscribe to INITIATE_CHANNEL and forward handoffs addressed to this node
/// (owner == my_ip) into the task's trigger channel.
async fn initiate_sub_task(valkey_client: redis::Client, my_ip: String, tx: mpsc::Sender<Trigger>) {
	let mut pubsub = match valkey_client.get_async_pubsub().await {
		Ok(p)  => p,
		Err(e) => { warn!("on-demand: handoff pubsub connect failed: {e} -- disabled"); return; }
	};
	if let Err(e) = pubsub.subscribe(INITIATE_CHANNEL).await {
		warn!("on-demand: subscribe {INITIATE_CHANNEL} failed: {e} -- handoff disabled");
		return;
	}
	info!(channel = INITIATE_CHANNEL, %my_ip, "on-demand: handoff subscriber running");
	let mut stream = pubsub.on_message();
	while let Some(msg) = stream.next().await {
		let payload: String = match msg.get_payload() { Ok(p) => p, Err(_) => continue };
		if let Ok(h) = serde_json::from_str::<Handoff>(&payload) {
			if h.owner == my_ip && tx.send(Trigger::HandedOff(h.peer)).await.is_err() {
				return;
			}
		}
	}
	warn!("on-demand: handoff subscriber stream ended");
}

/// Blocking loop: receive packets from NFQUEUE, DROP them (the sender
/// retransmits once the tunnel is up), and forward the parsed IPv4 destination
/// to the async handler.  Reopens the queue on error with a short backoff.
fn nfq_reader_loop(queue_num: u16, tx: mpsc::Sender<Trigger>) {
	loop {
		if let Err(e) = nfq_reader_once(queue_num, &tx) {
			warn!("on-demand: NFQUEUE reader error: {e} -- reopening in 2s");
			std::thread::sleep(Duration::from_secs(2));
		}
		if tx.is_closed() { return; }
	}
}

fn nfq_reader_once(queue_num: u16, tx: &mpsc::Sender<Trigger>) -> Result<()> {
	use nfq::{Queue, Verdict};
	let mut queue = Queue::open()?;
	queue.bind(queue_num)?;
	loop {
		let mut msg = queue.recv()?;
		let dst = parse_ipv4_dst(msg.get_payload());
		msg.set_verdict(Verdict::Drop);
		queue.verdict(msg)?;
		if let Some(d) = dst {
			if tx.blocking_send(Trigger::Local(d)).is_err() { return Ok(()); }
		}
	}
}

/// Extract the IPv4 destination from a raw IPv4 packet (the NFQUEUE payload
/// starts at the IP header).  None if it is not a valid IPv4 header.
fn parse_ipv4_dst(pkt: &[u8]) -> Option<Ipv4Addr> {
	if pkt.len() < 20 || (pkt[0] >> 4) != 4 { return None; }
	Some(Ipv4Addr::new(pkt[16], pkt[17], pkt[18], pkt[19]))
}
