//! Translation from SiteRecord crypto fields to StrongSwan proposal strings.
//!
//! # OneOrMany
//! Each crypto field accepts either a single value ("aes256") or a JSON array
//! (["aes256","aes128"]).  Both forms deserialise into Vec<T> transparently.
//!
//! # Cartesian product
//! IKE proposals = ike_enc x ike_auth x ike_dh (all combinations in order).
//! ESP proposals = esp_enc x esp_auth x esp_pfs, with invalid combinations
//! filtered silently:
//!   GCM enc + non-"none" auth -> dropped (auth is implicit in GCM)
//!   non-GCM enc + "none" auth -> dropped (encryption without HMAC is unsafe)
//!   esp_pfs = 0               -> no DH suffix on the proposal string
//!
//! # Defaults
//! When ALL fields for a phase are absent, a single strong default is returned.
//! There is no fall-through to an AMI-baked catch-all; every device in Valkey
//! gets an explicit per-site VICI connection.

use serde::{Deserialize, Deserializer};
use tracing::warn;

use crate::credentials::SiteRecord;

// ── OneOrMany<T> ──────────────────────────────────────────────────────────────

/// A field that can hold a single value or a list.
///
/// In Valkey: `"aes256"` or `["aes256","aes128"]`; both deserialise to Vec<T>.
/// The order of elements is preserved and reflects negotiation preference
/// (first element = most preferred).
#[derive(Debug, Clone)]
pub struct OneOrMany<T>(pub Vec<T>);

impl<'de, T: Deserialize<'de>> Deserialize<'de> for OneOrMany<T> {
	fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
		// Use an untagged enum to accept either a single T or a Vec<T>.
		#[derive(Deserialize)]
		#[serde(untagged)]
		enum Helper<T> {
			Single(T),
			Vec(Vec<T>),
		}

		Helper::deserialize(d).map(|h| match h {
			Helper::Single(t) => OneOrMany(vec![t]),
			Helper::Vec(v)    => OneOrMany(v),
		})
	}
}

// ── Defaults ──────────────────────────────────────────────────────────────────

const DEFAULT_IKE: &str = "aes256-sha256-modp2048";
const DEFAULT_ESP: &str = "aes256gcm16";

// ── DH group table ────────────────────────────────────────────────────────────

/// Translate a DH group number to the StrongSwan proposal token.
pub fn dh_group_name(group: u16) -> Option<&'static str> {
	match group {
		1  => Some("modp768"),
		2  => Some("modp1024"),
		5  => Some("modp1536"),
		14 => Some("modp2048"),
		15 => Some("modp3072"),
		16 => Some("modp4096"),
		19 => Some("ecp256"),
		20 => Some("ecp384"),
		21 => Some("ecp521"),
		24 => Some("modp2048s256"),
		_  => None,
	}
}

// ── Token helpers ─────────────────────────────────────────────────────────────

/// True when the encryption name denotes a GCM-family algorithm (AEAD).
pub fn is_gcm(enc: &str) -> bool {
	enc.ends_with("gcm")
}

fn enc_token(enc: &str) -> &str {
	match enc {
		"aes128"    => "aes128",
		"aes192"    => "aes192",
		"aes256"    => "aes256",
		"aes128gcm" => "aes128gcm16",
		"aes192gcm" => "aes192gcm16",
		"aes256gcm" => "aes256gcm16",
		other       => {
			warn!(enc = other, "unrecognised encryption value -- using aes256");
			"aes256"
		}
	}
}

fn auth_token(auth: &str) -> &str {
	match auth {
		"sha256" => "sha256",
		"sha384" => "sha384",
		"sha512" => "sha512",
		other    => {
			warn!(auth = other, "unrecognised auth value -- using sha256");
			"sha256"
		}
	}
}

// ── IKE proposal builder ──────────────────────────────────────────────────────

