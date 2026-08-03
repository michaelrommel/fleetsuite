# FleetSuite -- IPSec Test Client Setup (Debian 13 Trixie)

This document describes how to configure a Debian 13 Trixie machine as a
manual IPSec test client against the FleetSuite VPN concentrator at
`3.11.124.22` (the floating EIP).

Four test scenarios are covered:

| # | IKE version | ESP transport | Notes |
|---|-------------|---------------|-------|
| S1 | IKEv1 | Raw ESP (proto 50) | Requires direct public IP (no NAT) |
| S2 | IKEv1 | NAT-T (UDP 4500) | Works behind home ISP NAT |
| S3 | IKEv2 | Raw ESP (proto 50) | Requires direct public IP (no NAT) |
| S4 | IKEv2 | NAT-T (UDP 4500) | Works behind home ISP NAT |

> **NAT-T and your ISP** -- Most home ISPs use NAT (or CGNAT). Raw ESP
> (proto 50) is a layer-4 protocol with no port number; NAT boxes cannot
> track it and will silently drop it. If you are behind your home router
> you will almost certainly need NAT-T (S2 or S4). To test S1/S3 you need
> a machine with a direct, routable public IPv4 address (e.g. a VPS).
> StrongSwan detects NAT automatically using NAT-D payloads; `encap = yes`
> forces UDP 4500 encapsulation even when no NAT is detected.

---

## 1. How the Server Identifies You

The server (StrongSwan SQL plugin) looks up your PSK by the **source IP
address of the IKE packet** it receives, not by any identity you claim.
A row in the `identities` table of type `1` (ID_IPV4_ADDR) stores a
4-byte big-endian representation of that IP. The PSK linked to it is used
for authentication.

Consequence for NAT:
- **Behind NAT (S2/S4):** the source IP the server sees is your NAT
  gateway's public IP (your home router WAN IP or your ISP's CGNAT IP).
  The PSK must be keyed to *that* IP, not your private address.
  Run `curl -s https://checkip.amazonaws.com` from the client machine to
  find it.
- **Direct public IP (S1/S3):** the PSK is keyed to the machine's own
  public IP.

Your `local.id` in the swanctl connection block should be set to the same
IP that the server will see as the source. The server's `remote_id = %any`
means it ignores whatever identity you claim, but StrongSwan uses the
local ID to select the right PSK from the secrets section on the *client*
side too.

---

## 2. Package Installation

Install the modern swanctl-based StrongSwan stack. The `charon-systemd`
package integrates with journald and replaces the legacy `strongswan-starter`
/ `ipsec` front-end. Do **not** install both; they conflict on the charon
socket.

```bash
sudo apt update
sudo apt install \
    charon-systemd \
    strongswan-swanctl \
    libcharon-extra-plugins \
    libstrongswan-standard-plugins \
    libstrongswan-extra-plugins
```

Package roles:

| Package | Contents |
|---------|----------|
| `charon-systemd` | charon IKE daemon with systemd socket activation and journal logging |
| `strongswan-swanctl` | `swanctl` CLI + vici plugin + `/etc/swanctl/` config support |
| `libcharon-extra-plugins` | updown, xauth-*, resolve, kernel-netlink, socket-default, ... |
| `libstrongswan-standard-plugins` | aes, sha1, sha2, hmac, gmp, x509, pem, pkcs1, pubkey, random |
| `libstrongswan-extra-plugins` | curve25519 (x25519 DH), sha3, chapoly (chacha20poly1305), gcm, pkcs8 |

Verify the daemon started:

```bash
sudo systemctl status strongswan.service
sudo swanctl --version
```

### Silencing the agent plugin warning

The `agent` plugin (SSH-agent forwarding for charon) is bundled inside
`libcharon-extra-plugins` but requires `CAP_SETUID`/`CAP_SETGID` to
initialise. It will always print a warning both when the daemon starts and
when `swanctl` runs, because `swanctl` is a libstrongswan-only tool that
also tries to load plugins.

The `load = no` approach in `strongswan.d/charon/agent.conf` only works for
the daemon (`charon-systemd`) which uses `load_modular = yes`. It does not
apply to `swanctl` because `swanctl` has no `charon` global and cannot load
charon-tier plugins at all -- attempting to force modular loading in a
`swanctl {}` config section makes things worse (all charon plugins fail with
`undefined symbol: charon`). The reliable fix is to hide the `.so`:

```bash
sudo mv /usr/lib/ipsec/plugins/libstrongswan-agent.so \
        /usr/lib/ipsec/plugins/libstrongswan-agent.so.disabled
```

No restart needed. The running daemon already loaded its plugins at startup
and will not re-read the plugin directory.

---

## 3. Configuration Layout

`charon-systemd` reads `/etc/strongswan.conf` and then loads swanctl
configuration from `/etc/swanctl/`. The structure used here:

```
/etc/strongswan.conf               # daemon settings (logging, threads)
/etc/swanctl/
    conf.d/
        00-secrets.conf            # PSK -- shared by all scenarios
        s1-ikev1-raw.conf          # Scenario S1: IKEv1 + raw ESP
        s2-ikev1-natt.conf         # Scenario S2: IKEv1 + NAT-T forced
        s3-ikev2-raw.conf          # Scenario S3: IKEv2 + raw ESP
        s4-ikev2-natt.conf         # Scenario S4: IKEv2 + NAT-T forced
```

All four scenario files are loaded at startup (charon reads all `conf.d/*.conf`
files). Only the one you explicitly initiate with `swanctl --initiate` is
active. Terminate one before starting another.

---

## 4. `/etc/strongswan.conf`

Replace the installed file (if any) with this minimal version:

```
# /etc/strongswan.conf -- test client

charon-systemd {
    load_modular = yes

    # Increase log verbosity for testing.
    # ike=2: show SA negotiation; net=1: show packet-level NAT detection
    syslog {
        identifier = charon
        daemon {
            default = 1
            ike     = 2
            net     = 1
            cfg     = 1
        }
        auth {
            default = 2
        }
    }

    plugins {
        include strongswan.d/charon/*.conf
    }
}

# swanctl is a separate process with its own plugin init.
# Without load_modular = yes here it ignores all conf.d/charon/*.conf
# files (including agent.conf load = no) and loads every available plugin.
swanctl {
    load_modular = yes

    plugins {
        include strongswan.d/charon/*.conf
    }
}

include strongswan.d/*.conf
```

---

## 5. PSK Secret -- `/etc/swanctl/conf.d/00-secrets.conf`

```
# /etc/swanctl/conf.d/00-secrets.conf
#
# Replace CLIENT_PUBLIC_IP with your public IP (the one the server sees,
# see section 1).  Replace YOUR_PSK with the value stored in the RDS
# shared_secrets table for this client.

secrets {
    ike-fleetipsec {
        secret = "YOUR_PSK"
        # The id here must match what the connection uses as local.id.
        # swanctl matches this secret to the connection that way.
        id-0 = CLIENT_PUBLIC_IP
    }
}
```

Permissions (PSK must not be world-readable):

```bash
sudo chmod 600 /etc/swanctl/conf.d/00-secrets.conf
sudo chown root:root /etc/swanctl/conf.d/00-secrets.conf
```

---

## 6. Scenario S1 -- IKEv1 + Raw ESP

File: `/etc/swanctl/conf.d/s1-ikev1-raw.conf`

```
# Scenario S1: IKEv1, raw ESP (proto 50), no NAT-T.
# Requires a direct public IPv4 address on the client.
# The server accepts any IKE version; IKEv1 is matched by the
# 'fleetipsec-ikev1' peer_config (priority 1, lower than IKEv2).

connections {
    s1-ikev1-raw {
        # IKEv1 explicit.
        version = 1

        # Replace CLIENT_PUBLIC_IP with your public IP.
        local_addrs  = %any
        remote_addrs = 3.11.124.22

        local {
            auth = psk
            # Send own IP as IKE identity (ID_IPV4_ADDR).
            # Server ignores this (rightid=%any) but it must match
            # the secrets block so the PSK is selected client-side.
            id = CLIENT_PUBLIC_IP
        }
        remote {
            auth = psk
            # Accept any identity from the server.
            id = %any
        }

        # IKEv1 phase-1 (ISAKMP SA) proposals.
        # aes256-sha256-modp2048 is the strongest that all StrongSwan
        # 5.x servers accept without extra config.
        proposals = aes256-sha256-modp2048, aes256-sha1-modp2048, aes128-sha256-modp2048

        # Dead peer detection: probe every 30 s, clear SA if unresponsive.
        dpd_delay   = 30s
        dpd_timeout = 90s

        children {
            s1-ikev1-raw {
                # Tunnel all traffic through the VPN.
                # Adjust to a specific subnet if needed.
                local_ts  = 0.0.0.0/0
                remote_ts = 0.0.0.0/0

                mode = tunnel

                # ESP (phase-2) proposals.
                esp_proposals = aes256gcm16, aes256-sha256, aes128gcm16, aes128-sha256

                # Lifetime matching the server child_config defaults.
                life_time   = 3600s
                rekey_time  = 3000s

                dpd_action    = restart
                start_action  = none
                close_action  = none
            }
        }
    }
}
```

---

## 7. Scenario S2 -- IKEv1 + NAT-T (Forced UDP 4500)

File: `/etc/swanctl/conf.d/s2-ikev1-natt.conf`

