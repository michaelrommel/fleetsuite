//! ipsecpulse — boot-time configuration generator for IPSec LVS nodes.
//!
//! Runs once at instance boot, called from the keepalived OpenRC `start_pre`
//! hook after the shell script has already:
//!   • attached the management ENI (eth1) via `aeroplug eni`
//!   • brought eth1 up and assigned its IP address
//!   • configured policy routing for the SSH reply path
//!
//! ipsecpulse itself only does pure Rust work:
//!   1. Reads instance identity and tags from IMDSv2.
//!   2. Reads the already-attached NIC layout from IMDSv2.
//!   3. Fetches the current VPN concentrator IP list from the ASG.
//!   4. Writes /run/ipsecpulse.state  (JSON; read by the notify subcommands).
//!   5. Renders /etc/keepalived/vrrp.conf
//!   6. Renders /etc/keepalived/notify-master.sh  (calls back: ipsecpulse notify-master)
//!   7. Renders /etc/keepalived/notify-backup.sh   (calls back: ipsecpulse notify-backup)
//!   8. Renders /etc/nftables.d/ipsec-vars.nft
//!   9. Renders /etc/nftables.d/ipsec-backends.nft
//!
//! Two subcommands are invoked by keepalived at runtime:
//!
//!   notify-master  — associate EIP to eth0, update rtb-vpn, write role file ("master")
//!   notify-backup  — write role file ("backup")
//!
//!
//! Required EC2 instance tags (set on the ASG with PropagateAtLaunch=true):
//!
//!   ipsec-lb-role         "master" | "backup"
//!   ipsec-vip-outside     EIP allocation ID (eipalloc-…)
//!   ipsec-lb-peer-mgmt-ip peer's eth1 fixed IP for VRRP unicast
//!   ipsec-vpn-asg         VPN concentrator ASG name
//!   ipsec-rtb-vpn         Route table ID for VPN subnets

use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use serde::{Deserialize, Serialize};
use std::{
	collections::BTreeSet,
	fs,
	os::unix::fs::PermissionsExt,
	path::{Path, PathBuf},
};

use aerocore::{
	aws_query, extract_all_scalars, extract_scalar,
	fetch_imds_credentials, fetch_imds_path, fetch_imds_token,
	AwsCredentials,
};

// ── CLI ───────────────────────────────────────────────────────────────────────

#[derive(Parser)]
#[command(name = "ipsecpulse")]
#[command(about = "Boot-time config generator and notify handler for IPSec LVS nodes")]
struct Cli {
	/// VRRP authentication password (identical on both nodes).
	/// Prefer setting via the VRRP_PASS environment variable.
	#[arg(long, env = "VRRP_PASS")]
	auth_pass: Option<String>,

	/// AWS region.
	#[arg(long, default_value = "eu-west-2", global = true)]
	region: String,

	/// VRRP virtual_router_id (1–255, unique per subnet).
	#[arg(long, default_value_t = 51)]
	vrid: u8,

	/// VRRP advertisement interval in seconds.
	#[arg(long, default_value_t = 1)]
	advert_int: u8,

	/// Consecutive missed advertisements before BACKUP elects itself MASTER.
	#[arg(long, default_value_t = 3)]
	down_timer_adverts: u32,

	/// VRRP priority for the master-role node.
	#[arg(long, default_value_t = 150)]
	priority_master: u8,

	/// VRRP priority for the backup-role node.
	#[arg(long, default_value_t = 100)]
	priority_backup: u8,

	/// OS name of the data-plane NIC (device index 0).
	#[arg(long, default_value = "eth0")]
	iface_data: String,

	/// OS name of the management NIC (device index 1).
	#[arg(long, default_value = "eth1")]
	iface_mgmt: String,

	/// Path for the generated VRRP keepalived include file.
	#[arg(long, default_value = "/etc/keepalived/vrrp.conf")]
	vrrp_out: PathBuf,

	/// Path for the generated notify-master shell script.
	#[arg(long, default_value = "/etc/keepalived/notify-master.sh")]
	notify_master_out: PathBuf,

	/// Path for the generated notify-backup shell script.
	#[arg(long, default_value = "/etc/keepalived/notify-backup.sh")]
	notify_backup_out: PathBuf,

	/// Path for the generated nftables nat table file (DNAT rules + SNAT rule).
	/// Replaces the former ipsec-vars.nft + ipsec-backends.nft split.
	#[arg(long, default_value = "/etc/nftables.d/ipsec-nat.nft", global = true)]
	nft_nat_out: PathBuf,