/// Build the ordered list of IKE proposals for a device.
///
/// Returns a single hardcoded default when no IKE crypto fields are set.
/// When only some fields are present the missing ones default to the first
/// element of the standard default (aes256 / sha256 / modp2048).
pub fn build_ike_proposals(rec: &SiteRecord) -> Vec<String> {
	if rec.ike_enc.is_none() && rec.ike_auth.is_none() && rec.ike_dh.is_none() {
		return vec![DEFAULT_IKE.to_string()];
	}

	let def_enc  = OneOrMany(vec!["aes256".to_string()]);
	let def_auth = OneOrMany(vec!["sha256".to_string()]);
	let def_dh   = OneOrMany(vec![14u16]);

	let encs  = rec.ike_enc.as_ref().unwrap_or(&def_enc);
	let auths = rec.ike_auth.as_ref().unwrap_or(&def_auth);
	let dhs   = rec.ike_dh.as_ref().unwrap_or(&def_dh);

	let mut proposals = Vec::new();

	'outer: for enc in &encs.0 {
		let et = enc_token(enc);
		for auth in &auths.0 {
			let at = auth_token(auth);
			for dh in &dhs.0 {
				let Some(dt) = dh_group_name(*dh) else {
					warn!(group = dh, "unknown ike_dh group -- skipping combination");
					continue 'outer;
				};
				proposals.push(format!("{et}-{at}-{dt}"));
			}
		}
	}

	if proposals.is_empty() {
		warn!("IKE proposal list is empty after building -- using default");
		vec![DEFAULT_IKE.to_string()]
	} else {
		proposals
	}
}

// ── ESP proposal builder ──────────────────────────────────────────────────────

/// Build the ordered list of ESP proposals for a device.
///
/// Returns a single hardcoded default when no ESP crypto fields are set.
///
/// esp_pfs = 0 means no PFS; any positive value is a DH group number.
/// Absent esp_pfs defaults to no PFS.
pub fn build_esp_proposals(rec: &SiteRecord) -> Vec<String> {
	if rec.esp_enc.is_none() && rec.esp_auth.is_none() && rec.esp_pfs.is_none() {
		return vec![DEFAULT_ESP.to_string()];
	}

	let def_enc = OneOrMany(vec!["aes256gcm".to_string()]);
	let def_pfs = OneOrMany(vec![0u16]);

	let encs     = rec.esp_enc.as_ref().unwrap_or(&def_enc);
	let pfs_list = rec.esp_pfs.as_ref().unwrap_or(&def_pfs);

	let mut proposals = Vec::new();

	for enc in &encs.0 {
		let et  = enc_token(enc);
		let gcm = is_gcm(enc);

		// Determine the auth variants for this encryption algorithm.
		// GCM: no separate auth token (auth is implicit).  Only "none" is valid.
		// Non-GCM: explicit HMAC required.  "none" is dropped (unsafe).
		let auth_toks: Vec<Option<&str>> = match rec.esp_auth.as_ref() {
			Some(auths) => auths.0.iter()
				.filter_map(|a| {
					if gcm {
						if a == "none" {
							Some(None)
						} else {
							warn!(enc, auth = a.as_str(),
								"GCM enc ignores explicit auth -- skipping");
							None
						}
					} else {
						if a == "none" {
							warn!(enc, "non-GCM enc without auth is unsafe -- skipping");
							None
						} else {
							Some(Some(auth_token(a)))
						}
					}
				})
				.collect(),
			// No auth field: GCM needs none, non-GCM needs sha256.
			None => vec![if gcm { None } else { Some("sha256") }],
		};

		for auth in &auth_toks {
			for pfs in &pfs_list.0 {
				let pfs_tok: Option<&str> = if *pfs == 0 {
					None
				} else {
					match dh_group_name(*pfs) {
						Some(t) => Some(t),
						None => {
							warn!(group = pfs, "unknown esp_pfs group -- skipping");
							continue;
						}
					}
				};

				let proposal = match (auth, pfs_tok) {
					(None,    None)     => et.to_string(),
					(None,    Some(dh)) => format!("{et}-{dh}"),
					(Some(a), None)     => format!("{et}-{a}"),
					(Some(a), Some(dh)) => format!("{et}-{a}-{dh}"),
				};
				proposals.push(proposal);
			}
		}
	}

	if proposals.is_empty() {
		warn!("ESP proposal list is empty after building -- using default");
		vec![DEFAULT_ESP.to_string()]
	} else {
		proposals
	}
}
