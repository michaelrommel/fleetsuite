//! ipsecnode -- per-node VPN concentrator lifecycle daemon.
//!
//! Increment 6a+6b:
//!   - VICI connection to charon + child-updown event subscription
//!   - Bulk PSK load from Valkey at startup via VICI load-shared
//!   - Valkey keyspace pubsub for incremental credential updates
//!   - CA certificate loading from /etc/ipsecnode/ca/ via VICI load-cert
//!   - src/dest check disable on eth0 via EC2 API
//!   - Health endpoint on :9101
//!
//! Increments 6c (FRR routes), 6d (VPP VRF/NAT), 6e (ASG lifecycle),
//! 6f (half-open IKE SA state) are added in subsequent increments.

use std::time::Duration;

use anyhow::{Context, Result};
use tracing::{error, info, warn};

mod aws;
mod config;
mod credentials;
mod health;
mod nat;
mod nodeconfig;
mod proposals;
mod vici;
mod vpp;

use config::Args;

// ── Entry point ───────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<()> {
	tracing_subscriber::fmt()
		.with_env_filter(
			tracing_subscriber::EnvFilter::try_from_default_env()
				.unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
		)
		.init();

	let args = Args::parse_and_load();

	info!(
		vici_socket     = %args.vici_socket,
		valkey_url      = %args.valkey_url,
		ca_cert_dir     = %args.ca_cert_dir,
		health_port     = args.health_port,
		region          = %args.region,
		"ipsecnode starting (Increment 6d)"
	);

	// -- Step 1: Disable src/dest check on eth0 -----------------------------
	// Must happen before traffic flows. Hard timeout of 5 s so a slow or
	// unreachable IMDS endpoint does not hold up the rest of startup.
	info!("disabling src/dest check on eth0 via EC2 API ...");
	match tokio::time::timeout(
		std::time::Duration::from_secs(5),
		aws::disable_src_dest_check(&args.region),
	)
	.await
	{
		Ok(Ok(eni))  => info!(%eni, "src/dest check disabled on eth0"),
		Ok(Err(e))   => warn!("src/dest check disable failed (continuing): {e:#}"),
		Err(_timeout) => warn!("src/dest check disable timed out after 5 s (continuing)"),
	}

	// -- Step 2: Initialise VPP data plane ----------------------------------
	// Creates tap interfaces, enables NAT44, sets VPP default route.
	// If VPP is not running, continues in degraded mode (no data plane).
	info!("initialising VPP data plane ...");
	let vpp_state = match vpp::init().await {
		Ok(taps) => taps,
		Err(e)   => {
			warn!("VPP init error: {e:#} -- continuing without VPP data plane");
			None
		}
	};
	if vpp_state.is_some() {
		info!("VPP data plane ready");
	} else {
		warn!("VPP data plane unavailable -- 6d NAT/routing will be skipped");
	}

	// -- Step 3: Connect to VICI (command connection) -----------------------
	info!(socket = %args.vici_socket, "connecting to VICI (command connection) ...");
	let mut cmd_client = vici::connect_with_retry(&args.vici_socket, 30).await
		.context("Could not connect to VICI socket after retries")?;
	info!("VICI command connection established");

	// -- Step 4: Bulk-load PSKs from Valkey via VICI load-shared ------------
	info!(url = %args.valkey_url, "connecting to Valkey for bulk PSK load ...");
	let valkey_client =
		aerocore::redis_pool::build_redis_client(&args.valkey_url, true, false, &None)
			.context("Failed to build Valkey client")?;
	let mut valkey_cmd =
		valkey_client.get_multiplexed_async_connection().await
			.context("Failed to connect to Valkey")?;
	info!("Valkey connection established");

	// Enable keyspace notifications so the pubsub listener works.
	// KEg$: Keyspace + Keyevent, generic commands (DEL) + string commands (SET/GETSET).
	credentials::enable_keyspace_notifications(&mut valkey_cmd).await?;

	let loaded = credentials::bulk_load(&mut cmd_client, &mut valkey_cmd).await
		.context("Bulk PSK load from Valkey failed")?;
	info!(count = loaded, "PSKs loaded into charon via VICI");

	// -- Step 5: Load CA certificates ----------------------------------------
	let ca_count = vici::load_ca_certs(&mut cmd_client, &args.ca_cert_dir).await
		.context("CA certificate loading failed")?;
	info!(count = ca_count, dir = %args.ca_cert_dir, "CA certificates loaded");

	// -- Step 6: Connect to VICI (event connection) -------------------------
	info!(socket = %args.vici_socket, "connecting to VICI (event connection) ...");
	let mut evt_client = vici::connect_with_retry(&args.vici_socket, 30).await
		.context("Could not connect to VICI event socket after retries")?;
	let child_updown_stream = evt_client.subscribe::<vici::ViciRawValue>("child-updown");
	info!("subscribed to VICI child-updown events");

	// -- Step 7: Connect to Valkey pubsub (separate connection required) ----
	info!("opening Valkey pubsub connection ...");
	let valkey_pubsub =
		valkey_client.get_async_pubsub().await
			.context("Failed to open Valkey pubsub connection")?;

	// -- Step 8: Spawn background tasks -------------------------------------

	// child-updown event listener (keeps evt_client alive as _keep_alive).
	// valkey_client is cloned so the event task has its own handle for NAT
	// record lookups (Increment 6c) without contending with the pubsub task.
	let event_handle = tokio::spawn(vici::event_listener_task(
		evt_client,
		child_updown_stream,
		valkey_client.clone(),
		vpp_state,
	));

	// Valkey pubsub listener drives incremental VICI credential updates.
	let cred_handle = tokio::spawn(credentials::pubsub_task(
		cmd_client,
		valkey_client.clone(),
		valkey_pubsub,
	));

	// Health + metrics HTTP endpoint.
	let health_handle = tokio::spawn(health::serve(args.health_port));

	info!("all tasks spawned -- ipsecnode running");

	// Wait for any task to exit (they run forever; exit indicates a fault).
	tokio::select! {
		res = event_handle => {
			error!("VICI event listener task exited: {:?}", res);
		}
		res = cred_handle => {
			error!("Valkey credential task exited: {:?}", res);
		}
		res = health_handle => {
			error!("health server task exited: {:?}", res);
		}
	}

	// systemd Restart=on-failure will relaunch us.
	// Brief pause prevents tight restart loops if VICI or Valkey is down.
	tokio::time::sleep(Duration::from_secs(5)).await;
	Err(anyhow::anyhow!("ipsecnode exiting (task failure)"))
}