	/// Path for the runtime state file (written at boot, read by notify subcommands).
	#[arg(long, default_value = "/run/ipsecpulse.state", global = true)]
	state_file: PathBuf,

	/// Path for the role file written by notify subcommands ("master\n" or "backup\n").
	/// ipsecscale reads this each cycle to determine whether to act as master or backup.
	/// Pre-created in the keepalived init.d start_pre with keepalived_script ownership.
	#[arg(long, default_value = "/run/ipsec-role", global = true)]
	role_file: PathBuf,

	#[command(subcommand)]
	command: Option<SubCmd>,
}

#[derive(Subcommand)]
enum SubCmd {
	/// Associate the management EIP to this node's eth0 primary IP.
	/// Called once in keepalived start_pre before aeroplug runs, to establish
	/// permanent outbound internet access independent of the customer EIP.
	AssociateMgmtEip,
	/// Associate the EIP to eth0, update rtb-vpn, write role file.
	/// Called by the generated /etc/keepalived/notify-master.sh.
	NotifyMaster,

	/// Stop ipsecscale.
	/// Called by the generated /etc/keepalived/notify-backup.sh.
	NotifyBackup,
}

// ── Role ──────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Role {
	Master,
	Backup,
}

impl Role {
	fn as_str(self) -> &'static str {
		match self {
			Role::Master => "master",
			Role::Backup => "backup",
		}
	}

	fn priority(self, cli: &Cli) -> u8 {
		match self {
			Role::Master => cli.priority_master,
			Role::Backup => cli.priority_backup,
		}
	}
}

impl std::fmt::Display for Role {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		f.write_str(self.as_str())
	}
}

// ── State ─────────────────────────────────────────────────────────────────────

/// Runtime state written to disk during the boot run.
/// Read back by `notify-master` and `notify-backup` subcommands.
#[derive(Serialize, Deserialize)]
struct State {
	/// EC2 instance ID of this node.
	instance_id: String,
	/// "master" or "backup".
	role: String,
	/// AWS region, e.g. "eu-west-2".
	region: String,
	/// ENI ID of eth0 (data-plane NIC).
	eth0_eni_id: String,
	/// Primary private IP of eth0 — used for identity only; has the
	/// auto-assigned ephemeral public IP that provides permanent outbound access.
	eth0_primary_ip: String,
	/// Fixed secondary private IP of eth0 — the stable IP that the customer-
	/// facing EIP always points to on the current VRRP master.
	/// Used as EIP association target and nftables SNAT source.
	/// Assigned to the ENI at boot by aeroplug (keepalived start_pre step 2)
	/// and read from the ipsec-vip-inside IMDS instance tag.
	eth0_secondary_ip: String,
	/// Primary private IP of eth1 (management NIC).
	eth1_ip: String,
	/// Subnet prefix length for eth1, e.g. 28.
	eth1_prefix: u8,
	/// Peer's eth1 fixed IP — used as VRRP unicast peer address.
	peer_mgmt_ip: String,
	/// EIP allocation ID, e.g. "eipalloc-095ac59bb763cd2ce".
	eip_alloc_id: String,
	/// Route table ID for VPN subnets, e.g. "rtb-01c3275faa537fcc1".
	rtb_vpn_id: String,
	/// VPN concentrator ASG name, e.g. "fleetipsec-vpn".
	vpn_asg_name: String,
	/// Private IPs of running VPN concentrators, numerically sorted.
	vpn_ips: Vec<String>,
}

// ── NIC info (boot-time only) ─────────────────────────────────────────────────

struct IfaceInfo {
	eni_id:      String,
	primary_ip:  String,
	/// Subnet CIDR, e.g. "172.16.48.64/28".
	subnet_cidr: String,
}

// ── Entry point ───────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<()> {
	let cli = Cli::parse();
	match &cli.command {
		None                            => run_boot(&cli).await,
		Some(SubCmd::AssociateMgmtEip)  => run_associate_mgmt_eip(&cli).await,
		Some(SubCmd::NotifyMaster)      => run_notify_master(&cli).await,
		Some(SubCmd::NotifyBackup)      => run_notify_backup(&cli).await,
	}
}

// ── Boot run ──────────────────────────────────────────────────────────────────

