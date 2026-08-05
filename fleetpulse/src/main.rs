//! fleetpulse -- boot-time configuration generator for IPSec Return GW nodes.
//!
//! Runs once at instance boot, called from the keepalived OpenRC `start_pre`
//! hook after the shell script has already:
//!   - attached the management ENI (eth1) via `aeroplug eni`
//!   - brought eth1 up and assigned its IP address
//!
//! fleetpulse itself does:
//!   1. Reads instance identity and tags from IMDSv2.
//!   2. Reads the already-attached NIC layout from IMDSv2.
//!   3. Disables src/dest check on eth0 via EC2 API.
//!      The Return GW forwards traffic with arbitrary src/dst IPs --
//!      src/dest check would drop that traffic.
//!   4. Writes /run/fleetpulse.state  (JSON; read by the notify subcommands).
//!   5. Renders /etc/keepalived/vrrp.conf
//!   6. Renders /etc/keepalived/notify-master.sh
//!   7. Renders /etc/keepalived/notify-backup.sh
//!
//! Two subcommands are invoked by keepalived at runtime:
//!
//!   notify-master  -- upsert 0.0.0.0/0 in the backend route table to point at
//!                     this node's eth0 ENI; write role file ("master")
//!   notify-backup  -- write role file ("backup")
//!
//! Required EC2 instance tags (set on ASG with PropagateAtLaunch=true):
//!
//!   ipsec-gw-role          "master" | "backup"
//!   ipsec-gw-peer-mgmt-ip  peer's eth1 fixed IP for VRRP unicast
//!   ipsec-gw-rtb           route table ID for backend servers
//!                          updated with 0.0.0.0/0 -> eth0 ENI on master election

use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use serde::{Deserialize, Serialize};
use std::{
	fs,
	os::unix::fs::PermissionsExt,
	path::{Path, PathBuf},
};

use aerocore::{
	aws_query, extract_scalar,
	fetch_imds_credentials, fetch_imds_path, fetch_imds_token,
	AwsCredentials,
};

// -- CLI -----------------------------------------------------------------------

#[derive(Parser)]
#[command(name = "fleetpulse")]
#[command(about = "Boot-time config generator and notify handler for IPSec Return GW nodes")]
struct Cli {
	/// VRRP authentication password (identical on both nodes).
	/// Prefer setting via the VRRP_PASS environment variable.
	#[arg(long, env = "VRRP_PASS")]
	auth_pass: Option<String>,

	/// AWS region.
	#[arg(long, default_value = "eu-west-2", global = true)]
	region: String,

	/// VRRP virtual_router_id (1-255, unique per subnet).
	/// Use 52 for the Return GW pair (51 is used by the LVS pair).
	#[arg(long, default_value_t = 52)]
	vrid: u8,

	/// VRRP advertisement interval in seconds.
	#[arg(long, default_value_t = 1)]
	advert_int: u8,

	/// Consecutive missed advertisements before BACKUP promotes to MASTER.
	#[arg(long, default_value_t = 3)]
	down_timer_adverts: u32,

	/// VRRP priority for the master-role node.
	#[arg(long, default_value_t = 150)]
	priority_master: u8,

	/// VRRP priority for the backup-role node.
	#[arg(long, default_value_t = 100)]
	priority_backup: u8,

	/// OS name of the data-plane NIC (primary ENI with fixed IP).
	#[arg(long, default_value = "eth0")]
	iface_data: String,

	/// OS name of the management NIC (attached at boot by aeroplug).
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

	/// Path for the runtime state file (written at boot, read by notify subcommands).
	#[arg(long, default_value = "/run/fleetpulse.state", global = true)]
	state_file: PathBuf,

	/// Path for the role file ("master\n" or "backup\n").
	/// Pre-created in keepalived start_pre with keepalived_script ownership.
	#[arg(long, default_value = "/run/ipsec-role", global = true)]
	role_file: PathBuf,

