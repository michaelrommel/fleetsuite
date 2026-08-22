//! ipsecnode.toml configuration file -- types and loader.
//!
//! Default path: /etc/ipsecnode/ipsecnode.toml
//! Override:     IPSECNODE_CONFIG environment variable.
//!
//! The file is optional: absent = no backend NAT, no global service routing.
//! Present but unparseable = fatal startup error.
//!
//! # Example
//!
//! ```toml
//! # [node].local_ike_id is an OPTIONAL override; normally the customer-facing
//! # EIP is discovered via DescribeAddresses using the VIP EIP's Name tag.
//! # [node]
//! # local_ike_id = "3.11.124.22"
//! # vip_name_tag = "FleetShell-IPSec-VIP"
//!
//! [backend.access_server]
//! real_ip = "172.16.53.6"
//!
//! [[backend.access_server.split]]
//! ports = [8080]
//! pool  = "proxy"          # dynamic ECMP pool (fleetipsec:proxy:pool)
//!
//! [[backend.access_server.split]]
//! ports   = [21, 22]
//! dnat_to = "172.16.48.10"
//!
//! [[backend.access_server.split]]
//! port_from = 20000        # passive-FTP data-port range -> the FTP VIP
//! port_to   = 49999
//! dnat_to   = "172.16.48.10"
//!
//! [backend.sd_server]
//! real_ip = "172.16.53.8"
//!
//! [backend.em_server]
//! real_ip = "172.16.53.9"
//! ```

use anyhow::{Context, Result};
use serde::Deserialize;
use tracing::info;

pub const DEFAULT_CONFIG_PATH: &str = "/etc/ipsecnode/ipsecnode.toml";
pub const CONFIG_ENV_VAR:      &str = "IPSECNODE_CONFIG";

/// Default Name tag of the customer-facing VIP EIP (DescribeAddresses filter).
pub const DEFAULT_VIP_NAME_TAG: &str = "FleetShell-IPSec-VIP";

// ── Config types ──────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize, Clone, Default)]
pub struct IpsecnodeConfig {
	#[serde(default)]
	pub backend: BackendConfig,
	#[serde(default)]
	pub node: NodeConfig,
}

/// Node-wide identity/config not specific to any backend role.
#[derive(Debug, Deserialize, Clone, Default)]
pub struct NodeConfig {
	/// Stable local IKE identity (IDi) this concentrator presents when it
	/// INITIATES a tunnel toward a customer.  Must be the customer-facing EIP,
	/// because standard CPE (Cisco `crypto isakmp key <psk> address <EIP>`, etc.)
	/// key their PSK to our public IP.  Presenting the node's private IP makes
	/// every such device answer AUTHENTICATION_FAILED.
	///
	/// OPTIONAL per-host override.  Normally left unset: the EIP is discovered
	/// at startup via DescribeAddresses, filtered by the VIP EIP's Name tag
	/// (vip_name_tag), so a new regional deployment needs no file edit.
	/// Absent from BOTH = responder-only (node falls back to its own IP).
	pub local_ike_id: Option<String>,

	/// Name tag of the customer-facing VIP EIP, looked up via DescribeAddresses
	/// when local_ike_id is not set.  Defaults to DEFAULT_VIP_NAME_TAG.
	pub vip_name_tag: Option<String>,
}

/// Global backend server roles.
///
/// real_ip and port-split rules are the same for every customer site.
/// The customer_view_ip for each role is stored per-customer in Valkey
/// (fleetipsec:nat:<peer_ip> -> backend_nat field).
#[derive(Debug, Deserialize, Clone, Default)]
pub struct BackendConfig {
	pub access_server: Option<ServerConfig>,
	pub sd_server:     Option<ServerConfig>,
	pub em_server:     Option<ServerConfig>,
}

impl BackendConfig {
	/// Return the real_ip for a named role, or None if not configured.
	pub fn real_ip_for(&self, role: &str) -> Option<&str> {
		self.server_for(role).map(|s| s.real_ip.as_str())
	}

	/// Return the ServerConfig for a named role.
	pub fn server_for(&self, role: &str) -> Option<&ServerConfig> {
		match role {
			"access_server" => self.access_server.as_ref(),
			"sd_server"     => self.sd_server.as_ref(),
			"em_server"     => self.em_server.as_ref(),
			_               => None,
		}
	}
}

#[derive(Debug, Deserialize, Clone)]
pub struct ServerConfig {
	/// Real AWS IP for this server role (same for all customers).
	pub real_ip: String,
	/// Port-based DNAT rules applied on vpp-outer after per-customer VPP SNAT.
	/// Rules are evaluated top-down; first match wins.
	#[serde(default)]
	pub split: Vec<SplitRule>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct SplitRule {
	/// TCP destination ports to match (tcp dport).
	/// Mutually exclusive with src_ports / port_from+port_to.
	#[serde(default)]
	pub ports: Vec<u16>,
	/// TCP source ports to match (tcp sport).
	/// For non-RFC FTP clients that send passive data from source port 20.
	/// Mutually exclusive with ports / port_from+port_to.
	#[serde(default)]
	pub src_ports: Vec<u16>,
	/// Inclusive lower bound of a contiguous TCP destination-port RANGE
	/// (tcp dport <from>-<to>). Used for the passive-FTP data-port range
	/// (20000-49999) which is far too wide to list element-by-element.
	/// Set together with `port_to`; mutually exclusive with ports / src_ports.
	#[serde(default)]
	pub port_from: Option<u16>,
	/// Inclusive upper bound of the destination-port range (see `port_from`).
	#[serde(default)]
	pub port_to: Option<u16>,
	/// Fixed IP address to DNAT matching traffic to. Mutually exclusive with
	/// `pool`. Exactly one of `dnat_to` / `pool` must be set.
	#[serde(default)]
	pub dnat_to: Option<String>,
	/// Dynamic ECMP destination pool name (e.g. "proxy"). Matching traffic is
	/// load-balanced across the pool members published by ipsecscale to
	/// `fleetipsec:<pool>:pool`, via `dnat to jhash ip saddr mod N map {...}`.
	/// The membership is applied at runtime by the proxy-pool consumer task,
	/// so the destination set changes as proxies scale in/out. Mutually
	/// exclusive with `dnat_to`.
	#[serde(default)]
	pub pool: Option<String>,
}

// ── Loader ────────────────────────────────────────────────────────────────────

/// Load the ipsecnode config file.
///
/// Path resolution: IPSECNODE_CONFIG env var, then DEFAULT_CONFIG_PATH.
/// Returns a default (empty) config if the file does not exist.
/// Returns Err if the file exists but cannot be parsed.
pub fn load() -> Result<IpsecnodeConfig> {
	let path = std::env::var(CONFIG_ENV_VAR)
		.unwrap_or_else(|_| DEFAULT_CONFIG_PATH.to_string());

	if !std::path::Path::new(&path).exists() {
		info!(%path, "config file absent -- using defaults (no backend NAT)");
		return Ok(IpsecnodeConfig::default());
	}

	let raw = std::fs::read_to_string(&path)
		.with_context(|| format!("read config file {path}"))?;
	let cfg: IpsecnodeConfig = toml::from_str(&raw)
		.with_context(|| format!("parse config file {path}"))?;

	info!(%path, "ipsecnode config loaded");
	Ok(cfg)
}