async fn run_boot(cli: &Cli) -> Result<()> {
	let auth_pass = cli.auth_pass.as_deref()
		.context("--auth-pass / VRRP_PASS is required for the boot run")?;

	println!("ipsecpulse: boot run starting ...");

	// ── 1. IMDSv2 token + instance identity ──────────────────────────────
	let token       = fetch_imds_token().await?;
	let instance_id = fetch_imds_path(&token, "instance-id").await?;
	println!("  Instance   : {instance_id}");

	// ── 2. Required instance tags ─────────────────────────────────────────
	let role_str        = fetch_imds_tag(&token, "ipsec-lb-role").await?;
	let eip_alloc_id    = fetch_imds_tag(&token, "ipsec-vip-outside").await?;
	let peer_mgmt_ip    = fetch_imds_tag(&token, "ipsec-lb-peer-mgmt-ip").await?;
	let vpn_asg_name    = fetch_imds_tag(&token, "ipsec-vpn-asg").await?;
	let rtb_vpn_id      = fetch_imds_tag(&token, "ipsec-rtb-vpn").await?;
	let eth0_secondary_ip = fetch_imds_tag(&token, "ipsec-vip-inside").await?;

	let role = match role_str.as_str() {
		"master" => Role::Master,
		"backup" => Role::Backup,
		other    => bail!(
			"Tag 'ipsec-lb-role' has unexpected value '{other}'. \
			 Expected 'master' or 'backup'."
		),
	};
	println!("  Role       : {role}");
	println!("  EIP alloc  : {eip_alloc_id}");
	println!("  VIP inside : {eth0_secondary_ip}  (fixed secondary; EIP target + SNAT source)");
	println!("  Peer eth1  : {peer_mgmt_ip}");
	println!("  VPN ASG    : {vpn_asg_name}");
	println!("  rtb-vpn    : {rtb_vpn_id}");

	// ── 3. NIC layout from IMDS ───────────────────────────────────────────
	// The shell start_pre has already attached eth1 and brought it up;
	// IMDS now reflects both device 0 (eth0) and device 1 (eth1).
	let ifaces = fetch_all_interfaces(&token).await?;

	let eth0 = ifaces.iter().find(|(dev, _)| *dev == 0)
		.map(|(_, info)| info)
		.context(
			"Device 0 (eth0) not found in IMDS interface list. \
			 Is the data-plane ENI attached?"
		)?;

	let eth1 = ifaces.iter().find(|(dev, _)| *dev == 1)
		.map(|(_, info)| info)
		.context(
			"Device 1 (eth1) not found in IMDS interface list. \
			 Has the shell start_pre attached and brought up the management ENI?"
		)?;

	let eth1_prefix = parse_prefix(&eth1.subnet_cidr)?;

	println!("  eth0       : {}  ({})", eth0.primary_ip, eth0.eni_id);
	println!("  eth1       : {}  ({}/{})", eth1.primary_ip, eth1.subnet_cidr, eth1_prefix);

	// ── 4. Fetch VPN concentrator IPs from ASG ────────────────────────────
	println!("  Fetching VPN instances from ASG '{vpn_asg_name}' ...");
	let creds   = fetch_imds_credentials().await?;
	let vpn_ips = describe_vpn_instances(&cli.region, &creds, &vpn_asg_name).await?;
	println!("  VPN nodes  : {} instance(s)", vpn_ips.len());
	for ip in &vpn_ips { println!("    {ip}"); }


	// ── 5. Build state and write to disk ──────────────────────────────────
	let state = State {
		instance_id:     instance_id.clone(),
		role:            role_str.clone(),
		region:          cli.region.clone(),
		eth0_eni_id:        eth0.eni_id.clone(),
		eth0_primary_ip:    eth0.primary_ip.clone(),
		eth0_secondary_ip:  eth0_secondary_ip.clone(),
		eth1_ip:            eth1.primary_ip.clone(),
		eth1_prefix,
		peer_mgmt_ip:    peer_mgmt_ip.clone(),
		eip_alloc_id:    eip_alloc_id.clone(),
		rtb_vpn_id:      rtb_vpn_id.clone(),
		vpn_asg_name:    vpn_asg_name.clone(),
		vpn_ips:         vpn_ips.clone(),
	};
	let state_json = serde_json::to_string_pretty(&state)?;
	// 0o644 so keepalived_script (which runs the notify scripts) can read it.
	write_file(&cli.state_file, &state_json, 0o644)?;
	println!("  State      → {}", cli.state_file.display());

	// ── 6. Render and write config files ──────────────────────────────────
	write_file(&cli.vrrp_out,          &render_vrrp_conf(cli, &state, auth_pass), 0o640)?;
	write_file(&cli.notify_master_out, &render_notify_master(cli, &state),        0o750)?;
	write_file(&cli.notify_backup_out, &render_notify_backup(cli, &state),        0o750)?;
	write_file(&cli.nft_nat_out,       &render_nft_nat(&state),                   0o640)?;
	println!("  Written    → {}", cli.vrrp_out.display());
	println!("  Written    → {}", cli.notify_master_out.display());
	println!("  Written    → {}", cli.notify_backup_out.display());
	println!("  Written    → {}", cli.nft_nat_out.display());

	println!();
	println!("✅ ipsecpulse boot run complete.");
	println!("   keepalived.conf must include:");
	println!("     include \"{}\"", cli.vrrp_out.display());
	Ok(())
}