	#[command(subcommand)]
	command: Option<SubCmd>,
}

#[derive(Subcommand)]
enum SubCmd {
	/// Upsert 0.0.0.0/0 in the backend route table pointing at eth0 ENI.
	/// Write role file ("master").
	/// Called by the generated /etc/keepalived/notify-master.sh.
	NotifyMaster,

	/// Write role file ("backup").
	/// Called by the generated /etc/keepalived/notify-backup.sh.
	NotifyBackup,
}

// -- Role ----------------------------------------------------------------------

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

// -- State ---------------------------------------------------------------------

/// Runtime state written at boot and read by notify subcommands.
#[derive(Serialize, Deserialize)]
struct State {
	/// EC2 instance ID of this node.
	instance_id: String,
	/// "master" or "backup".
	role: String,
	/// AWS region, e.g. "eu-west-2".
	region: String,
	/// ENI ID of eth0 (the fixed-IP data-plane NIC).
	/// Used as the route target when this node is MASTER.
	eth0_eni_id: String,
	/// Primary IP of eth0 (the fixed static IP from the Launch Template).
	eth0_ip: String,
	/// Primary IP of eth1 (management NIC, attached at boot by aeroplug).
	eth1_ip: String,
	/// Subnet prefix length of eth1, e.g. 28.
	eth1_prefix: u8,
	/// Peer's eth1 fixed IP -- used as VRRP unicast peer address.
	peer_mgmt_ip: String,
	/// Route table ID for backend servers.
	/// On MASTER election, 0.0.0.0/0 is upserted to point at eth0_eni_id.
	rtb_id: String,
}

// -- NIC info (boot-time only) -------------------------------------------------

struct IfaceInfo {
	eni_id:      String,
	primary_ip:  String,
	subnet_cidr: String,
}

// -- Entry point ---------------------------------------------------------------

#[tokio::main]
async fn main() -> Result<()> {
	let cli = Cli::parse();
	match &cli.command {
		None                       => run_boot(&cli).await,
		Some(SubCmd::NotifyMaster) => run_notify_master(&cli).await,
		Some(SubCmd::NotifyBackup) => run_notify_backup(&cli).await,
	}
}

// -- Boot run ------------------------------------------------------------------

