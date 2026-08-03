--
-- strongswan-schema.sql
--
-- PostgreSQL schema for the StrongSwan SQL plugin on fleetnode VPN nodes.
-- Apply to the RDS instance before starting StrongSwan for the first time:
--
--   PGPASSWORD=<password> psql \
--     -h fleetshell-ipsec-strongswan.cpgmocimewi5.eu-west-2.rds.amazonaws.com \
--     -U <admin-user> -d strongswan \
--     -f strongswan-schema.sql
--
-- The SQL plugin reads all peer_configs on startup and re-queries for
-- credentials on each IKE negotiation.  No charon restart is needed when
-- adding new PSKs -- changes are visible immediately.
--
-- PSK auth workflow (per customer device):
--   1. INSERT a type-1 (ID_IPV4_ADDR) identity for the device IP.
--   2. INSERT the PSK as a type-1 shared_secret.
--   3. Link them via shared_secret_identity.
--   The catch-all peer_configs below handle the IKE negotiation; charon
--   selects the PSK by matching the peer source IP to a type-1 identity.
--
-- Identity types (used in identities.type):
--   0  = ID_ANY           wildcard / %any
--   1  = ID_IPV4_ADDR     raw 4-byte IPv4 address (peer IP lookup)
--   2  = ID_FQDN          domain name
--   3  = ID_RFC822_ADDR   email address
--   4  = ID_IPV6_ADDR     raw 16-byte IPv6 address
--   9  = ID_DER_ASN1_DN   X.509 distinguished name
--  11  = ID_KEY_ID        opaque key identifier
--
-- Shared secret types (used in shared_secrets.type):
--   1  = SHARED_IKE       PSK for IKE authentication (what we use)
--   2  = SHARED_EAP       EAP secret
--   3  = SHARED_ECDSA     (unused)
--
-- IKE version values in peer_configs.ike_version:
--   1  = IKEv1
--   2  = IKEv2

-- ── Create database user (run as RDS admin once) ─────────────────────────────
-- CREATE USER strongswan WITH PASSWORD 'PLACEHOLDER';
-- GRANT CONNECT ON DATABASE strongswan TO strongswan;
-- After creating tables: GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES
--   IN SCHEMA public TO strongswan;
-- GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO strongswan;

-- ── Identities ────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS identities (
	id   SERIAL  PRIMARY KEY,
	type INTEGER NOT NULL,
	data BYTEA   NOT NULL,
	UNIQUE(type, data)
);

-- Wildcard identity used as remote_id in catch-all peer_configs.
INSERT INTO identities (type, data) VALUES (0, ''::BYTEA)
	ON CONFLICT DO NOTHING;
-- id=1 is the %any identity; reference it from peer_configs.remote_id.

-- ── IKE endpoint configurations ───────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS ike_configs (
	id          SERIAL  PRIMARY KEY,
	certreq     INTEGER NOT NULL DEFAULT 1,
	force_encap INTEGER NOT NULL DEFAULT 0,
	local       TEXT    NOT NULL,
	remote      TEXT    NOT NULL
);

-- Single catch-all IKE config: accept connections from any peer.
-- certreq=0: do not send a certificate request (PSK-only deployment).
INSERT INTO ike_configs (certreq, force_encap, local, remote)
	VALUES (0, 0, '%any', '%any')
	ON CONFLICT DO NOTHING;
-- id=1; referenced by both IKEv1 and IKEv2 peer_configs below.

-- ── Peer (connection) configurations ─────────────────────────────────────────

CREATE TABLE IF NOT EXISTS peer_configs (
	id           SERIAL  PRIMARY KEY,
	name         TEXT    NOT NULL UNIQUE,
	ike_version  INTEGER NOT NULL DEFAULT 2,
	local_id     INTEGER          REFERENCES identities(id),
	remote_id    INTEGER          REFERENCES identities(id),
	ike_cfg      INTEGER NOT NULL REFERENCES ike_configs(id),
	local_addrs  TEXT    NOT NULL DEFAULT '%any',
	remote_addrs TEXT    NOT NULL DEFAULT '%any',
	in_port      INTEGER NOT NULL DEFAULT 500,
	out_port     INTEGER NOT NULL DEFAULT 500,
	options      INTEGER NOT NULL DEFAULT 0,
	priority     INTEGER NOT NULL DEFAULT 0,
	rekey_time   INTEGER NOT NULL DEFAULT 0,
	reauth_time  INTEGER NOT NULL DEFAULT 0,
	over_time    INTEGER NOT NULL DEFAULT 0,
	rand_time    INTEGER NOT NULL DEFAULT 0
);

