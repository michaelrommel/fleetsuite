//! `squid-infoproxy` -- a Squid `external_acl_type` helper for Info Proxy
//! destination authorization.
//!
//! Squid only sees the CLIENT IP at request time; device modality / product /
//! serial is resolved OFFLINE by the spooler
//! (`fleetshell-portal-dev/src/lib/server/infoproxy.ts` /
//! `scripts/spool-infoproxy.mjs`) into SCOPE-TIERED allow-lists in Valkey:
//!
//! ```text
//! SET  infoproxy:<proxy_type>:global           -- ANY/ANY bindings (every device)
//! SET  infoproxy:<proxy_type>:model:<partno>   -- bindings scoped to a model
//! SET  infoproxy:<proxy_type>:device:<src_ip>  -- device-specific bindings
//! ```
//!
//! The device's model is resolved at request time from `partno` in the shared
//! device hash `systems:by-ip:<src_ip>` (written write-through by the portal
//! device spooler; one partno == one model). Tiering keeps writes O(1) per
//! master-data change instead of O(fleet): a global URL edit rewrites ONE key,
//! and adding/moving a device needs no infoproxy spool at all.
//!
//! This helper unions the applicable tiers and answers `OK` iff any member
//! matches the requested destination + port. A MISSING key => that tier is
//! empty (default DENY overall). Squid caches the verdict (ttl=...), so this
//! runs once per (src, dst, port, method) tuple.
//!
//! Modes (`--proxy-type`):
//!   * `intranet` / `internet` -- authorize against that single namespace;
//!     answer plain `OK`/`ERR`. Use when running two independent Squids.
//!   * `both` -- authorize against BOTH namespaces in one call for a single
//!     dual-homed Squid, and additionally CLASSIFY the request for routing by
//!     returning a Squid `tag=`: `OK tag=intranet` (destination is in the
//!     device's intranet allow-list; intranet wins over internet on overlap),
//!     `OK tag=internet`, or `ERR`. squid.conf matches the tag with
//!     `acl is_intranet tag intranet` and drives `never_direct` /
//!     `always_direct` / `cache_peer_access` from it -- so one helper call
//!     yields both the authz verdict AND the DIRECT-vs-intranet-peer routing
//!     decision, from data the portal already spools per proxy_type. No static
//!     dstdomain file is needed.
//!
//! Squid configuration (dual-homed `both` Squid):
//!
//! ```text
//! external_acl_type infoproxy \
//!     ttl=60 negative_ttl=10 children-max=40 \
//!     %SRC %DST %PORT %METHOD %>rd \
//!     /usr/local/bin/squid-infoproxy --proxy-type both
//! acl infoproxy_ok external infoproxy
//! acl is_intranet  tag intranet
//! http_access allow infoproxy_ok
//! http_access deny all
//! cache_peer_access intranet allow is_intranet
//! cache_peer_access intranet deny all
//! never_direct  allow  is_intranet
//! always_direct allow !is_intranet
//! ```
//!
//! Input line fields (in the order requested above): `SRC DST PORT METHOD RD`.

mod matcher;
mod valkey;

use std::io::{self, BufRead, Write};

use matcher::{rule_allows, Request, Rule};
use valkey::{Valkey, ValkeyConfig};

struct Args {
	proxy_type: String,
	valkey_url: String,
	tls_insecure: bool,
	strict_proto: bool,
	concurrent: bool,
}

fn usage() -> ! {
	eprintln!(
		"squid-infoproxy -- Squid external_acl helper for Info Proxy\n\
		 \n\
		 USAGE:\n\
		 \x20 squid-infoproxy --proxy-type <intranet|internet> [options]\n\
		 \n\
		 OPTIONS:\n\
		 \x20 --proxy-type <t>   which Squid this serves: intranet|internet|both (required)\n\
		 \x20 --valkey-url <url> redis(s):// URL (env VALKEY_URL, else rediss://localhost:6380)\n\
		 \x20 --tls-insecure     skip Valkey TLS cert validation (env VALKEY_TLS_REJECT_UNAUTHORIZED=false)\n\
		 \x20 --strict-proto     enforce the freeform protocol label (default: advisory)\n\
		 \x20 --concurrent       Squid concurrency: first field is a channel id echoed back\n\
		 \x20 -h, --help         this help"
	);
	std::process::exit(2);
}

fn parse_args() -> Args {
	let mut proxy_type: Option<String> = None;
	let mut valkey_url = std::env::var("VALKEY_URL").unwrap_or_else(|_| "rediss://localhost:6380".into());
	// Mirror the portal's convention: VALKEY_TLS_REJECT_UNAUTHORIZED=false => insecure.
	let mut tls_insecure = std::env::var("VALKEY_TLS_REJECT_UNAUTHORIZED")
		.map(|v| v == "false")
		.unwrap_or(false);
	let mut strict_proto = false;
	let mut concurrent = false;

	let mut it = std::env::args().skip(1);
	while let Some(arg) = it.next() {
		match arg.as_str() {
			"--proxy-type" => proxy_type = it.next(),
			"--valkey-url" => valkey_url = it.next().unwrap_or_else(|| usage()),
			"--tls-insecure" => tls_insecure = true,
			"--strict-proto" => strict_proto = true,
			"--concurrent" => concurrent = true,
			"-h" | "--help" => usage(),
			other => {
				eprintln!("squid-infoproxy: unknown argument '{other}'");
				usage();
			}
		}
	}

	let proxy_type = proxy_type.unwrap_or_else(|| {
		eprintln!("squid-infoproxy: --proxy-type is required");
		usage();
	});
	if proxy_type != "intranet" && proxy_type != "internet" && proxy_type != "both" {
		eprintln!("squid-infoproxy: --proxy-type must be 'intranet', 'internet' or 'both'");
		usage();
	}

	Args { proxy_type, valkey_url, tls_insecure, strict_proto, concurrent }
}