async fn run_boot(cli: &Cli) -> Result<()> {
	let auth_pass = cli.auth_pass.as_deref()
		.context("--auth-pass / VRRP_PASS is required for the boot run")?;

	println!("fleetpulse: boot run starting ...");

	// 1. IMDSv2 token + instance identity
	let token       = fetch_imds_token().await?;
	let instance_id = fetch_imds_path(&token, "instance-id").await?;
	println!("  Instance   : {instance_id}");

	// 2. Required instance tags
	let role_str      = fetch_imds_tag(&token, "ipsec-gw-role").await?;
	let peer_mgmt_ip  = fetch_imds_tag(&token, "ipsec-gw-peer-mgmt-ip").await?;
	let rtb_id        = fetch_imds_tag(&token, "ipsec-gw-rtb").await?;

	let role = match role_str.as_str() {
		"master" => Role::Master,
		"backup" => Role::Backup,
		other    => bail!(
			"Tag 'ipsec-gw-role' has unexpected value '{other}'. \
			 Expected 'master' or 'backup'."
		),
	};
	println!("  Role       : {role}");
	println!("  Peer eth1  : {peer_mgmt_ip}");
	println!("  rtb-backend: {rtb_id}");

	// 3. NIC layout from IMDS
	// The shell start_pre has already attached eth1 and brought it up.
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
			 Has start_pre attached and brought up the management ENI?"
		)?;

	let eth1_prefix = parse_prefix(&eth1.subnet_cidr)?;

	println!("  eth0       : {}  ({})", eth0.primary_ip, eth0.eni_id);
	println!("  eth1       : {}  ({})", eth1.primary_ip, eth1.subnet_cidr);

	// 4. Disable src/dest check on eth0 and eth3 (if present).
	// eth0: forwards backend traffic with arbitrary dst IPs to VPN concentrators.
	// eth3: VPN-subnet ENI forwards customer global IPs via L2 to concentrators.
	// eth1 (VRRP heartbeat) and eth2 (BGP ENI) are fine with src/dest check on.
	let creds = fetch_imds_credentials().await?;
	println!("  Disabling src/dest check on {} (eth0) ...", eth0.eni_id);
	disable_src_dest_check(&cli.region, &creds, &eth0.eni_id).await?;
	println!("  Source/dest check disabled on {}", eth0.eni_id);

	// eth3 may not be present in debug/minimal boot -- non-fatal.
	if let Some((_, eth3)) = ifaces.iter().find(|(dev, _)| *dev == 3) {
		println!("  Disabling src/dest check on {} (eth3) ...", eth3.eni_id);
		match disable_src_dest_check(&cli.region, &creds, &eth3.eni_id).await {
			Ok(()) => println!("  Source/dest check disabled on {} (eth3)", eth3.eni_id),
			Err(e)  => eprintln!("  warning: src/dest check on eth3 failed: {e}"),
		}
	} else {
		println!("  eth3 not present -- src/dest check disable skipped");
	}

	// 5. Build state and write to disk
	let state = State {
		instance_id:  instance_id.clone(),
		role:         role_str.clone(),
		region:       cli.region.clone(),
		eth0_eni_id:  eth0.eni_id.clone(),
		eth0_ip:      eth0.primary_ip.clone(),
		eth1_ip:      eth1.primary_ip.clone(),
		eth1_prefix,
		peer_mgmt_ip: peer_mgmt_ip.clone(),
		rtb_id:       rtb_id.clone(),
	};
	let state_json = serde_json::to_string_pretty(&state)?;
	// 0o644 so keepalived_script (which runs the notify scripts) can read it.
	write_file(&cli.state_file, &state_json, 0o644)?;
	println!("  State      -> {}", cli.state_file.display());

	// 6. Render and write config files
	write_file(&cli.vrrp_out,          &render_vrrp_conf(cli, &state, auth_pass), 0o640)?;
	write_file(&cli.notify_master_out, &render_notify_master(cli, &state),        0o750)?;
	write_file(&cli.notify_backup_out, &render_notify_backup(cli, &state),        0o750)?;
	println!("  Written    -> {}", cli.vrrp_out.display());
	println!("  Written    -> {}", cli.notify_master_out.display());
	println!("  Written    -> {}", cli.notify_backup_out.display());

	println!();
	println!("fleetpulse boot run complete.");
	Ok(())
}

// -- NotifyMaster --------------------------------------------------------------

async fn run_notify_master(cli: &Cli) -> Result<()> {
	println!("fleetpulse notify-master: starting ...");

	let state = load_state(&cli.state_file)?;
	let creds = fetch_imds_credentials().await?;

	// Upsert the default route in the backend route table to point at this
	// node's eth0 ENI.  Tries ReplaceRoute first; falls back to CreateRoute
	// when the route does not yet exist (first MASTER election).
	println!(
		"  rtb-backend ({}) 0.0.0.0/0 -> {}",
		state.rtb_id, state.eth0_eni_id,
	);
	upsert_route(
		&state.region, &creds,
		&state.rtb_id, "0.0.0.0/0", &state.eth0_eni_id,
	).await?;
	println!("  backend route table default route updated.");

	write_file(&cli.role_file, "master\n", 0o644)?;
	println!("  Role file written: master -> {}", cli.role_file.display());

	println!("fleetpulse notify-master complete.");
	Ok(())
}

// -- NotifyBackup --------------------------------------------------------------

async fn run_notify_backup(cli: &Cli) -> Result<()> {
	println!("fleetpulse notify-backup: writing role file ...");
	write_file(&cli.role_file, "backup\n", 0o644)?;
	println!("  Role file written: backup -> {}", cli.role_file.display());
	println!("fleetpulse notify-backup complete.");
	Ok(())
}