-- IKEv2 catch-all: accepts any peer, looks up PSK by source IP.
-- remote_id=1 references the %any identity inserted above.
INSERT INTO peer_configs
	(name, ike_version, remote_id, ike_cfg, local_addrs, remote_addrs)
	VALUES ('fleetipsec-ikev2', 2, 1, 1, '%any', '%any')
	ON CONFLICT DO NOTHING;

-- IKEv1 catch-all: same topology, rightid=%any equivalent.
-- priority=1 lower than IKEv2 so IKEv2 is preferred when both are offered.
INSERT INTO peer_configs
	(name, ike_version, remote_id, ike_cfg, local_addrs, remote_addrs, priority)
	VALUES ('fleetipsec-ikev1', 1, 1, 1, '%any', '%any', 1)
	ON CONFLICT DO NOTHING;

-- ── Child SA (IPsec SA) configurations ───────────────────────────────────────

CREATE TABLE IF NOT EXISTS child_configs (
	id           SERIAL  PRIMARY KEY,
	name         TEXT    NOT NULL UNIQUE,
	lifetime     INTEGER NOT NULL DEFAULT 3600,
	rekeytime    INTEGER NOT NULL DEFAULT 3000,
	jitter       INTEGER NOT NULL DEFAULT 0,
	updown       TEXT,
	hostaccess   INTEGER NOT NULL DEFAULT 0,
	mode         INTEGER NOT NULL DEFAULT 1,
	dpd_action   INTEGER NOT NULL DEFAULT 1,
	start_action INTEGER NOT NULL DEFAULT 0,
	close_action INTEGER NOT NULL DEFAULT 0,
	ipcomp       INTEGER NOT NULL DEFAULT 0,
	inactivity   INTEGER NOT NULL DEFAULT 0,
	reqid        INTEGER NOT NULL DEFAULT 0,
	mark_in      INTEGER NOT NULL DEFAULT 0,
	mark_out     INTEGER NOT NULL DEFAULT 0,
	tfc_padding  INTEGER NOT NULL DEFAULT 0,
	priority     INTEGER NOT NULL DEFAULT 0,
	interface    TEXT
);

-- Single child SA config shared by IKEv1 and IKEv2.
-- mode=1: tunnel mode.  dpd_action=1: clear SA on DPD failure.
INSERT INTO child_configs (name, lifetime, rekeytime, mode, dpd_action)
	VALUES ('fleetipsec-child', 3600, 3000, 1, 1)
	ON CONFLICT DO NOTHING;

-- ── peer_config <-> child_config mapping ─────────────────────────────────────

CREATE TABLE IF NOT EXISTS peer_config_child_config (
	peer_cfg  INTEGER NOT NULL REFERENCES peer_configs(id),
	child_cfg INTEGER NOT NULL REFERENCES child_configs(id),
	PRIMARY KEY(peer_cfg, child_cfg)
);

INSERT INTO peer_config_child_config (peer_cfg, child_cfg)
	VALUES (1, 1), (2, 1)
	ON CONFLICT DO NOTHING;

-- ── Proposals (IKE phase 1 and ESP child SA algorithms) ────────────────────
-- protocol: 1 = IKE, 2 = ESP, 3 = AH

CREATE TABLE IF NOT EXISTS proposals (
	id       SERIAL  PRIMARY KEY,
	protocol INTEGER NOT NULL,
	proposal TEXT    NOT NULL
);

CREATE TABLE IF NOT EXISTS ike_config_proposal (
	ike_cfg  INTEGER NOT NULL REFERENCES ike_configs(id),
	proposal INTEGER NOT NULL REFERENCES proposals(id),
	PRIMARY KEY(ike_cfg, proposal)
);

CREATE TABLE IF NOT EXISTS child_config_proposal (
	child_cfg INTEGER NOT NULL REFERENCES child_configs(id),
	proposal  INTEGER NOT NULL REFERENCES proposals(id),
	PRIMARY KEY(child_cfg, proposal)
);

-- IKE (phase 1) proposals.
INSERT INTO proposals (protocol, proposal) VALUES
	(1, 'aes256-sha256-modp2048'),
	(1, 'aes256-sha1-modp2048'),
	(1, 'aes128-sha256-modp2048')
	ON CONFLICT DO NOTHING;

