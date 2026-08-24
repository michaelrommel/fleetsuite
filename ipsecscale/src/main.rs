//! ipsecscale -- VPN concentrator autoscaling daemon (runs on the IPSec LVS nodes).
//!
//! Implemented so far (role read from /run/ipsec-role each cycle):
//!
//!   A. Proxy-pool reconciler (MASTER ONLY -- shared Valkey key, single writer):
//!      discover ready fleetproxy members and publish fleetipsec:<pool>:pool to
//!      Valkey; each VPN node's ipsecnode consumes it and rebuilds its local
//!      svcroute ECMP DNAT chain. The scaler never touches VPN-node nft directly
//!      -- Valkey is the bus.
//!
//!   B. VPN-NAT watcher (BOTH ROLES -- local rule, aeroftp pattern): watch the
//!      VPN concentrator ASG membership and, when it changes (e.g. you cycle a
//!      concentrator), re-render + hot-reload THIS LVS node's `ip nat` jhash
//!      table (/etc/nftables.d/ipsec-nat.nft) so new customers hash across the
//!      current node set. Run on the backup too so its local table is always
//!      ready for an instant VRRP takeover (it keys on the node's OWN secondary
//!      IP, so it renders exactly the table it will need once promoted).
//!      Rendered via the shared `ipseccore` crate so it is byte-identical to
//!      ipsecpulse's boot render (same jhash seed -- Architecture Decision #1).
//!
//! NOT yet implemented: the scale-out/in DECISION (SetDesiredCapacity on the VPN
//! ASG based on tunnel counts). This daemon only reconciles membership -> config.

use std::collections::BTreeSet;
use std::net::{Ipv4Addr, SocketAddr};
use std::os::unix::fs::PermissionsExt;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use clap::Parser;
use redis::AsyncCommands;
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tracing::{debug, info, warn};

use aerocore::{aws_query, extract_all_scalars, fetch_imds_credentials, AwsCredentials};

#[derive(Parser, Debug, Clone)]
#[command(name = "ipsecscale", about = "IPSec LVS autoscaling / pool reconciler")]
struct Args {
	#[arg(long, env = "REGION", default_value = "eu-west-2")]
	region: String,

	#[arg(
		long,
		env = "VALKEY_URL",
		default_value = "rediss://clustercfg.dev-valkey-aeroftp.ak121m.memorydb.eu-west-2.amazonaws.com:6379"
	)]
	valkey_url: String,

	/// VRRP role file written by ipsecpulse notify scripts. Only "master" acts.
	#[arg(long, env = "ROLE_FILE", default_value = "/run/ipsec-role")]
	role_file: String,

	// -- Proxy pool (A) --------------------------------------------------------
	#[arg(long, env = "PROXY_ASG", default_value = "fleetshell-proxy-asg")]
	proxy_asg: String,
	/// TCP port to health-probe on each proxy before including it (Squid :8080).
	#[arg(long, env = "PROXY_PORT", default_value_t = 8080)]
	proxy_port: u16,
	/// Backend subnet CIDRs carrying the proxy eth0 (DNAT-target) IPs; excludes
	/// the eth1 proxy-out egress IPs.
	#[arg(long, env = "PROXY_BACKEND_CIDRS", default_value = "172.16.53.0/24,172.16.54.0/24")]
	backend_cidrs: String,
	/// Pool name; the Valkey key is fleetipsec:<pool>:pool.
	#[arg(long, env = "PROXY_POOL_NAME", default_value = "proxy")]
	pool_name: String,
	/// Per-instance health-probe timeout in milliseconds (connect + HTTP reply).
	#[arg(long, env = "PROXY_PROBE_TIMEOUT_MS", default_value_t = 1500)]
	probe_timeout_ms: u64,

	// -- VPN NAT watcher (B) ---------------------------------------------------
	/// ipsecpulse boot state (source of the VIP secondary IP + VPN ASG name).
	#[arg(long, env = "STATE_FILE", default_value = "/run/ipsecpulse.state")]
	state_file: String,
	/// The LVS `ip nat` jhash table file (regenerated on VPN membership change).
	#[arg(long, env = "NAT_FILE", default_value = "/etc/nftables.d/ipsec-nat.nft")]
	nat_file: String,
	/// Disable the VPN-NAT watcher (leave ipsec-nat.nft to ipsecpulse only).
	#[arg(long, env = "NO_VPN_NAT", default_value_t = false)]
	no_vpn_nat: bool,

	/// Seconds between reconcile cycles.
	#[arg(long, env = "RECONCILE_INTERVAL_SECS", default_value_t = 15)]
	interval: u64,
}

