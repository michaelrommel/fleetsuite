# fleetproxy

FleetShell **dual-homed Squid proxy** AMI. An EC2 Auto Scaling fleet that
terminates device HTTP/HTTPS egress at the tunnel exit (fixed port **8080**) and
authorizes destinations via the [`squid-infoproxy`](../../squid-infoproxy/)
`external_acl` helper against the Info Proxy allow-lists in Valkey.

```
device --tunnel--> ipsecnode (device global IP, no SNAT) --8080 ECMP split-->
    eth0 (Squid :8080) --squid-infoproxy--> Valkey  (allow / deny)
        allowed internet URL --tcp_outgoing_address eth1--> NAT gateway --> internet
        allowed intranet URL --cache_peer--> downstream intranet proxy
```

## Why dual-homed (the whole point)

Device replies must return via the **concentrator** (the backend subnet's
default route -> Return GW), but Squid's **own** outbound requests must NOT
follow that default into the tunnel - they must egress via the **NAT gateway**.
Both destinations are arbitrary non-backend IPs (customer address space is not a
fixed CIDR), so they cannot be separated by destination. They are separated by
**source**, via a second network interface + policy routing:

| ENI | subnet default route | role |
|---|---|---|
| `eth0` | -> IPSec concentrator | Squid listener `:8080`; device replies return here |
| `eth1` | -> NAT gateway | Squid `tcp_outgoing_address`; originated requests egress here |

AWS cannot reliably launch an instance with two ENIs in different subnets, so
`eth1` is **created + attached at boot** by the `proxy-net` OpenRC service
(`aeroplug` + aws-cli), exactly like the ReturnGW pattern. `proxy-net` then adds
`ip rule from <eth1-ip> table 200` (default -> NAT) so every connection Squid
originates (bound to eth1) egresses through the NAT instead of the concentrator.

No NLB: preserving the arbitrary device IP while returning via the concentrator
is incompatible with an NLB's return path, so **load-balancing is ipsecnode VPP
ECMP** across the ASG's `eth0` IPs (see `infrastructure/make_proxy_service.sh`
STEP 9).

## Intranet vs internet (per-device, from the Info Proxy data)

The intranet/internet split is already master data: every destination rule
collection is tagged `proxy_type` (`intranet`|`internet`) in the portal, and the
spooler writes two per-device allow-lists to Valkey
(`infoproxy:intranet:<ip>` and `infoproxy:internet:<ip>`). So classification is
NOT re-derived here from a static domain file - the `squid-infoproxy` helper
(run with `--proxy-type both`) authorizes against both namespaces in one lookup
and returns a Squid `tag=` (`intranet` wins on overlap). squid.conf matches the
tag (`acl is_intranet tag intranet`) to drive `never_direct` / `always_direct` /
`cache_peer_access`: intranet-tagged requests go to the single downstream
`cache_peer` (the dumb intranet proxy); everything else is fetched directly via
eth1 -> NAT. One AMI, one service, one source of truth.

## Files

| File | Installed to | Purpose |
|---|---|---|
| `fleetproxy.pkr.hcl` | - | Packer build (Alpine + squid + aws-cli + helper + aeroplug) |
| `_etc_squid_squid.conf` | `/etc/squid/squid.conf` | proxy config (`@INTRANET_PROXY@`/`@VALKEY_URL@` substituted at boot) |
| `_etc_nftables_fleetproxy.nft` | `/etc/nftables.nft` | INPUT filter: SSH/ICMP/9100 from the VPC, 8080 on eth0; replaces the base image default-drop |
| `_etc_init.d_proxy-net` | `/etc/init.d/proxy-net` | create+attach eth1, policy routing, materialise squid conf |
| `_etc_conf.d_proxy-net` | `/etc/conf.d/proxy-net` | subnet/SG tags, egress table, intranet peer, Valkey URL |
| `_etc_conf.d_squid` | `/etc/conf.d/squid` | `rc_need=proxy-net` ordering |

## Build