-- ESP (child SA) proposals.
INSERT INTO proposals (protocol, proposal) VALUES
	(2, 'aes256gcm16'),
	(2, 'aes256-sha256'),
	(2, 'aes128gcm16'),
	(2, 'aes128-sha256')
	ON CONFLICT DO NOTHING;

-- Link IKE proposals to catch-all ike_config (id=1).
INSERT INTO ike_config_proposal (ike_cfg, proposal)
	SELECT 1, id FROM proposals WHERE protocol = 1
	ON CONFLICT DO NOTHING;

-- Link ESP proposals to catch-all child_config (id=1).
INSERT INTO child_config_proposal (child_cfg, proposal)
	SELECT 1, id FROM proposals WHERE protocol = 2
	ON CONFLICT DO NOTHING;

-- ── Traffic selectors ─────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS traffic_selectors (
	id         SERIAL  PRIMARY KEY,
	type       INTEGER NOT NULL DEFAULT 7,
	protocol   INTEGER NOT NULL DEFAULT 0,
	start_addr BYTEA   NOT NULL DEFAULT E'\\x00000000',
	end_addr   BYTEA   NOT NULL DEFAULT E'\\xffffffff',
	start_port INTEGER NOT NULL DEFAULT 0,
	end_port   INTEGER NOT NULL DEFAULT 65535
);

CREATE TABLE IF NOT EXISTS child_config_traffic_selector (
	child_cfg        INTEGER NOT NULL REFERENCES child_configs(id),
	traffic_selector INTEGER NOT NULL REFERENCES traffic_selectors(id),
	kind             INTEGER NOT NULL,
	PRIMARY KEY(child_cfg, traffic_selector, kind)
);

-- ── Shared secrets (PSKs) ─────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS shared_secrets (
	id   SERIAL  PRIMARY KEY,
	type INTEGER NOT NULL,
	data BYTEA   NOT NULL
);

-- Maps PSKs to identities (peer IP addresses).
CREATE TABLE IF NOT EXISTS shared_secret_identity (
	shared_secret INTEGER NOT NULL REFERENCES shared_secrets(id),
	identity      INTEGER NOT NULL REFERENCES identities(id),
	PRIMARY KEY(shared_secret, identity)
);

-- ── Example: insert a PSK for a customer device ───────────────────────────────
-- Replace 192.0.2.1 (device public IP) and 'mysecretpsk' with real values.
-- The IP is stored as a 4-byte big-endian BYTEA (network byte order).
--
-- INSERT INTO identities (type, data)
--     VALUES (1, decode(lpad(to_hex((192::bigint<<24)|(0<<16)|(2<<8)|1), 8, '0'), 'hex'));
-- -- Note the identity id returned (e.g. 42)
--
-- INSERT INTO shared_secrets (type, data)
--     VALUES (1, 'mysecretpsk'::BYTEA);
-- -- Note the shared_secret id returned (e.g. 7)
--
-- INSERT INTO shared_secret_identity (shared_secret, identity) VALUES (7, 42);

-- ── Certificates and private keys (unused; kept for schema completeness) ──────

CREATE TABLE IF NOT EXISTS certificates (
	id   SERIAL  PRIMARY KEY,
	type INTEGER NOT NULL,
	flag INTEGER NOT NULL DEFAULT 0,
	data BYTEA   NOT NULL,
	UNIQUE(type, data)
);

CREATE TABLE IF NOT EXISTS certificate_identity (
	certificate INTEGER NOT NULL REFERENCES certificates(id),
	identity    INTEGER NOT NULL REFERENCES identities(id),
	PRIMARY KEY(certificate, identity)
);

CREATE TABLE IF NOT EXISTS private_keys (
	id   SERIAL  PRIMARY KEY,
	type INTEGER NOT NULL,
	data BYTEA   NOT NULL,
	UNIQUE(type, data)
);

CREATE TABLE IF NOT EXISTS private_key_identity (
	private_key INTEGER NOT NULL REFERENCES private_keys(id),
	identity    INTEGER NOT NULL REFERENCES identities(id),
	PRIMARY KEY(private_key, identity)
);

-- ── Grants (run as admin after creating the strongswan user) ──────────────────
-- GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO strongswan;
-- GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO strongswan;
