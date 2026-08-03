-- Device public IP: e.g. your office IP or a test host
-- Insert identity (type 1 = ID_IPV4_ADDR, 4-byte big-endian)
--INSERT INTO identities (type, data)
-- VALUES (1, decode(lpad(to_hex(
--   (185::bigint<<24)|(17<<16)|(205<<8)|224), 8, '0'), 'hex'));
-- where x.y.z.w is the test client's public IP
-- 185.17.205.224 is koi via mnet

-- Insert PSK and link it
--INSERT INTO shared_secrets (type, data) VALUES (1, 'testpsk123'::BYTEA);
INSERT INTO shared_secret_identity (shared_secret, identity)
 VALUES (currval('shared_secrets_id_seq'), currval('identities_id_seq'));
