//! CLI arguments and environment-variable configuration for ipsecnode.

use clap::Parser;

// ── CLI ───────────────────────────────────────────────────────────────────────

#[derive(Parser, Debug)]
#[command(name = "ipsecnode")]
#[command(about = "IPSec VPN concentrator lifecycle daemon (Increment 6a+6b)")]
pub struct Args {
	/// Path to the charon VICI Unix socket.
	#[arg(long, default_value = "/var/run/charon.vici")]
	pub vici_socket: String,

	/// Valkey (MemoryDB) connection URL.
	/// MemoryDB requires TLS; use rediss:// scheme.
	/// Loaded from the IMDS instance tag ipsec-valkey-endpoint at startup
	/// if not provided on the command line.
	#[arg(
		long,
		env = "VALKEY_URL",
		default_value = "rediss://clustercfg.dev-valkey-aeroftp.ak121m.memorydb.eu-west-2.amazonaws.com:6379"
	)]
	pub valkey_url: String,

	/// Directory containing CA certificate PEM files for VICI load-cert.
	/// ipsecnode loads every *.pem / *.crt file in this directory at startup.
	#[arg(long, default_value = "/etc/ipsecnode/ca")]
	pub ca_cert_dir: String,

	/// Port for the health + Prometheus metrics HTTP endpoint.
	#[arg(long, default_value_t = 9101)]
	pub health_port: u16,

	/// AWS region (used for the EC2 src/dest check disable call).
	/// Defaults to eu-west-2; overridden by the IMDS region at startup.
	#[arg(long, default_value = "eu-west-2", env = "AWS_DEFAULT_REGION")]
	pub region: String,
}

impl Args {
	/// Parse CLI arguments.  In production the IMDS-derived region overrides
	/// the default; this is handled in main after IMDS is queried.
	pub fn parse_and_load() -> Self {
		Self::parse()
	}
}