// -- State helpers -------------------------------------------------------------

fn load_state(path: &Path) -> Result<State> {
	let json = fs::read_to_string(path)
		.with_context(|| format!(
			"Cannot read state file '{}'. \
			 Has fleetpulse (boot mode) run on this instance?",
			path.display()
		))?;
	serde_json::from_str(&json)
		.with_context(|| format!("Cannot parse state file '{}'", path.display()))
}

// -- IMDS helpers --------------------------------------------------------------

/// Fetch a single instance tag from IMDSv2.
/// Requires "Instance tags in metadata" enabled in the launch template.
async fn fetch_imds_tag(token: &str, key: &str) -> Result<String> {
	fetch_imds_path(token, &format!("tags/instance/{key}"))
		.await
		.with_context(|| format!(
			"IMDS tag '{key}' not found. \
			 Is 'Instance tags in metadata' enabled \
			 (LaunchTemplate -> MetadataOptions -> InstanceMetadataTags)?"
		))
}

/// Read all attached network interfaces from IMDS.
/// Returns a list of (device_number, IfaceInfo) sorted by device number.
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

/// Parse the prefix length from a CIDR string, e.g. "172.16.51.64/28" -> 28.
fn parse_prefix(cidr: &str) -> Result<u8> {
	cidr.split('/')
		.nth(1)
		.and_then(|s| s.parse().ok())
		.with_context(|| format!("Cannot parse prefix length from CIDR '{cidr}'"))
}

// -- EC2 API helpers -----------------------------------------------------------

/// Disable the source/dest check on a network interface.
/// Required so the Return GW can forward traffic with arbitrary src/dst IPs
/// without AWS silently dropping it.
async fn disable_src_dest_check(
	region: &str,
	creds: &AwsCredentials,
	eni_id: &str,
) -> Result<()> {
	let host = format!("ec2.{region}.amazonaws.com");
	let xml = aws_query(&host, "ec2", region, creds, &[
		("Action",                    "ModifyNetworkInterfaceAttribute"),
		("Version",                   "2016-11-15"),
		("NetworkInterfaceId",        eni_id),
		("SourceDestCheck.Value",     "false"),
	]).await?;

	match extract_scalar(&xml, "return") {
		Some("true") => Ok(()),
		Some(v)      => bail!("ModifyNetworkInterfaceAttribute returned unexpected value: {v}"),
		None         => bail!("Could not parse ModifyNetworkInterfaceAttribute response:\n{xml}"),
	}
}

/// Create or replace a route in a route table to point at a network interface.
/// Tries ReplaceRoute first; falls back to CreateRoute if the route does not
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
			  || e.to_string().contains("Use CreateRoute") => { /* fall through to create */ }
		Err(e) => return Err(e),
	}

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

// -- Renderers -----------------------------------------------------------------