```bash
# from the fleetsuite workspace root:
cargo build --release --target x86_64-unknown-linux-musl -p squid-infoproxy
cd vendor/aerosuite && cargo build --release --target x86_64-unknown-linux-musl -p aeroplug && cd ../..
cd aerobake/fleetproxy
packer build -var-file=../../infrastructure/fleetproxy.pkrvars.hcl fleetproxy.pkr.hcl
```

## Deploy

`infrastructure/make_proxy_service.sh` - progressive AWS CLI scaffold: the
missing `ec2` VPC endpoint (STEP 0), proxy-out subnets + NAT route table, the
eth0/eth1 security groups, the IAM instance profile (ENI lifecycle), the launch
template + ASG, network-based scaling, the ENI-leak backstop, and the ipsecnode
ECMP registration.

## Next steps (resume here)

Status: SCAFFOLDED only - nothing built or deployed yet. Order of work:

1. **Fill in the environment-specific placeholders** before building:
   - `_etc_conf.d_proxy-net`: `INTRANET_PROXY_IP` / `INTRANET_PROXY_PORT` (the
     real downstream intranet proxy) and confirm `VALKEY_URL`.
   - `make_proxy_service.sh`: `PROXY_OUT_CIDR_A/B` are 172.16.59/60.0/24
     (172.16.57/58.0/24 are the FleetShell-db Aurora PrivateLink subnets).
   (Intranet vs internet is no longer a static file - it comes per-device from
   the Info Proxy allow-lists via `squid-infoproxy --proxy-type both`.)
2. **Build the AMI** (see Build above): musl `squid-infoproxy` + `aeroplug`,
   then `packer build`. Capture the resulting AMI id.
3. **Run `make_proxy_service.sh` STEP by STEP**, pasting each result back and
   filling the variables:
   - STEP 0: the `com.amazonaws.eu-west-2.ec2` interface endpoint (HARD
     prerequisite - `proxy-net` needs it over eth0 before NAT exists).
   - STEP 1-2: proxy-out subnets + NAT rtb; the two SGs (Name tags matter -
     `proxy-net` discovers `fleetshell-proxy-egress` by Name).
   - STEP 3-4: Valkey 6379 rule; IAM role + instance-profile. Trust =
     `_trust.json`; permissions are composed from AWS-managed policies
     (`AmazonEC2FullAccess` + `AmazonSSMManagedInstanceCore`) because we lack
     inline/managed-policy creation rights. `_policy.json` holds the scoped
     permission set, retained to re-scope later.
   - STEP 5-7: launch template (paste the AMI id), ASG, network scaling.
4. **Validate one instance manually** before scaling:
   - `proxy-net` created + attached eth1; `ip rule` shows `from <eth1-ip>
     lookup 200`; `ip route show table 200` defaults via the proxy-out gw.
   - `/etc/squid/conf.d/egress.conf` has `tcp_outgoing_address <eth1-ip>`;
     squid.conf placeholders (`@INTRANET_PROXY@` / `@VALKEY_URL@`) substituted.
   - From the box: a direct-internet URL egresses via NAT (source = eth1);
     an intranet URL routes to the `cache_peer`; the helper denies a URL with
     no matching Valkey allow-list entry for the source IP.
5. **STEP 8 - ENI-leak backstop**: terminating lifecycle hook + a sweeper for
   `available` ENIs tagged `Name=fleetproxy-egress` whose `fleetproxy-instance`
   tag is no longer a running instance.
6. **STEP 9 - ipsecnode ECMP** (fleetsuite side): replace the single test
   backend (172.16.53.6) 8080 split with an ECMP set over the ASG's eth0 IPs.
   This is what actually delivers device traffic to the fleet.
7. **Tighten** the IAM permissions (swap `AmazonEC2FullAccess` for a
   customer-managed policy built from `make_proxy_service_policy.json`, scoped by
   tag/subnet) and the eth1 egress SG
   (80/443 + intranet proxy IP only) once the happy path works.

Gotchas to remember:
- `ec2messages` != `ec2` - the control-plane endpoint (STEP 0) is separate.
- No NLB by design; do not reintroduce one (breaks the concentrator return path).
- The device source IP the helper keys on must equal `device.ip_address` in the
  portal Info Proxy spool (the Valkey key `infoproxy:<type>:<src_ip>`).