// ── AssociateMgmtEip ─────────────────────────────────────────────────────────

/// Associate the pre-allocated management EIP to this node's eth0 primary IP.
///
/// Called early in keepalived start_pre, before aeroplug or anything else that
/// needs outbound internet.  Uses the auto-assigned public IP (from the LT's
/// AssociatePublicIpAddress=true) for this one API call; the management EIP
/// then permanently replaces it, surviving all customer EIP movements.
///
/// Safe to call on restart: AllowReassociation=true makes it a no-op when
/// the EIP is already on this ENI and primary IP.
async fn run_associate_mgmt_eip(cli: &Cli) -> Result<()> {
	println!("ipsecpulse associate-mgmt-eip: starting ...");

	let token  = fetch_imds_token().await?;
	let alloc_id = fetch_imds_tag(&token, "ipsec-mgmt-eip").await?;
	println!("  Mgmt EIP alloc : {alloc_id}");

	let ifaces = fetch_all_interfaces(&token).await?;
	let eth0 = ifaces.iter().find(|(dev, _)| *dev == 0)
		.map(|(_, info)| info)
		.context("Device 0 (eth0) not found in IMDS interface list")?;
	println!("  eth0           : {}  ({})", eth0.primary_ip, eth0.eni_id);

	let creds = fetch_imds_credentials().await?;

	associate_eip(&cli.region, &creds, &alloc_id, &eth0.eni_id, &eth0.primary_ip).await?;
	println!("  ✓ Management EIP {alloc_id} -> {} ({})", eth0.primary_ip, eth0.eni_id);

	disable_src_dest_check(&cli.region, &creds, &eth0.eni_id).await?;
	println!("  ✓ Source/dest check disabled on {}", eth0.eni_id);

	println!("✅ ipsecpulse associate-mgmt-eip complete.");
	Ok(())
}

// ── NotifyMaster ─────────────────────────────────────────────────────────────

async fn run_notify_master(cli: &Cli) -> Result<()> {
	println!("ipsecpulse notify-master: starting ...");

	let state = load_state(&cli.state_file)?;
	let creds = fetch_imds_credentials().await?;

	// Associate the EIP to this node's fixed secondary IP on eth0.
	println!(
		"  EIP {} → ENI {} (secondary {})",
		state.eip_alloc_id, state.eth0_eni_id, state.eth0_secondary_ip,
	);
	associate_eip(
		&state.region, &creds,
		&state.eip_alloc_id, &state.eth0_eni_id,
		&state.eth0_secondary_ip,
	).await?;
	println!("  ✓ EIP associated.");

	// Create or replace the 0.0.0.0/0 route in rtb-vpn.
	println!(
		"  rtb-vpn ({}) 0.0.0.0/0 → {}",
		state.rtb_vpn_id, state.eth0_eni_id,
	);
	upsert_route(
		&state.region, &creds,
		&state.rtb_vpn_id, "0.0.0.0/0", &state.eth0_eni_id,
	).await?;
	println!("  ✓ rtb-vpn default route updated.");

	// Write role file — ipsecscale runs always and reads this each cycle.
	write_file(&cli.role_file, "master\n", 0o644)?;
	println!("  ✓ Role file written: master → {}", cli.role_file.display());

	println!("✅ ipsecpulse notify-master complete.");
	Ok(())
}

// ── NotifyBackup ──────────────────────────────────────────────────────────────

async fn run_notify_backup(cli: &Cli) -> Result<()> {
	println!("ipsecpulse notify-backup: writing role file ...");
	write_file(&cli.role_file, "backup\n", 0o644)?;
	println!("  ✓ Role file written: backup → {}", cli.role_file.display());
	println!("✅ ipsecpulse notify-backup complete.");
	Ok(())
}

/// Load the runtime state file written during the boot run.
fn load_state(path: &Path) -> Result<State> {
	let json = fs::read_to_string(path)
		.with_context(|| format!(
			"Cannot read state file '{}'. \
			 Has ipsecpulse (boot mode) been run on this instance?",
			path.display()
		))?;
	serde_json::from_str(&json)
		.with_context(|| format!("Cannot parse state file '{}'", path.display()))
}

