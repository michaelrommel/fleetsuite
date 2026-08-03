-- insert_test_psk.sql
--
-- Insert a test PSK for a single customer device.
-- Replace 'x.x.x.x' with the test client's actual public IP address
-- and 'testpsk123' with the desired PSK.
--
-- Uses CTEs with RETURNING to avoid currval session-scope issues.
-- Safe to re-run: the ON CONFLICT on identities is a no-op if the
-- identity already exists; the PSK and mapping are always inserted fresh.

\set client_ip '185.17.205.224'
\set psk       'testpsk123'

WITH new_identity AS (
	INSERT INTO identities (type, data)
	VALUES (
		1,
		decode(lpad(to_hex(
			(split_part(:'client_ip', '.', 1)::int << 24) |
			(split_part(:'client_ip', '.', 2)::int << 16) |
			(split_part(:'client_ip', '.', 3)::int <<  8) |
			 split_part(:'client_ip', '.', 4)::int
		), 8, '0'), 'hex')
	)
	ON CONFLICT (type, data) DO UPDATE SET type = EXCLUDED.type
	RETURNING id
),
new_secret AS (
	INSERT INTO shared_secrets (type, data)
	VALUES (1, :'psk'::BYTEA)
	RETURNING id
)
INSERT INTO shared_secret_identity (shared_secret, identity)
SELECT new_secret.id, new_identity.id
FROM new_secret, new_identity;