/// Does any member of set `key` allow `req`? A missing key => `Ok(false)`
/// (default deny). Any Valkey/transport error => `Err(())` (fail closed).
fn key_allows(
	valkey: &mut Valkey,
	key: &str,
	req: &Request<'_>,
	strict_proto: bool,
) -> Result<bool, ()> {
	let members = match valkey.smembers(key) {
		Ok(m) => m,
		Err(e) => {
			eprintln!("squid-infoproxy: valkey error for {key}: {e}");
			return Err(());
		}
	};
	Ok(members
		.iter()
		.any(|m| rule_allows(&Rule::parse(m), req, strict_proto)))
}

/// Is `req` authorized within one proxy namespace, unioning the three scope
/// tiers (global / model-by-partno / device-by-ip)? Short-circuits on the first
/// match. Missing tiers are simply empty; a Valkey error fails closed.
///
/// Keys (see `infoproxy.ts` spooler):
///   infoproxy:<pt>:global                -- ANY/ANY bindings (every device)
///   infoproxy:<pt>:model:<partno>        -- bindings scoped to the device model
///   infoproxy:<pt>:device:<src_ip>       -- device-specific bindings
fn tier_allows(
	valkey: &mut Valkey,
	pt: &str,
	src: &str,
	partno: Option<&str>,
	req: &Request<'_>,
	strict_proto: bool,
) -> Result<bool, ()> {
	if key_allows(valkey, &format!("infoproxy:{pt}:global"), req, strict_proto)? {
		return Ok(true);
	}
	if let Some(pn) = partno {
		if !pn.is_empty()
			&& key_allows(valkey, &format!("infoproxy:{pt}:model:{pn}"), req, strict_proto)?
		{
			return Ok(true);
		}
	}
	key_allows(valkey, &format!("infoproxy:{pt}:device:{src}"), req, strict_proto)
}

/// Decide the verdict for one request. `fields` = [SRC, DST, PORT, METHOD, RD].
///
/// Single-namespace modes return `OK`/`ERR`. The `both` mode additionally
/// classifies for routing (intranet wins) and returns a Squid `tag=`.
fn decide(valkey: &mut Valkey, args: &Args, fields: &[&str]) -> &'static str {
	let get = |i: usize| fields.get(i).copied().unwrap_or("-");
	let src = get(0);
	let dst = get(1);
	let port_s = get(2);
	let method = get(3);
	let rd = get(4);

	if src.is_empty() || src == "-" {
		return "ERR";
	}
	let dst_ip = if dst != "-" && !dst.is_empty() { dst.parse().ok() } else { None };
	// Prefer the requested host; fall back to the (possibly IP) destination.
	let dst_host = if rd != "-" && !rd.is_empty() {
		rd
	} else if dst != "-" {
		dst
	} else {
		""
	};
	let port = port_s.parse::<u16>().ok();
	let req = Request { dst_ip, dst_host, port, method };

	// Resolve the device's model via its partno from the shared device hash
	// (systems:by-ip:<ip>, written by the portal device spooler). Absent hash =>
	// no model tier (global + device-specific still apply, matching ANY/ANY
	// semantics). A transport error fails closed.
	let partno = match valkey.hget(&format!("systems:by-ip:{src}"), "partno") {
		Ok(v) => v,
		Err(e) => {
			eprintln!("squid-infoproxy: valkey error for systems:by-ip:{src}: {e}");
			return "ERR";
		}
	};
	let partno = partno.as_deref();

	if args.proxy_type == "both" {
		// Intranet takes precedence: a destination authorized as intranet is
		// routed to the cache_peer even if it also appears in the internet set,
		// keeping internal traffic off the public NAT. Fail closed on error.
		match tier_allows(valkey, "intranet", src, partno, &req, args.strict_proto) {
			Ok(true) => return "OK tag=intranet",
			Ok(false) => {}
			Err(()) => return "ERR",
		}
		return match tier_allows(valkey, "internet", src, partno, &req, args.strict_proto) {
			Ok(true) => "OK tag=internet",
			_ => "ERR",
		};
	}

	match tier_allows(valkey, &args.proxy_type, src, partno, &req, args.strict_proto) {
		Ok(true) => "OK",
		_ => "ERR",
	}
}

fn main() {
	let args = parse_args();
	let cfg = match ValkeyConfig::parse(&args.valkey_url, args.tls_insecure) {
		Ok(c) => c,
		Err(e) => {
			eprintln!("squid-infoproxy: {e}");
			std::process::exit(2);
		}
	};
	let mut valkey = match Valkey::new(cfg) {
		Ok(v) => v,
		Err(e) => {
			eprintln!("squid-infoproxy: {e}");
			std::process::exit(2);
		}
	};

	let stdin = io::stdin();
	let mut stdout = io::stdout();
	for line in stdin.lock().lines() {
		let line = match line {
			Ok(l) => l,
			Err(_) => break,
		};
		if line.trim().is_empty() {
			continue;
		}
		let mut tokens: Vec<&str> = line.split_whitespace().collect();

		// Squid concurrency: the first token is a channel id echoed back verbatim.
		let channel = if args.concurrent && !tokens.is_empty() {
			Some(tokens.remove(0))
		} else {
			None
		};

		let verdict = decide(&mut valkey, &args, &tokens);
		let out = match channel {
			Some(ch) => format!("{ch} {verdict}\n"),
			None => format!("{verdict}\n"),
		};
		if stdout.write_all(out.as_bytes()).is_err() || stdout.flush().is_err() {
			break;
		}
	}
}