/// The proxy snapshot written to Valkey (consumed by ipsecnode's proxy_pool_task).
#[derive(Serialize)]
struct PoolSnapshot {
	gen: u64,
	ips: Vec<String>,
}

/// The subset of ipsecpulse's /run/ipsecpulse.state that the VPN-NAT watcher
/// needs. serde ignores the other fields.
#[derive(Deserialize)]
struct PulseState {
	instance_id: String,
	eth0_secondary_ip: String,
	vpn_asg_name: String,
}

// ── CIDR helpers (avoid an ipnet dep) ─────────────────────────────────────────

fn ip_to_u32(ip: &str) -> Option<u32> {
	ip.parse::<Ipv4Addr>().ok().map(u32::from)
}

/// Parse "a.b.c.d/len" -> (network base masked, mask).
fn parse_cidr(cidr: &str) -> Option<(u32, u32)> {
	let (addr, len) = cidr.split_once('/')?;
	let base = ip_to_u32(addr.trim())?;
	let len: u32 = len.trim().parse().ok()?;
	if len > 32 { return None; }
	let mask = if len == 0 { 0 } else { u32::MAX << (32 - len) };
	Some((base & mask, mask))
}

fn cidr_contains(cidrs: &[(u32, u32)], ip: u32) -> bool {
	cidrs.iter().any(|&(base, mask)| ip & mask == base)
}

// ── AWS discovery ─────────────────────────────────────────────────────────────

/// Private IPs of running instances in an ASG, optionally filtered to a set of
/// CIDRs (used to pick the eth0 IP and drop dual-homed secondary NICs), sorted
/// numerically for stable jhash / ECMP indices.
async fn describe_asg_ips(
	region: &str,
	creds:  &AwsCredentials,
	asg_name: &str,
	cidr_filter: Option<&[(u32, u32)]>,
) -> Result<Vec<String>> {
	let host = format!("ec2.{region}.amazonaws.com");
	let xml = aws_query(&host, "ec2", region, creds, &[
		("Action",           "DescribeInstances"),
		("Version",          "2016-11-15"),
		("Filter.1.Name",    "tag:aws:autoscaling:groupName"),
		("Filter.1.Value.1", asg_name),
		("Filter.2.Name",    "instance-state-name"),
		("Filter.2.Value.1", "running"),
	]).await.with_context(|| format!("DescribeInstances (asg {asg_name})"))?;

	let unique: BTreeSet<String> = extract_all_scalars(&xml, "privateIpAddress")
		.into_iter()
		.filter(|s| !s.is_empty())
		.collect();

	let mut ips: Vec<String> = unique
		.into_iter()
		.filter(|ip| match (ip_to_u32(ip), cidr_filter) {
			(Some(v), Some(cidrs)) => cidr_contains(cidrs, v),
			(Some(_), None)        => true,
			_                       => false,
		})
		.collect();
	ips.sort_by_key(|ip| ip_to_u32(ip).unwrap_or(0));
	Ok(ips)
}

/// Squid liveness probe. Issues a proxy request for a sentinel host that
/// squid.conf denies FIRST (before the infoproxy helper), so a ready proxy
/// answers with `HTTP/1.0 403` -- proof it is parsing and serving requests, not
/// merely that the port is open. Healthy iff we read back an `HTTP/` status
/// line within the timeout. The sentinel is excluded from Squid's access log.
const HEALTH_HOST: &str = "health.fleetproxy.invalid";