// ── IMDS helpers ──────────────────────────────────────────────────────────────

/// Fetch a single instance tag from IMDSv2.
/// Requires "Instance tags in metadata" enabled in the launch template.
async fn fetch_imds_tag(token: &str, key: &str) -> Result<String> {
	fetch_imds_path(token, &format!("tags/instance/{key}"))
		.await
		.with_context(|| format!(
			"IMDS tag '{key}' not found. \
			 Is 'Instance tags in metadata' enabled \
			 (LaunchTemplate → MetadataOptions → InstanceMetadataTags)?"
		))
}

/// Read all attached network interfaces from IMDS.
/// Returns a list of (device_number, IfaceInfo) sorted by device number.
/// Mirrors aeropulse's `fetch_all_interfaces`.
async fn fetch_all_interfaces(token: &str) -> Result<Vec<(u32, IfaceInfo)>> {
	let macs_raw = fetch_imds_path(token, "network/interfaces/macs/").await?;
	let macs: Vec<&str> = macs_raw
		.lines()
		.map(|s| s.trim_end_matches('/').trim())
		.filter(|s| !s.is_empty())
		.collect();

	let mut ifaces = Vec::with_capacity(macs.len());

	for mac in macs {
		let base = format!("network/interfaces/macs/{mac}");

		let device_number: u32 = fetch_imds_path(token, &format!("{base}/device-number"))
			.await
			.with_context(|| format!("Failed to read device-number for MAC {mac}"))?
			.parse()
			.with_context(|| format!("device-number for MAC {mac} is not a valid integer"))?;

		let eni_id = fetch_imds_path(token, &format!("{base}/interface-id"))
			.await
			.with_context(|| format!("Failed to read interface-id for MAC {mac}"))?;

		let ips_raw = fetch_imds_path(token, &format!("{base}/local-ipv4s"))
			.await
			.with_context(|| format!("Failed to read local-ipv4s for MAC {mac}"))?;
		let primary_ip = ips_raw
			.lines()
			.next()
			.context("local-ipv4s returned an empty response")?
			.trim()
			.to_string();

		let subnet_cidr = fetch_imds_path(token, &format!("{base}/subnet-ipv4-cidr-block"))
			.await
			.with_context(|| format!("Failed to read subnet-ipv4-cidr-block for MAC {mac}"))?;

		ifaces.push((device_number, IfaceInfo { eni_id, primary_ip, subnet_cidr }));
	}

	ifaces.sort_by_key(|(dev, _)| *dev);
	Ok(ifaces)
}

/// Parse the prefix length from a CIDR string, e.g. "172.16.48.64/28" → 28.
fn parse_prefix(cidr: &str) -> Result<u8> {
	cidr.split('/')
		.nth(1)
		.and_then(|s| s.parse().ok())
		.with_context(|| format!("Cannot parse prefix length from CIDR '{cidr}'"))
}

// ── EC2 API helpers ───────────────────────────────────────────────────────────

/// Associate an EIP (by allocation ID) to a network interface.
/// AllowReassociation=true moves the EIP from the previous holder atomically.
async fn associate_eip(
	region: &str,
	creds: &AwsCredentials,
	alloc_id: &str,
	eni_id: &str,
	private_ip: &str,
) -> Result<()> {
	let host = format!("ec2.{region}.amazonaws.com");
	let xml = aws_query(&host, "ec2", region, creds, &[
		("Action",             "AssociateAddress"),
		("Version",            "2016-11-15"),
		("AllocationId",       alloc_id),
		("NetworkInterfaceId", eni_id),
		("PrivateIpAddress",   private_ip),
		("AllowReassociation", "true"),
	]).await?;

	match extract_scalar(&xml, "associationId") {
		Some(_) => Ok(()),
		None    => bail!("AssociateAddress (VPC) response missing associationId:\n{xml}"),
	}
}

/// Disable the source/dest check on a network interface.
/// Required on LVS eth0 so that FORWARD traffic (customer src IP post-DNAT)
/// is not dropped by AWS before reaching the VPN concentrators.
async fn disable_src_dest_check(
	region: &str,
	creds: &AwsCredentials,
	eni_id: &str,
) -> Result<()> {
	let host = format!("ec2.{region}.amazonaws.com");
	let xml = aws_query(&host, "ec2", region, creds, &[
		("Action",              "ModifyNetworkInterfaceAttribute"),
		("Version",             "2016-11-15"),
		("NetworkInterfaceId",  eni_id),
		("SourceDestCheck.Value", "false"),
	]).await?;

	match extract_scalar(&xml, "return") {
		Some("true") => Ok(()),
		Some(v)      => bail!("ModifyNetworkInterfaceAttribute returned unexpected value: {v}"),
		None         => bail!("Could not parse ModifyNetworkInterfaceAttribute response:\n{xml}"),
	}
}

