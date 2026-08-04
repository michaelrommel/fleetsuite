//! Health and Prometheus-stub HTTP endpoint on port 9101.
//!
//! GET /health  -- returns 200 OK with a plain-text status line.
//!                 Used by ALB health checks and manual verification.
//! GET /metrics -- placeholder; returns empty Prometheus text format.
//!                 Full metrics added in a later increment.

use axum::{Router, routing::get};
use tokio::net::TcpListener;
use tracing::info;

// ── Handlers ──────────────────────────────────────────────────────────────────

async fn health() -> &'static str {
	"OK\n"
}

async fn metrics() -> impl axum::response::IntoResponse {
	(
		[("Content-Type", "text/plain; version=0.0.4; charset=utf-8")],
		"# ipsecnode metrics -- full implementation in Increment 6a+6b+later\n",
	)
}

// ── Server ────────────────────────────────────────────────────────────────────

/// Bind to 0.0.0.0:<port> and serve /health and /metrics forever.
/// Call inside tokio::spawn.
pub async fn serve(port: u16) {
	let app = Router::new()
		.route("/health",  get(health))
		.route("/metrics", get(metrics));

	let listener = TcpListener::bind(("0.0.0.0", port))
		.await
		.unwrap_or_else(|e| panic!("Failed to bind health port {port}: {e}"));

	info!(port, "health endpoint listening");

	axum::serve(listener, app)
		.await
		.unwrap_or_else(|e| panic!("Health server crashed: {e}"));
}