/// Generate /etc/keepalived/vrrp.conf -- included by the static keepalived.conf.
///
/// One vrrp_instance (VI_RETURNGW) on eth1 with unicast heartbeat.
/// No virtual_ipaddress -- the Return GW uses the route-table failover approach:
/// on MASTER election, notify-master.sh updates the backend route table default
/// route to point at this node's eth0 ENI.
fn render_vrrp_conf(cli: &Cli, state: &State, auth_pass: &str) -> String {
	let role      = if state.role == "master" { Role::Master } else { Role::Backup };
	let priority  = role.priority(cli);
	// nopreempt: the master-role node does not preempt the current master
	// when it comes back after a failure -- avoids unnecessary failovers.
	let nopreempt = if role == Role::Master { "    nopreempt\n" } else { "" };
	let ts        = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ");

	format!(
		r#"# vrrp.conf -- generated by fleetpulse for {instance_id}
# Generated : {ts}
# Role      : {role}
# DO NOT EDIT MANUALLY -- re-run fleetpulse to regenerate.
#
# Interface roles:
#   {iface_data}  data-plane NIC (fixed IP; eth0 ENI used as route target on MASTER)
#   {iface_mgmt}  management NIC (VRRP unicast heartbeat + SSH)
#
# No virtual_ipaddress block: failover is handled by updating the backend
# route table default route (0.0.0.0/0 -> eth0 ENI) via EC2 ReplaceRoute.

vrrp_instance VI_RETURNGW {{
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
		instance_id       = state.instance_id,
		ts                = ts,
		role              = state.role,
		iface_data        = cli.iface_data,
		iface_mgmt        = cli.iface_mgmt,
		vrid              = cli.vrid,
		priority          = priority,
		advert_int        = cli.advert_int,
		down_timer_adverts = cli.down_timer_adverts,
		nopreempt         = nopreempt,
		eth1_ip           = state.eth1_ip,
		peer_mgmt_ip      = state.peer_mgmt_ip,
		auth_pass         = auth_pass,
	)
}

/// Generate /etc/keepalived/notify-master.sh.
fn render_notify_master(cli: &Cli, state: &State) -> String {
	let ts     = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ");
	let binary = std::env::current_exe()
		.unwrap_or_else(|_| PathBuf::from("/usr/local/bin/fleetpulse"));

	format!(
		r#"#!/bin/sh
# notify-master.sh -- generated by fleetpulse for {instance_id}
# Generated : {ts}
# DO NOT EDIT MANUALLY -- re-run fleetpulse to regenerate.
#
# Called by keepalived when VI_RETURNGW transitions to MASTER.
# Updates backend route table default route to this node's eth0 ENI.
# Full fleetpulse output is appended to /run/fleetpulse-notify.log.

set -u
TYPE="${{1:-?}}" NAME="${{2:-?}}" STATE="${{3:-?}}"
logger -p local3.info -t fleetpulse-notify \
    "notify-master[${{TYPE}}/${{NAME}}]: running on {instance_id}"

set +e
{binary} notify-master --region {region} --state-file {state_file} --role-file {role_file} \
    > /run/fleetpulse-notify.log 2>&1
rc=$?
set -e
logger -p local3.info -t fleetpulse-out < /run/fleetpulse-notify.log

if [ $rc -eq 0 ]; then
    logger -p local3.info -t fleetpulse-notify \
        "notify-master[${{TYPE}}/${{NAME}}]: complete"
else
    logger -p local3.err -t fleetpulse-notify \
        "notify-master[${{TYPE}}/${{NAME}}]: FAILED (exit $rc) -- see /run/fleetpulse-notify.log"
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
		.unwrap_or_else(|_| PathBuf::from("/usr/local/bin/fleetpulse"));

	format!(
		r#"#!/bin/sh
# notify-backup.sh -- generated by fleetpulse for {instance_id}
# Generated : {ts}
# DO NOT EDIT MANUALLY -- re-run fleetpulse to regenerate.
#
# Called by keepalived when VI_RETURNGW transitions to BACKUP.
# Writes the role file; ipsecscale-equivalent daemons see backup and idle.

set -u
TYPE="${{1:-?}}" NAME="${{2:-?}}" STATE="${{3:-?}}"
logger -p local3.info -t fleetpulse-notify \
    "notify-backup[${{TYPE}}/${{NAME}}]: running on {instance_id}"

set +e
{binary} notify-backup --state-file {state_file} --role-file {role_file} \
    > /run/fleetpulse-notify.log 2>&1
rc=$?
set -e
logger -p local3.info -t fleetpulse-out < /run/fleetpulse-notify.log

if [ $rc -eq 0 ]; then
    logger -p local3.info -t fleetpulse-notify \
        "notify-backup[${{TYPE}}/${{NAME}}]: complete"
else
    logger -p local3.err -t fleetpulse-notify \
        "notify-backup[${{TYPE}}/${{NAME}}]: FAILED (exit $rc) -- see /run/fleetpulse-notify.log"
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