/// Create or replace a route in a route table to point at a network interface.
/// Tries ReplaceRoute first; falls back to CreateRoute when the route does not
/// yet exist (first MASTER transition before any route was ever written).
async fn upsert_route(
	region: &str,
	creds: &AwsCredentials,
	rtb_id: &str,
	cidr: &str,
	eni_id: &str,
) -> Result<()> {
	let host = format!("ec2.{region}.amazonaws.com");

	let replace = aws_query(&host, "ec2", region, creds, &[
		("Action",               "ReplaceRoute"),
		("Version",              "2016-11-15"),
		("RouteTableId",         rtb_id),
		("DestinationCidrBlock", cidr),
		("NetworkInterfaceId",   eni_id),
	]).await;

	match replace {
		Ok(_)  => return Ok(()),
		Err(e) if e.to_string().contains("InvalidRoute.NotFound")
			  || e.to_string().contains("Use CreateRoute") => { /* fall through */ }
		Err(e) => return Err(e),
	}

	// Route does not exist yet — create it.
	let xml = aws_query(&host, "ec2", region, creds, &[
		("Action",               "CreateRoute"),
		("Version",              "2016-11-15"),
		("RouteTableId",         rtb_id),
		("DestinationCidrBlock", cidr),
		("NetworkInterfaceId",   eni_id),
	]).await?;

	match extract_scalar(&xml, "return") {
		Some("true") => Ok(()),
		Some(v)      => bail!("CreateRoute returned unexpected value: {v}"),
		None         => bail!("Could not parse CreateRoute response:\n{xml}"),
	}
}

/// Fetch private IPs of all running instances in a VPN concentrator ASG.
/// Filters DescribeInstances by the aws:autoscaling:groupName tag.
/// Returns IPs deduplicated and sorted numerically for stable nftables indices.
async fn describe_vpn_instances(
	region: &str,
	creds: &AwsCredentials,
	asg_name: &str,
) -> Result<Vec<String>> {
	let host = format!("ec2.{region}.amazonaws.com");
	let xml = aws_query(&host, "ec2", region, creds, &[
		("Action",           "DescribeInstances"),
		("Version",          "2016-11-15"),
		("Filter.1.Name",    "tag:aws:autoscaling:groupName"),
		("Filter.1.Value.1", asg_name),
		("Filter.2.Name",    "instance-state-name"),
		("Filter.2.Value.1", "running"),
	]).await?;

	// extract_all_scalars returns every <privateIpAddress> in the document,
	// including duplicates from nested ENI blocks; deduplicate then sort numerically.
	let unique: BTreeSet<String> = extract_all_scalars(&xml, "privateIpAddress")
		.into_iter()
		.filter(|s| !s.is_empty())
		.collect();

	let mut ips: Vec<String> = unique.into_iter().collect();
	ips.sort_by_key(|ip| ip_to_u32(ip).unwrap_or(0));
	Ok(ips)
}

/// Convert a dotted-decimal IPv4 string to a u32 for numeric sorting.
fn ip_to_u32(ip: &str) -> Option<u32> {
	let mut p = ip.split('.');
	let a: u32 = p.next()?.parse().ok()?;
	let b: u32 = p.next()?.parse().ok()?;
	let c: u32 = p.next()?.parse().ok()?;
	let d: u32 = p.next()?.parse().ok()?;
	if p.next().is_some() { return None; }
	Some((a << 24) | (b << 16) | (c << 8) | d)
}

// ── Renderers ─────────────────────────────────────────────────────────────────