```
# Scenario S2: IKEv1, NAT-T forced (UDP 4500 encapsulation).
# Works behind home ISP NAT / CGNAT.

connections {
    s2-ikev1-natt {
        version      = 1
        local_addrs  = %any
        remote_addrs = 3.11.124.22

        local {
            auth = psk
            id   = CLIENT_PUBLIC_IP
        }
        remote {
            auth = psk
            id   = %any
        }

        proposals = aes256-sha256-modp2048, aes256-sha1-modp2048, aes128-sha256-modp2048

        # Force UDP 4500 encapsulation regardless of NAT detection.
        encap = yes

        dpd_delay   = 30s
        dpd_timeout = 90s

        children {
            s2-ikev1-natt {
                local_ts  = 0.0.0.0/0
                remote_ts = 0.0.0.0/0
                mode      = tunnel

                esp_proposals = aes256gcm16, aes256-sha256, aes128gcm16, aes128-sha256

                life_time  = 3600s
                rekey_time = 3000s

                dpd_action   = restart
                start_action = none
                close_action = none
            }
        }
    }
}
```

---

## 8. Scenario S3 -- IKEv2 + Raw ESP

File: `/etc/swanctl/conf.d/s3-ikev2-raw.conf`

```
# Scenario S3: IKEv2, raw ESP (proto 50), no NAT-T.
# Requires a direct public IPv4 address on the client.
# The server prefers IKEv2 (higher priority peer_config in SQL).

connections {
    s3-ikev2-raw {
        version      = 2
        local_addrs  = %any
        remote_addrs = 3.11.124.22

        local {
            auth = psk
            id   = CLIENT_PUBLIC_IP
        }
        remote {
            auth = psk
            id   = %any
        }

        # IKEv2 IKE SA proposals -- prefer AEAD + strong DH.
        proposals = aes256gcm16-prfsha256-x25519, aes256gcm16-prfsha256-modp2048, aes256-sha256-modp2048, aes128gcm16-prfsha256-x25519

        encap = no

        dpd_delay   = 30s
        dpd_timeout = 90s

        children {
            s3-ikev2-raw {
                local_ts  = 0.0.0.0/0
                remote_ts = 0.0.0.0/0
                mode      = tunnel

                esp_proposals = aes256gcm16, aes256-sha256, aes128gcm16

                life_time  = 3600s
                rekey_time = 3000s

                dpd_action   = restart
                start_action = none
                close_action = none
            }
        }
    }
}
```

---

## 9. Scenario S4 -- IKEv2 + NAT-T (Forced UDP 4500)

File: `/etc/swanctl/conf.d/s4-ikev2-natt.conf`

```
# Scenario S4: IKEv2, NAT-T forced (UDP 4500 encapsulation).
# The most capable mode and most likely to work behind any ISP.
# StrongSwan will also switch to this automatically when it detects NAT
# even if encap = no is set, but forcing it avoids detection delay.

connections {
    s4-ikev2-natt {
        version      = 2
        local_addrs  = %any
        remote_addrs = 3.11.124.22

        local {
            auth = psk
            id   = CLIENT_PUBLIC_IP
        }
        remote {
            auth = psk
            id   = %any
        }

        proposals = aes256gcm16-prfsha256-x25519, aes256gcm16-prfsha256-modp2048, aes256-sha256-modp2048, aes128gcm16-prfsha256-x25519

        encap = yes

        dpd_delay   = 30s
        dpd_timeout = 90s

        children {
            s4-ikev2-natt {
                local_ts  = 0.0.0.0/0
                remote_ts = 0.0.0.0/0
                mode      = tunnel

                esp_proposals = aes256gcm16, aes256-sha256, aes128gcm16

                life_time  = 3600s
                rekey_time = 3000s

                dpd_action   = restart
                start_action = none
                close_action = none
            }
        }
    }
}
```

---

## 10. Switching Between Scenarios

Load (or reload) all config into the running daemon after any file change:

```bash
sudo swanctl --load-all
```

This is non-disruptive to existing SAs. Then initiate and terminate
individual scenarios explicitly:

```bash
# Check what is loaded
sudo swanctl --list-conns

# Initiate a scenario (by child SA name)
sudo swanctl --initiate --child s4-ikev2-natt

# List active SAs
sudo swanctl --list-sas

# Terminate a scenario (by connection name)
sudo swanctl --terminate --ike s4-ikev2-natt

# Terminate all SAs
sudo swanctl --terminate --ike %any
```

Switch sequence:
```bash
# Tear down current scenario
sudo swanctl --terminate --ike s4-ikev2-natt

# Start a different one
sudo swanctl --initiate --child s3-ikev2-raw
```

---

## 11. Adding the Test Client PSK to the Server Database

Run from a bastion host with access to the RDS instance. Increment 3 must
be complete (StrongSwan + RDS integration deployed on the VPN concentrator
AMI) before this has any effect on tunnel establishment.

