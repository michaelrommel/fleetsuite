--
-- strongswan-schema-patch1.sql
--
-- Adds proposals tables (missing from initial schema) and populates them
-- with the IKE and ESP proposals that match koi's s2-ikev1-natt config.
--
-- Apply via the same SSH tunnel used for the initial schema:
--   psql -h localhost -p 15432 -U strongswan -d strongswan \
--        -f infrastructure/strongswan-schema-patch1.sql
--
-- IKE proposals match koi's:  aes256-sha256-modp2048, aes256-sha1-modp2048,
--                              aes128-sha256-modp2048
-- ESP proposals match koi's:  aes256gcm16, aes256-sha256,
--                              aes128gcm16, aes128-sha256
--
-- protocol values: 1 = IKE, 2 = ESP, 3 = AH

-- ── Tables ────────────────────────────────────────────────────────────────────

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

-- ── IKE (phase 1) proposals ───────────────────────────────────────────────────

INSERT INTO proposals (protocol, proposal) VALUES
	(1, 'aes256-sha256-modp2048'),
	(1, 'aes256-sha1-modp2048'),
	(1, 'aes128-sha256-modp2048');

-- ── ESP (child SA) proposals ──────────────────────────────────────────────────

INSERT INTO proposals (protocol, proposal) VALUES
	(2, 'aes256gcm16'),
	(2, 'aes256-sha256'),
	(2, 'aes128gcm16'),
	(2, 'aes128-sha256');

-- ── Link proposals to the catch-all ike_config (id=1) ────────────────────────

INSERT INTO ike_config_proposal (ike_cfg, proposal)
	SELECT 1, id FROM proposals WHERE protocol = 1;

-- ── Link ESP proposals to the catch-all child_config (id=1) ──────────────────

INSERT INTO child_config_proposal (child_cfg, proposal)
	SELECT 1, id FROM proposals WHERE protocol = 2;