async fn probe(ip: &str, port: u16, timeout: Duration) -> bool {
	let Ok(addr) = format!("{ip}:{port}").parse::<SocketAddr>() else { return false; };
	matches!(tokio::time::timeout(timeout, probe_http(addr)).await, Ok(true))
}

async fn probe_http(addr: SocketAddr) -> bool {
	let Ok(mut stream) = TcpStream::connect(addr).await else { return false; };
	let req = format!(
		"GET http://{HEALTH_HOST}/ HTTP/1.0\r\nHost: {HEALTH_HOST}\r\nConnection: close\r\n\r\n"
	);
	if stream.write_all(req.as_bytes()).await.is_err() {
		return false;
	}
	// Read just enough to see the status line; any HTTP/ response = alive.
	let mut buf = [0u8; 16];
	match stream.read(&mut buf).await {
		Ok(n) if n >= 5 => buf[..n].starts_with(b"HTTP/"),
		_ => false,
	}
}

// ── nftables (local, VPN-NAT watcher) ──────────────────────────────────────────

fn write_nat_file(path: &str, content: &str) -> Result<()> {
	std::fs::write(path, content).with_context(|| format!("write {path}"))?;
	std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o644))
		.with_context(|| format!("chmod {path}"))?;
	Ok(())
}

/// Atomically replace the `ip nat` table: flush then reload in one nft
/// transaction (stateless DNAT, so no meaningful window even so).
async fn reload_nat_table(rendered: &str) -> Result<()> {
	use tokio::io::AsyncWriteExt;
	let batch = format!("add table ip nat\nflush table ip nat\n{rendered}");
	let mut child = tokio::process::Command::new("nft")
		.arg("-f").arg("-")
		.stdin(std::process::Stdio::piped())
		.stderr(std::process::Stdio::piped())
		.spawn().context("spawn nft -f -")?;
	if let Some(mut stdin) = child.stdin.take() {
		stdin.write_all(batch.as_bytes()).await.context("write nft batch")?;
	}
	let out = child.wait_with_output().await.context("wait nft")?;
	if !out.status.success() {
		anyhow::bail!("nft -f failed: {}", String::from_utf8_lossy(&out.stderr).trim());
	}
	Ok(())
}

/// Flush the LVS conntrack table. Called ONLY after a node is removed from the
/// jhash pool, so flows pinned to the departed node re-hash to a survivor on
/// their next packet. Stateless-LVS design (Decision #3) makes this safe: a
/// flow on a surviving node re-hashes to the same node.
async fn flush_conntrack() -> Result<()> {
	let out = tokio::process::Command::new("conntrack").arg("-F")
		.output().await.context("spawn conntrack -F")?;
	if !out.status.success() {
		anyhow::bail!("conntrack -F failed: {}", String::from_utf8_lossy(&out.stderr).trim());
	}
	Ok(())
}

fn read_pulse_state(path: &str) -> Result<Option<PulseState>> {
	match std::fs::read_to_string(path) {
		Ok(s)  => Ok(Some(serde_json::from_str(&s).with_context(|| format!("parse {path}"))?)),
		Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
		Err(e) => Err(e).with_context(|| format!("read {path}")),
	}
}

// ── Reconcile ─────────────────────────────────────────────────────────────────

fn is_master(role_file: &str) -> bool {
	match std::fs::read_to_string(role_file) {
		Ok(s)  => s.trim() == "master",
		Err(_) => false, // no role file yet => stand by (do not act)
	}
}