/// Generate /etc/keepalived/vrrp.conf — included by the static keepalived.conf.
///
/// One vrrp_instance (VI_IPSEC) on eth1 with unicast heartbeat.
/// No virtual_ipaddress block: the EIP is associated by notify-master.sh.
fn render_vrrp_conf(cli: &Cli, state: &State, auth_pass: &str) -> String {
	let role      = if state.role == "master" { Role::Master } else { Role::Backup };
	let priority  = role.priority(cli);
	let nopreempt = if role == Role::Master { "    nopreempt\n" } else { "" };
	let ts        = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ");

	format!(
		r#"# vrrp.conf — generated by ipsecpulse for {instance_id}
# Generated : {ts}
# Role      : {role}
# DO NOT EDIT MANUALLY — re-run ipsecpulse to regenerate.
#
# Add to /etc/keepalived/keepalived.conf:
#   include "/etc/keepalived/vrrp.conf"
#
# Interface roles:
#   {iface_data}  data-plane NIC (EIP on MASTER transition)
#   {iface_mgmt}  management NIC (VRRP unicast heartbeat + SSH)
#
# No virtual_ipaddress block: the EIP is associated to {iface_data}'s
# primary IP by notify-master.sh via EC2 AssociateAddress.

vrrp_instance VI_IPSEC {{
    state             BACKUP
    interface         {iface_mgmt}
    virtual_router_id {vrid}
    priority          {priority}
    advert_int        {advert_int}
    down_timer_adverts {down_timer_adverts}
{nopreempt}
    unicast_src_ip  {eth1_ip}
    unicast_peer {{
        {peer_mgmt_ip}
    }}

    authentication {{
        auth_type PASS
        auth_pass {auth_pass}
    }}

    track_interface {{
        {iface_data}
    }}

    notify_master "/etc/keepalived/notify-master.sh"
    notify_backup "/etc/keepalived/notify-backup.sh"
}}
"#,
		instance_id      = state.instance_id,
		ts               = ts,
		role             = state.role,
		iface_data       = cli.iface_data,
		iface_mgmt       = cli.iface_mgmt,
		vrid             = cli.vrid,
		priority         = priority,
		advert_int       = cli.advert_int,
		down_timer_adverts = cli.down_timer_adverts,
		nopreempt        = nopreempt,
		eth1_ip          = state.eth1_ip,
		peer_mgmt_ip     = state.peer_mgmt_ip,
		auth_pass        = auth_pass,
	)
}

/// Generate /etc/keepalived/notify-master.sh.
/// A thin shell wrapper that calls back into this binary with `notify-master`.
fn render_notify_master(cli: &Cli, state: &State) -> String {
	let ts     = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ");
	let binary = std::env::current_exe()
		.unwrap_or_else(|_| PathBuf::from("/usr/local/bin/ipsecpulse"));

	format!(
		r#"#!/bin/sh
# notify-master.sh — generated by ipsecpulse for {instance_id}
# Generated : {ts}
# DO NOT EDIT MANUALLY — re-run ipsecpulse to regenerate.
#
# Called by keepalived when VI_IPSEC transitions to MASTER.
# Associates the EIP to eth0, updates rtb-vpn, writes the role file.
# Full ipsecpulse output is appended to /run/ipsecpulse-notify.log.

set -u
TYPE="${{1:-?}}" NAME="${{2:-?}}" STATE="${{3:-?}}"
logger -p local3.info -t ipsecpulse-notify \
    "notify-master[${{TYPE}}/${{NAME}}]: running on {instance_id}"

# Disable set -e around the ipsecpulse call so we always capture the exit code.
# With set -e, a non-zero exit would terminate the script before rc=$? is reached,
# swallowing both the error output and the FAILED log message.
set +e
{binary} notify-master --region {region} --state-file {state_file} --role-file {role_file} \
    > /run/ipsecpulse-notify.log 2>&1
rc=$?
set -e
# Forward all ipsecpulse output to syslog (local3 → /var/log/keepalived/keepalived.log).
# Raw log also available at /run/ipsecpulse-notify.log for direct inspection.
logger -p local3.info -t ipsecpulse-out < /run/ipsecpulse-notify.log

if [ $rc -eq 0 ]; then
    logger -p local3.info -t ipsecpulse-notify \
        "notify-master[${{TYPE}}/${{NAME}}]: complete"
else
    logger -p local3.err -t ipsecpulse-notify \
        "notify-master[${{TYPE}}/${{NAME}}]: FAILED (exit $rc) — see /run/ipsecpulse-notify.log"
    exit 1
fi
"#,
		instance_id = state.instance_id,
		ts          = ts,
		binary      = binary.display(),
		region      = cli.region,
		state_file  = cli.state_file.display(),
		role_file   = cli.role_file.display(),
	)
}

