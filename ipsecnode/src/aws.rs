//! AWS helper: disable the src/dest check on eth0.
//!
//! Discovers the eth0 ENI ID from IMDSv2 and calls
//! ModifyNetworkInterfaceAttribute (SourceDestCheck=false).
//!
//! Required so that inner packets (customer src IP, mapped global dst IP)
//! are not dropped by AWS after VPP decapsulates them.
//!
//! Also exposes fetch_vip_public_ip() which discovers the customer-facing VIP
//! EIP (by its Name tag) via DescribeAddresses -- used as the local IKE
//! identity this node presents when it INITIATES a tunnel.

use anyhow::{Context, Result};
use tracing::debug;

use aerocore::{
	aws_query, extract_scalar,
	fetch_imds_path, fetch_imds_token,
	AwsCredentials,
	fetch_imds_credentials,
};

// ── Public entry point ────────────────────────────────────────────────────────

/// Discover the customer-facing VIP EIP public IP via DescribeAddresses,
/// filtered by the EIP's Name tag (e.g. "FleetShell-IPSec-VIP").
///
/// Used as the local IKE identity (IDi) this node presents when it INITIATES a
/// tunnel, so standard CPE that key their PSK to our public IP authenticate us.
/// Runs in the node's own region, so it returns this region's VIP.  Returns
/// None on any error or if the tag matches no address -- the caller decides
/// whether that is fatal.
pub async fn fetch_vip_public_ip(region: &str, name_tag: &str) -> Option<String> {
	let creds: AwsCredentials = fetch_imds_credentials().await.ok()?;
	let host = format!("ec2.{region}.amazonaws.com");
	let xml = aws_query(&host, "ec2", region, &creds, &[
		("Action",           "DescribeAddresses"),
		("Version",          "2016-11-15"),
		("Filter.1.Name",    "tag:Name"),
		("Filter.1.Value.1", name_tag),
	])
	.await
	.ok()?;
	extract_scalar(&xml, "publicIp").map(str::to_string)
}

/// This node's primary private IPv4 (IMDS local-ipv4) -- its identity in the LVS
/// jhash pool (the DNAT target the LVS map holds for this node).  Used by the
/// on-demand owner selection (Increment 6g phase 2b) to decide "am I the owner?".
pub async fn local_ipv4() -> Option<String> {
	let token = fetch_imds_token().await.ok()?;
	fetch_imds_path(&token, "local-ipv4").await.ok().map(|s| s.trim().to_string())
}

/// Discover the eth0 ENI ID from IMDS and disable its src/dest check.
/// Returns the ENI ID on success for logging.
pub async fn disable_src_dest_check(region: &str) -> Result<String> {
	let token = fetch_imds_token().await
		.context("IMDS token fetch failed")?;

	// Primary MAC address identifies eth0 (device-number 0).
	let mac = fetch_imds_path(&token, "mac").await
		.context("IMDS mac fetch failed")?;
	let mac = mac.trim();

	let eni_id = fetch_imds_path(
		&token,
		&format!("network/interfaces/macs/{mac}/interface-id"),
	)
	.await
	.context("IMDS ENI ID fetch failed")?;
	let eni_id = eni_id.trim().to_string();

	debug!(%eni_id, "disabling src/dest check");

	let creds: AwsCredentials = fetch_imds_credentials().await
		.context("IMDS credentials fetch failed")?;

	let host = format!("ec2.{region}.amazonaws.com");
	let xml = aws_query(&host, "ec2", region, &creds, &[
		("Action",               "ModifyNetworkInterfaceAttribute"),
		("Version",              "2016-11-15"),
		("NetworkInterfaceId",   &eni_id),
		("SourceDestCheck.Value", "false"),
	])
	.await
	.context("ModifyNetworkInterfaceAttribute call failed")?;

	match extract_scalar(&xml, "return") {
		Some("true") => Ok(eni_id),
		Some(v)      => anyhow::bail!(
			"ModifyNetworkInterfaceAttribute returned unexpected value: {v}"
		),
		None         => anyhow::bail!(
			"Could not parse ModifyNetworkInterfaceAttribute response:\n{xml}"
		),
	}
}