fn now_secs() -> u64 {
	SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// (A) Publish the healthy proxy set to Valkey. Returns the set if changed.
async fn reconcile_proxy(
	args: &Args,
	conn: &mut redis::aio::ConnectionManager,
	backend_cidrs: &[(u32, u32)],
	last: &Option<Vec<String>>,
	pool_key: &str,
	creds: &AwsCredentials,
) -> Result<Option<Vec<String>>> {
	let candidates = describe_asg_ips(&args.region, creds, &args.proxy_asg, Some(backend_cidrs)).await?;

	let timeout = Duration::from_millis(args.probe_timeout_ms);
	let probes = candidates.iter().map(|ip| {
		let ip = ip.clone();
		async move { (probe(&ip, args.proxy_port, timeout).await, ip) }
	});
	let mut healthy: Vec<String> = futures_util::future::join_all(probes).await
		.into_iter()
		.filter_map(|(ok, ip)| if ok { Some(ip) } else { debug!(%ip, "proxy failed :{} probe", args.proxy_port); None })
		.collect();
	healthy.sort_by_key(|ip| ip_to_u32(ip).unwrap_or(0));

	if last.as_ref() == Some(&healthy) {
		return Ok(None);
	}
	let json = serde_json::to_string(&PoolSnapshot { gen: now_secs(), ips: healthy.clone() })
		.context("serialize pool snapshot")?;
	let _: () = conn.set(pool_key, &json).await.with_context(|| format!("SET {pool_key}"))?;
	info!(pool = %args.pool_name, members = healthy.len(), candidates = candidates.len(),
		  "proxy pool published: {:?}", healthy);
	Ok(Some(healthy))
}

/// (B) Re-render + hot-reload the LVS `ip nat` jhash table when the VPN ASG
/// membership changed. Returns the VPN IP set if it changed.
async fn reconcile_vpn_nat(
	args: &Args,
	last: &Option<Vec<String>>,
	creds: &AwsCredentials,
) -> Result<Option<Vec<String>>> {
	let Some(state) = read_pulse_state(&args.state_file)? else {
		debug!(state = %args.state_file, "no ipsecpulse state yet -- skipping VPN-NAT watch");
		return Ok(None);
	};
	let vpn_ips = describe_asg_ips(&args.region, creds, &state.vpn_asg_name, None).await?;

	if last.as_ref() == Some(&vpn_ips) {
		return Ok(None);
	}
	// Nodes that LEFT the pool since the last render. Their per-flow conntrack
	// DNAT bindings still point at them, so after removing them from the jhash
	// map we must flush conntrack -- otherwise flows (e.g. a customer's UDP-4500
	// NAT-T flow) keep being DNAT'd to a departed node and silently vanish.
	// On pure scale-OUT (nothing removed) we deliberately do NOT flush: conntrack
	// pinning is what keeps established tunnels on their current node (Decision #3/#8).
	let removed: Vec<&String> = match last {
		Some(prev) => prev.iter().filter(|ip| !vpn_ips.contains(ip)).collect(),
		None       => Vec::new(),
	};
	let rendered = ipseccore::render_ipsec_nat(&state.instance_id, &state.eth0_secondary_ip, &vpn_ips);
	write_nat_file(&args.nat_file, &rendered).context("write ipsec-nat.nft")?;
	reload_nat_table(&rendered).await.context("reload ip nat table")?;
	if !removed.is_empty() {
		match flush_conntrack().await {
			Ok(())  => info!(?removed, "flushed conntrack after node removal (stale DNAT bindings)"),
			Err(e)  => warn!("conntrack flush after node removal failed: {e:#}"),
		}
	}
	info!(asg = %state.vpn_asg_name, nodes = vpn_ips.len(),
		  "VPN pool changed -- ipsec-nat.nft re-rendered + reloaded: {:?}", vpn_ips);
	Ok(Some(vpn_ips))
}

/// Publish the concentrator jhash ring (Increment 6g phase 2b) to Valkey so
/// ipsecnode can pick the on-demand initiate owner that matches the LVS map.
/// The value is deterministic (sorted `nodes` + fixed seed), so both LVMs
/// writing it is idempotent -- no master-only gating needed.
async fn publish_lvsring(conn: &mut redis::aio::ConnectionManager, nodes: &[String]) -> Result<()> {
	let ring = ipseccore::LvsRing::new(nodes.to_vec());
	let json = serde_json::to_string(&ring).context("serialize LvsRing")?;
	let _: () = conn.set(ipseccore::LVSRING_KEY, &json).await
		.with_context(|| format!("SET {}", ipseccore::LVSRING_KEY))?;
	info!(key = ipseccore::LVSRING_KEY, nodes = nodes.len(), "lvsring published");
	Ok(())
}

// ── Entry point ───────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<()> {
	tracing_subscriber::fmt()
		.with_env_filter(
			tracing_subscriber::EnvFilter::try_from_default_env()
				.unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
		)
		.init();

	let args = Args::parse();
	let pool_key = format!("fleetipsec:{}:pool", args.pool_name);

	let backend_cidrs: Vec<(u32, u32)> = args.backend_cidrs
		.split(',')
		.filter_map(|c| {
			let c = c.trim();
			match parse_cidr(c) {
				Some(v) => Some(v),
				None    => { warn!(cidr = c, "ignoring unparseable backend CIDR"); None }
			}
		})
		.collect();
	if backend_cidrs.is_empty() {
		anyhow::bail!("no valid --backend-cidrs; refusing to run (would select no eth0 IPs)");
	}

	info!(
		region = %args.region, proxy_asg = %args.proxy_asg, proxy_port = args.proxy_port,
		pool_key = %pool_key, manage_vpn_nat = !args.no_vpn_nat, interval = args.interval,
		"ipsecscale starting (proxy-pool + VPN-NAT watcher)"
	);

	let client = aerocore::redis_pool::build_redis_client(&args.valkey_url, true, false, &None)
		.context("build Valkey client")?;
	let mut conn = redis::aio::ConnectionManager::new(client).await
		.context("connect to Valkey")?;

	let mut last_proxy: Option<Vec<String>> = None;
	let mut last_vpn:   Option<Vec<String>> = None;
	let mut was_master = false;

	loop {
		let master = is_master(&args.role_file);

		match fetch_imds_credentials().await {
			Ok(creds) => {
				// VPN-NAT: reconcile on BOTH roles (aeroftp pattern). The rule is
				// LOCAL to this LVS node and changes nothing about live traffic on
				// the backup (the customer EIP is not on it); keeping it current with
				// VPN membership means a VRRP failover takes over instantly with a
				// correct table instead of a stale one. The render keys on THIS node's
				// own secondary IP (from its own /run/ipsecpulse.state), which is
				// exactly what the EIP targets once this node is promoted.
				if !args.no_vpn_nat {
					match reconcile_vpn_nat(&args, &last_vpn, &creds).await {
						Ok(Some(set)) => {
							// Publish the ring (same sorted vpn_ips that produced the
							// LVS map) so ipsecnode picks the on-demand initiate owner
							// that matches this node's routing. Idempotent + deterministic,
							// so both LVMs writing identical JSON is harmless.
							if let Err(e) = publish_lvsring(&mut conn, &set).await {
								warn!("lvsring publish failed: {e:#}");
							}
							last_vpn = Some(set);
						}
						Ok(None)      => {}
						Err(e)        => warn!("VPN-NAT reconcile failed: {e:#}"),
					}
				}

				// Proxy pool: MASTER ONLY. It is a SHARED Valkey key, so a single
				// writer avoids double-writes / flap; VPN-node consumers read it
				// regardless of which LVS is master. On promotion, force a fresh
				// publish (the ex-backup never wrote it).
				if master {
					if !was_master {
						info!("promoted to master -- publishing proxy pool");
						last_proxy = None;
					}
					match reconcile_proxy(&args, &mut conn, &backend_cidrs, &last_proxy, &pool_key, &creds).await {
						Ok(Some(set)) => last_proxy = Some(set),
						Ok(None)      => {}
						Err(e)        => warn!("proxy reconcile failed: {e:#}"),
					}
				} else if was_master {
					info!("demoted to backup -- proxy pool now published by the new master");
					last_proxy = None;
				}
			}
			Err(e) => warn!("IMDS credentials fetch failed: {e:#}"),
		}
		was_master = master;
		tokio::time::sleep(Duration::from_secs(args.interval)).await;
	}
}