/// Generate /etc/keepalived/notify-backup.sh.
fn render_notify_backup(cli: &Cli, state: &State) -> String {
	let ts     = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ");
	let binary = std::env::current_exe()
		.unwrap_or_else(|_| PathBuf::from("/usr/local/bin/ipsecpulse"));

	format!(
		r#"#!/bin/sh
# notify-backup.sh — generated by ipsecpulse for {instance_id}
# Generated : {ts}
# DO NOT EDIT MANUALLY — re-run ipsecpulse to regenerate.
#
# Called by keepalived when VI_IPSEC transitions to BACKUP.
# Writes the role file; ipsecscale sees backup and idles.

set -u
TYPE="${{1:-?}}" NAME="${{2:-?}}" STATE="${{3:-?}}"
logger -p local3.info -t ipsecpulse-notify \
    "notify-backup[${{TYPE}}/${{NAME}}]: running on {instance_id}"

set +e
{binary} notify-backup --state-file {state_file} --role-file {role_file} > /run/ipsecpulse-notify.log 2>&1
rc=$?
set -e
logger -p local3.info -t ipsecpulse-out < /run/ipsecpulse-notify.log

if [ $rc -eq 0 ]; then
    logger -p local3.info -t ipsecpulse-notify \
        "notify-backup[${{TYPE}}/${{NAME}}]: complete"
else
    logger -p local3.err -t ipsecpulse-notify \
        "notify-backup[${{TYPE}}/${{NAME}}]: FAILED (exit $rc) — see /run/ipsecpulse-notify.log"
    exit 1
fi
"#,
		instance_id = state.instance_id,
		ts          = ts,
		binary      = binary.display(),
		state_file  = cli.state_file.display(),
		role_file   = cli.role_file.display(),
	)
}

/// Generate /etc/nftables.d/ipsec-nat.nft — the complete ip nat table.
///
/// Contains both PREROUTING (jhash DNAT) and POSTROUTING (SNAT) chains.
/// Uses inline anonymous maps so no `type integer` named map or `$VARIABLE`
/// in mod position is needed — avoids all nftables 1.0+ compatibility issues.
///
/// Regenerated by ipsecpulse at boot and by ipsecscale on pool changes.
fn render_nft_nat(state: &State) -> String {
	let ts      = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ");
	let n       = state.vpn_ips.len();
	let snat_ip = &state.eth0_secondary_ip;   // fixed secondary — stable across EIP movements
	let mut out = String::new();

	out.push_str(&format!(
		"# ipsec-nat.nft — generated by ipsecpulse for {}\n\
		 # Generated    : {ts}\n\
		 # DO NOT EDIT  — regenerated by ipsecpulse (boot) and ipsecscale (pool changes).\n\
		 # VPN backends : {n}\n\n",
		state.instance_id,
	));

	out.push_str("table ip nat {\n");

	// PREROUTING: hash src IP → VPN concentrator (inline anonymous map avoids
	// named-map type issues and $VARIABLE in mod position).
	out.push_str("\tchain PREROUTING {\n");
	out.push_str("\t\ttype nat hook prerouting priority dstnat; policy accept;\n");
	if n == 0 {
		out.push_str("\t\t# No VPN backends yet — ipsecscale will update this file.\n");
	} else {
		let entries: String = state.vpn_ips.iter()
			.enumerate()
			.map(|(i, ip)| format!("{i} : {ip}"))
			.collect::<Vec<_>>()
			.join(", ");
		let map = format!("{{ {} }}", entries);
		for rule in [
			format!("ip protocol 50 dnat ip to jhash ip saddr mod {n} map {map}"),
			format!("ip protocol udp udp dport 500 dnat ip to jhash ip saddr mod {n} map {map}"),
			format!("ip protocol udp udp dport 4500 dnat ip to jhash ip saddr mod {n} map {map}"),
		] {
			out.push_str(&format!("\t\t{rule}\n"));
		}
	}
	out.push_str("\t}\n\n");

	// POSTROUTING: SNAT return traffic from VPN concentrators to eth0 primary IP.
	out.push_str("\tchain POSTROUTING {\n");
	out.push_str("\t\ttype nat hook postrouting priority srcnat; policy accept;\n");
	out.push_str(&format!(
		"\t\toifname \"eth0\" ip saddr {{ 172.16.49.0/24, 172.16.50.0/24 }} snat to {snat_ip}\n"
	));
	out.push_str("\t}\n");
	out.push_str("}\n");

	out
}

/// Write `content` to `path`, creating parent directories as needed,
/// and set the file permissions to `mode`.
fn write_file(path: &Path, content: &str, mode: u32) -> Result<()> {
	if let Some(dir) = path.parent() {
		fs::create_dir_all(dir)
			.with_context(|| format!("Cannot create directory {}", dir.display()))?;
	}
	fs::write(path, content)
		.with_context(|| format!("Cannot write {}", path.display()))?;
	fs::set_permissions(path, fs::Permissions::from_mode(mode))
		.with_context(|| format!("Cannot set permissions on {}", path.display()))?;
	Ok(())
}
