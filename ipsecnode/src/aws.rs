//! AWS helper: disable the src/dest check on eth0.
//!
//! Discovers the eth0 ENI ID from IMDSv2 and calls
//! ModifyNetworkInterfaceAttribute (SourceDestCheck=false).
//!
//! Required so that inner packets (customer src IP, mapped global dst IP)
//! are not dropped by AWS after VPP decapsulates them.

use anyhow::{Context, Result};
use tracing::debug;

use aerocore::{
	aws_query, extract_scalar,
	fetch_imds_path, fetch_imds_token,
	AwsCredentials,
	fetch_imds_credentials,
};

// ── Public entry point ────────────────────────────────────────────────────────

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