Replace `192.0.2.1` with the client's actual public IP (the source IP the
server will see) and `YOUR_PSK_VALUE` with the shared secret.

```sql
-- Encode client public IP as 4-byte big-endian BYTEA.
-- Example for IP a.b.c.d:
--   (a<<24 | b<<16 | c<<8 | d) in hex, zero-padded to 8 chars.
-- For 1.2.3.4: (1<<24)|(2<<16)|(3<<8)|4 = 0x01020304

BEGIN;

-- 1. Insert the client identity (source IP).
INSERT INTO identities (type, data)
    VALUES (
        1,
        decode(
            lpad(to_hex(
                (split_part('192.0.2.1','.',1)::bigint << 24) |
                (split_part('192.0.2.1','.',2)::bigint << 16) |
                (split_part('192.0.2.1','.',3)::bigint <<  8) |
                 split_part('192.0.2.1','.',4)::bigint
            ), 8, '0'),
            'hex'
        )
    )
    ON CONFLICT DO NOTHING
    RETURNING id;
-- Note the returned id (call it IDENTITY_ID).

-- 2. Insert the PSK.
INSERT INTO shared_secrets (type, data)
    VALUES (1, 'YOUR_PSK_VALUE'::BYTEA)
    RETURNING id;
-- Note the returned id (call it SECRET_ID).

-- 3. Link the PSK to the identity.
-- Replace IDENTITY_ID and SECRET_ID with the values returned above.
INSERT INTO shared_secret_identity (shared_secret, identity)
    VALUES (SECRET_ID, IDENTITY_ID)
    ON CONFLICT DO NOTHING;

COMMIT;
```

No charon restart needed -- the SQL plugin re-queries for credentials on
each IKE negotiation.

To verify:

```sql
SELECT
    i.id,
    i.type,
    encode(i.data, 'hex') AS ip_hex,
    encode(ss.data, 'escape') AS psk_preview
FROM identities i
JOIN shared_secret_identity ssi ON ssi.identity = i.id
JOIN shared_secrets ss          ON ss.id = ssi.shared_secret
WHERE i.type = 1
ORDER BY i.id;
```

---

## 12. Useful Diagnostic Commands

### Client-side

```bash
# Live log of charon IKE negotiation
sudo journalctl -fu strongswan.service

# Full SA detail including cipher suites negotiated
sudo swanctl --list-sas --raw

# Show loaded secrets (masked)
sudo swanctl --list-creds

# Show active policies in the kernel (xfrm)
sudo ip xfrm policy list
sudo ip xfrm state list

# Count ESP packets (encap = no / raw ESP)
sudo ip -s xfrm state list

# Count NAT-T packets (encap = yes, look for UDP-ESP)
sudo ss -nup | grep :4500
```

### Verifying raw ESP vs. NAT-T in a packet capture

On the client (or a mirror port):

```bash
# Raw ESP: look for proto 50 packets toward 3.11.124.22
sudo tcpdump -n -i eth0 'host 3.11.124.22 and ip proto 50'

# NAT-T: look for UDP port 4500
sudo tcpdump -n -i eth0 'host 3.11.124.22 and udp port 4500'

# IKE negotiation phase only
sudo tcpdump -n -i eth0 'host 3.11.124.22 and (udp port 500 or udp port 4500)'
```

### Firewall check on the client

The local nftables or iptables must allow outbound UDP 500, UDP 4500, and
optionally proto 50. On a fresh Debian 13 system the default policy is
ACCEPT outbound, so this is usually fine. Verify:

```bash
sudo nft list ruleset
# or: sudo iptables -L -n -v
```

### Server-side (on VPN concentrator via bastion)

```bash
# Check active IKE SAs from the server perspective
sudo swanctl --list-sas

# Server charon log
sudo journalctl -fu strongswan.service

# See what the kernel xfrm policy looks like for the client
sudo ip xfrm policy list src 0.0.0.0/0 dst CLIENT_PUBLIC_IP
```

---

## 13. Scenarios Cheat Sheet

```
IKE version    NAT-T        encap   Ports used         Connection name
-----------    -----        -----   ----------         ---------------
IKEv1          no (raw ESP) no      UDP 500 + proto 50 s1-ikev1-raw
IKEv1          forced       yes     UDP 500 -> 4500    s2-ikev1-natt
IKEv2          no (raw ESP) no      UDP 500 + proto 50 s3-ikev2-raw
IKEv2          forced       yes     UDP 500 -> 4500    s4-ikev2-natt

LVS accepts all three: UDP 500, UDP 4500, proto 50 (nftables INPUT rules).
LVS DNAT: jhash(src_ip) % N  ->  same VPN concentrator for all modes from
the same client IP.  If only one VPN node is running (dev ASG desired=1)
all traffic goes to that node regardless.
```
