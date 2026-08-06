# FleetSuite -- Agent Bootstrap Document

This file summarises the architecture, decisions, and outstanding tasks for the
`fleetsuite` project. Read it in full before making any changes. It is the
authoritative reference for a new agent session picking up this work.

---

## Next Session Starting Point  <<<  READ THIS FIRST

**Last completed session (2026-08-06):** T4 PASSED -- full VPP NAT + return path via Return GW confirmed.
Helena1 (62.238.96.148) established IKEv2+NAT-T tunnel, dummy0 simulating device
192.168.13.133. VPP SNAT to 198.51.100.133, backend at 172.16.53.6 (Backend-a).
HTTP response received end-to-end. Two bugs fixed during T4:
- fleetnode Packer: `systemctl enable frr` (was disable -- FRR never started on concentrator).
- fleetroute sysctl: `net.ipv4.conf.default.rp_filter=0` added (ipip-gw inherits
  rp_filter=1 from conf/default at creation time; MAX(all=0,ipip-gw=1)=1 silently
  dropped forwarded packets on the Return GW backup).
Both fixes committed. Backend subnet infrastructure complete (Backend-a/b, rtb-backend,
VPC endpoints). Routing model confirmed: 0.0.0.0/0 via Return GW master in rtb-backend;
AWS services via VPC endpoints; global IP traffic via BGP automatically.

### What the next session should do

**T4 is COMPLETE. AMI source fixes committed. Rebuild both AMIs when instance
cycle is next needed (see Rebuild Sequence below).**

**Current priority: Increment 6e -- per-customer VRF isolation in vpp.rs.**
This is a correctness blocker: the current global VPP NAT table silently breaks
when two customers share the same device internal_ip (e.g. 192.168.1.10).
The fix uses XFRM interfaces (one per site, created at VICI load-conn time)
and per-site VPP fib tables (created on CHILD_SA UP). See Architecture
Decision #15 for the full design.

Files to change (in order):
1. `ipsecnode/src/vici.rs`  -- add `if_id_in`, `if_id_out`, `mark_out` to
   `ChildConnConfig` and `load_conn()` signature.
2. `ipsecnode/src/vpp.rs`   -- major refactor: per-site VRFs, VrfAllocator,
   nftables mangle map for return-path marking.
3. `ipsecnode/src/credentials.rs` -- create/delete XFRM interface around
   VICI load-conn/unload-conn.
4. `ipsecnode/src/main.rs`  -- update `VppTaps` -> `VppState` type.

After 6e: implement backend DNAT (Increment 6g) using nftables PREROUTING
map (see Architecture Decision #16 -- Step 1 manually tested and confirmed).

**Open topic (not blocking 6e/6g):** Initiating tunnels from the AWS side
toward customer CPEs. Architecture Decision #17 documents the design approach
(`start_action = trap` + `inactivity` timeout). Implement after routing design
for backend-to-device traffic is resolved.

**After ipsecnode increments:** ipsecscale (Build Order step 8) -- see the
ipsecscale section for concrete sizing and scale-out criteria.

----------------------------------------------------------------------
REBUILD SEQUENCE  <<<  DO THIS FIRST
----------------------------------------------------------------------

1. Re-enable services in Packer (5 lines to uncomment in fleetroute.pkr.hcl):
   - nftables, dnsmasq, frr, node-exporter, keepalived

2. Rebuild musl binaries (aeroplug changed -- --takeover now writes --write-ip-file):
   ```bash
   cd vendor/aerosuite
   cargo build --release --target x86_64-unknown-linux-musl -p aeroplug
   cd ../..
   cargo build --release --target x86_64-unknown-linux-musl -p fleetpulse
   ```

3. Build the production fleetroute AMI:
   ```bash
   cd aerobake/fleetroute && packer build fleetroute.pkr.hcl
   ```

4. Update LT and recycle Return GW instances:
   ```bash
   FLEETROUTE_AMI=ami-XXXX bash infrastructure/update_lt_returngw_ami.sh
   CONFIRM=yes bash infrastructure/cycle_returngw_instances.sh
   ```

5. Check ASG tags include the IPIP parameters (ipsec-gw-peer-bgp-ip, ipsec-gw-remote-vpn).
   These were added to make_asg_returngw.sh but the RUNNING ASGs may need manual update.

6. Rebuild fleetnode AMI (FRR fixes committed: redistribute kernel,
   disable-connected-check, peer-group-before-listen-range, FRR ENABLED):
   ```bash
   cd aerobake/fleetnode && packer build fleetnode.pkr.hcl
   ```
   Update fleetipsec-lt-vpn and cycle the VPN concentrator instance.

7. Run T4: full VPP NAT + confirmed return path via Return GW.
   From koi: swanctl --initiate --child fleetipsec-ikev2
   Test backend must be in Backend-a (`subnet-01a513292ea15ae83`) or Backend-b
   (`subnet-08213d03f2940855c`) with `sg-backend` attached. The `fleetpulse
   notify-master` call on Return GW VRRP election sets `0.0.0.0/0` in
   rtb-backend pointing to the Return GW master ENI -- verify this route is
   present before testing (`aws ec2 describe-route-tables --route-table-ids
   rtb-0a446e715fc3ec757`).
   Seed Valkey with a nat record mapping 198.51.100.133 -> <backend-container-ip>.
   Ping from seagull (192.168.13.133) through tunnel to backend container.

----------------------------------------------------------------------
STATE OF RUNNING INSTANCES (end of 2026-08-05 session)
----------------------------------------------------------------------

Return GW master (i-0a6ed3e8056541c2e, 172.16.51.x, AZ-a):
  Running ami-0ce52bcbd3c5e7d17. All services UP, manually configured.
  eth3=172.16.49.4 (VPN-a), ipip-gw tunnel to backup. VRRP master.
  BGP Established with 172.16.50.119. rp_filter=0 set at runtime only.

Return GW backup (i-058d47f181f4794fa, 172.16.51.55, AZ-b):
  Same AMI, same caveats. eth3=172.16.50.4 (VPN-b), ipip-gw tunnel to master.

VPN concentrator (172.16.50.119, AZ-b):
  FRR enabled. BGP Established with both Return GW nodes.
  Two CHILD_SAs active. /32 routes in Return GW kernel (proto bgp, via ipip-gw).
  FRR fixes applied via vtysh only -- NOT in AMI yet.

----------------------------------------------------------------------
FIXES COMMITTED BUT NOT YET IN ANY DEPLOYED AMI
----------------------------------------------------------------------

fleetroute (need rebuild):
  - rp_filter=0 (was 2) -- critical for IPIP forwarding
  - nftables: ip protocol 4 accept on eth2 (IPIP in INPUT chain)
  - init.d: eth3 attach + IPIP tunnel + dev eth2 + remote VPN route
  - init.d: table 201 route with onlink
  - init.d: eth1 uses --takeover instead of --attach
  - Packer: 5 rc-update lines commented out (DEBUG MODE -- re-enable!)

fleetnode (need rebuild):
  - frr.conf: redistribute kernel (was: redistribute static)
  - frr.conf: disable-connected-check on both Return GW neighbors
  - frr.conf: peer-group declared BEFORE bgp listen range
  - frr.conf: FRR ENABLED in rc-update (was disabled in AMI)

aerosuite/aeroplug (need musl rebuild):
  - attach.rs: --takeover writes --write-ip-file (was silently omitted)

Operational notes learned during 6d testing:
- `swanctl --load-conns` removes VICI-loaded per-site connections. Any swanctl
  file change on the VPN node must be followed by `systemctl restart ipsecnode`.
- VPP can accumulate stale tap interfaces across ipsecnode restarts; the
  cleanup_stale_state() function handles this, but deleting many stale taps at
  once can crash VPP. In production (AMI boot) VPP starts fresh, so this is
  only a development/testing concern.
- VPP's 0.0.0.0/0 default route must be added BEFORE `nat44 plugin enable`;
  adding it after causes the NAT plugin to add a second ECMP path.
- Manual VPP ip routes for internal_ip must NOT be added; VPP NAT manages
  these FIB entries automatically and adding them creates ECMP.

### What changed in the last session (key facts for code work)

- **Return GW deployed and BGP sessions confirmed working** (2026-08-05).
  Many bugs discovered and fixed during manual boot-sequence debugging.
  All fixes are committed to the relevant config files.

  **aeroplug fix (`vendor/aerosuite/aeroplug/src/attach.rs`):**
  - `--takeover` did not write `--write-ip-file`. Fixed: private IP is now
    extracted from the DescribeNetworkInterfaces XML and written, same as `--attach`.
  - Requires aeroplug musl rebuild before next Packer run.

  **`aerobake/fleetroute/` fixes:**
  - `fleetroute.pkr.hcl`: services commented out for debug build (dnsmasq, nftables,
    frr, node-exporter, keepalived). Re-enable all 5 `rc-update add` lines before
    production build. dnsmasq MUST run at boot (resolv.conf points to 127.0.0.1;
    aeroplug/fleetpulse cannot reach EC2 API without DNS).
  - `_etc_init.d_keepalived`:
    - eth1 changed from `--attach` with retry to `--takeover` (handles restart
      where eth1 is already in-use on this instance).
    - Policy routing table 201 added for eth1 source IP (so SSH replies egress
      via eth1, not eth0 -- prevents SourceDestCheck drop on eth0).
    - `ip route add table 202 ... onlink` required for /32 eth2 address (without
      `onlink`, kernel rejects gateway as unreachable from a /32 interface).
  - `_etc_nftables_fleetroute.nft`: BGP rule changed from `iifname "eth0"` to
    `iifname "eth2"` -- BGP sessions arrive on eth2 (the BGP ENI), not eth0.
  - `_etc_frr_frr.conf`:
    - Peer group (`neighbor VPN-NODES peer-group`) must be declared BEFORE
      `bgp listen range` lines. FRR parses config sequentially; referencing an
      undefined peer group silently drops the listen range lines.
    - Added `neighbor VPN-NODES disable-connected-check`. Without this, FRR's
      NHT marks the BGP next-hop as `unresolved(Connected)` because VPN
      concentrators are not in a directly-connected subnet of the Return GW.
      Routes appear in the BGP table but have no `*>` and are not installed
      in the kernel. `ip nht resolve-via-default` alone was NOT sufficient.

  **`aerobake/fleetnode/_etc_frr_frr.conf` fixes:**
  - Added `neighbor 172.16.51.4 disable-connected-check` and same for .36.
    Without this, FRR on the VPN node never sends TCP SYNs to the Return GW
    (BGP state shows `Active` but `Last write never`, zero Opens). FRR silently
    refuses connections to peers not in a directly-connected subnet.
  - Changed `redistribute static` to `redistribute kernel`. ipsecnode installs
    /32 routes via `ip route` which zebra classifies as `K` (kernel) routes,
    not `S` (static). `redistribute static` was silently not redistributing them.

- **Build Order step 7 scaffolding complete** (2026-08-05).
  - New `fleetpulse` Cargo workspace member (`fleetpulse/`) -- boot-time config
    generator for Return GW nodes. Subcommands: `(boot)`, `notify-master`,
    `notify-backup`. Same patterns as ipsecpulse but simpler (no EIP, no ASG
    polling, no nftables). Disables src/dest check on eth0 during boot run.
    Upserts `0.0.0.0/0 -> eth0_eni_id` in the backend route table on MASTER.
  - `aerobake/fleetroute/` -- complete Alpine AMI files:
    - FRR BGP config (AS 65002, `bgp listen range` for 172.16.49/50.x).
    - keepalived VRRP (unicast on eth1, VRID 52, route-table failover, no VIP).
    - init.d boot sequence: aeroplug attach eth1, fleetpulse boot, prime VRRP CT.
    - nftables filter: allows BGP (TCP 179) from VPN subnets, VRRP/SSH on eth1.
    - Packer build file: Alpine 3.23.3, packages frr+frr-openrc+keepalived.
  - Infrastructure scripts:
    - `make_enis_returngw.sh` -- creates eth1 ENIs (172.16.51.68 master, 172.16.51.100 backup).
    - `make_rtb_backend.sh` -- creates `FleetShell-IPSec-rtb-backend` (no default route until notify-master fires).
    - `make_lt_returngw.sh` -- two LTs with fixed primary IPs (172.16.51.4 / 172.16.51.36).
    - `make_asg_returngw.sh` -- two ASGs (min=max=1) for master/backup nodes.
  - Uses `ecsInstanceRole` IAM profile (same as LVS dev) -- no new IAM setup needed.

- **T2 passed** (2026-08-04). Full xfrm data path: seagull (192.168.13.133)
  -> koi (IPsec gateway, NAT-T encapsulation) -> office NAT -> LVS DNAT ->
  VPN node (decapsulation) -> dummy0 (194.138.39.18). 0% packet loss, ~27ms RTT.

- **bypass-office removed** from `aerobake/fleetnode/_etc_swanctl_conf.d_fleetipsec.conf`.
  Management SSH to VPN nodes always arrives via the bastion (172.16.x.x),
  never from the office LAN directly. bypass-vpc (172.16.0.0/16) is sufficient.
  The running instance still has the old bypass-office xfrm shunt policies in
  kernel state; they are removed on the next AMI rebuild + instance cycle.

- **Customer gateway must have `send_redirects=0`** on its LAN interface.
  When a gateway (koi) forwards customer device traffic into the xfrm tunnel,
  Linux sends ICMP redirects to the device unless `send_redirects` is disabled
  on the LAN interface. In the test: `sysctl -w net.ipv4.conf.all.send_redirects=0`
  and per-interface. In production this must be set on every customer CPE.
  Note: `net.ipv4.conf.all.send_redirects=0` alone is NOT sufficient -- Linux
  uses OR(all, interface) semantics, so the interface-specific value must also
  be set to 0.

- **AMI rebuild needed** before next T3/production testing:
  - bypass-office removed from fleetipsec.conf
  - VPP startup.conf (Build Order step 5)
  Run `aerobake/fleetnode/build.sh` (or equivalent Packer command), then
  `update_lt_vpn_ami.sh` and `cycle_vpn_instance.sh`.

- **Valkey schema redesigned** (Architecture Decision #12):
  - `fleetipsec:psk:<site_ip>` -- PSK (unchanged)
  - `fleetipsec:site:<site_ip>` -- tunnel / IKE config (was `:device:`)
  - `fleetipsec:nat:<site_ip>` -- per-device NAT mappings (was `:natmap:`)
  - `mapped_global_ip` removed from site record (kept as `Option` for compat)
  - `local_ts` added to site record (customer's view of our backend addresses)
  - Each crypto field now accepts a single value OR a JSON array (OneOrMany)
  - No catch-all swanctl connections -- every site must be in Valkey

- **ipsecnode source** (`ipsecnode/src/`):
  - `SiteRecord` (was `DeviceRecord`), `SITE_PREFIX` (was `DEVICE_PREFIX`)
  - `proposals.rs` -- `OneOrMany<T>` type, cartesian-product proposal builder
  - `vici.rs` -- `ViciRawValue` custom Deserializer (handles serde_vici bytes),
    `conn_id()` returns `"site-<ip>"`, `load_conn()` takes `Vec<String>` proposals
  - `credentials.rs` -- always loads per-site VICI connection (no needs_custom_conn)
  - `aws.rs` -- IMDS path bug fixed (`"mac"` not `"meta-data/mac"`)
  - `main.rs` -- 5-second timeout on src/dest check disable (was 30 s default)
  - `_etc_systemd_system_ipsecnode.service` -- `RUST_LOG=ipsecnode=debug`

- **swanctl.conf** -- catch-all `fleetipsec-ikev1` and `fleetipsec-ikev2`
  connections REMOVED. Only `bypass-vpc` and `bypass-office` remain static.

- **Current AMI** -- built 2026-08-04, contains all of the above.
  LT default version: check with `describe-launch-template-versions`.

- **Pending small fix** -- `conn_id()` rename from `device-` to `site-` is
  in the code but the running instance still shows the old name in logs.
  Will be correct on the next instance cycle.

### Valkey seed for testing (koi, 185.17.205.224)
```bash
redis-cli -u rediss://clustercfg.dev-valkey-aeroftp.ak121m.memorydb.eu-west-2.amazonaws.com:6379 \
  SET fleetipsec:psk:185.17.205.224 testpsk123
redis-cli -u rediss://clustercfg.dev-valkey-aeroftp.ak121m.memorydb.eu-west-2.amazonaws.com:6379 \
  SET fleetipsec:site:185.17.205.224 \
  '{"customer_id":"koi-test","static_ip":true}'
```

---

## What This Project Is

A scalable IPSec VPN concentrator infrastructure hosted on AWS eu-west-2, built
to terminate **up to 25,000 site-to-site IPSec tunnels** from remote customer
sites. It is a greenfield build that replaces an existing on-premises
concentrator, reusing the existing device-to-unique-IP mapping database.

The sibling project `~/software/aerosuite` is a production FTP load-balancer
built on the same AWS account and VPC. Many patterns, binaries, and AMI
construction techniques are shared. Read its code before writing anything here.
The two projects are **separately maintainable** but intentionally aligned.

---

## Repository Layout

```
fleetsuite/
  AGENTS.md                   <- this file
  Cargo.toml                  <- Rust workspace (ipsecpulse, ipsecscale, ipsecnode)
  .gitmodules                 <- declares vendor/aerosuite submodule
  vendor/
    aerosuite/                <- git submodule -> git@github.com:michaelrommel/aerosuite.git
                                  aerocore and aeroplug are consumed from here via
                                  path dependencies; they are NOT workspace members
                                  (nested workspaces are not supported by Cargo)
  ipsecpulse/                 <- binary: boot-time config generator (LVS nodes) -- IMPLEMENTED
  ipsecscale/                 <- binary: ASG orchestration daemon (LVS nodes)   -- STUB
  ipsecnode/                  <- binary: per-node tunnel lifecycle (VPN nodes)   -- STUB

  aerobake/
    fleetscale/               <- IPSec LB AMI   (Alpine) -- IMPLEMENTED, TESTED
    fleetnode/               <- VPN concentrator AMI (Debian 12 Bookworm) -- IN PROGRESS
    fleetroute/               <- Return-path GW AMI (Alpine) -- TODO
  infrastructure/             <- AWS CLI scripts + their output
```

### Working with the aerosuite submodule

Clone fleetsuite with submodules initialised:
```bash
git clone --recurse-submodules git@github.com:michaelrommel/fleetsuite.git
# or, if already cloned:
git submodule update --init --recursive
```

To pull the latest aerosuite into fleetsuite (e.g. after aerocore/aeroplug changes):
```bash
cd vendor/aerosuite && git pull origin main
cd ../..
git add vendor/aerosuite
git commit -m "chore: bump aerosuite submodule to <short-sha>"
```

**Important Cargo note:** `aerocore/Cargo.toml` uses `workspace = true` for all
its dependencies. When built from outside the aerosuite workspace, Cargo
resolves those keys against the *referencing* workspace root (fleetsuite's
`Cargo.toml`). Therefore fleetsuite's `[workspace.dependencies]` must declare
every dep that aerocore uses -- including `sha2`, `hmac`, `hex`,
`serde_urlencoded` -- at versions matching aerosuite exactly. If aerosuite adds
new workspace deps to aerocore in the future, add the same entry to fleetsuite's
`Cargo.toml` as part of the submodule bump commit.

---

## AWS Account and Existing Infrastructure

```
Account:   295934382486
Region:    eu-west-2  (London)
VPC:       vpc-0595e17ce290fb050   CIDR 172.16.0.0/16
IGW:       igw-0599736bc51a9ac5c
```

### Existing resources relevant to this project

| Resource | ID / ARN | Notes |
|---|---|---|
| MemoryDB (Valkey 7.3) | `arn:aws:memorydb:eu-west-2:295934382486:cluster/dev-valkey-aeroftp` | Shared with aeroftp. TLS on port 6379. Use key prefix `fleetipsec:` |
| MemoryDB endpoint | `clustercfg.dev-valkey-aeroftp.ak121m.memorydb.eu-west-2.amazonaws.com:6379` | |
| MemoryDB subnet group | `nucleus-private-subnets` | subnets 172.16.128.0/20 (AZ-a) + 172.16.16.0/20 (AZ-b) |
| Office SSH access SG | `sg-011b3ebfcfbcca22d` `CLI_RemoteAccess` | Add to every managed node |
| Office network | `192.168.13.0/24` | koi `.151`, local workstation `.185`, test Linux host `.133` |
| SSH access | koi or workstation direct to instance private IP | SSH agent forwarding; no bastion |

### Subnets (all created, all in vpc-0595e17ce290fb050)

| Name | Subnet ID | CIDR | AZ | Type | Route Table |
|---|---|---|---|---|---|
| FleetShell-IPSec-LVS-a | `subnet-0fe6d05bc51c16ed8` | 172.16.48.0/27 | eu-west-2a | PUBLIC | rtb-public |
| FleetShell-IPSec-LVS-b | `subnet-071e009038ce73f87` | 172.16.48.32/27 | eu-west-2b | PUBLIC | rtb-public |
| FleetShell-IPSec-LVS-mgmt-a | `subnet-049c91ca98e7d3637` | 172.16.48.64/28 | eu-west-2a | PRIVATE | rtb-private |
| FleetShell-IPSec-LVS-mgmt-b | `subnet-07da62f2872b072b7` | 172.16.48.80/28 | eu-west-2b | PRIVATE | rtb-private |
| FleetShell-IPSec-ReturnGW-mgmt-a | `subnet-063a83cf5653196c7` | 172.16.51.64/28 | eu-west-2a | PRIVATE | rtb-private |
| FleetShell-IPSec-ReturnGW-mgmt-b | `subnet-0ee35e39252ccf95a` | 172.16.51.96/28 | eu-west-2b | PRIVATE | rtb-private |
| FleetShell-IPSec-VPN-a | `subnet-05a86c0fe6eec7b10` | 172.16.49.0/24 | eu-west-2a | PRIVATE | rtb-vpn |
| FleetShell-IPSec-VPN-b | `subnet-0ab2ba73e9b587e2e` | 172.16.50.0/24 | eu-west-2b | PRIVATE | rtb-vpn |
| FleetShell-IPSec-ReturnGW-a | `subnet-017d5b3a6331e26a7` | 172.16.51.0/27 | eu-west-2a | PRIVATE | rtb-private |
| FleetShell-IPSec-ReturnGW-b | `subnet-082703ab573f0f4e9` | 172.16.51.32/27 | eu-west-2b | PRIVATE | rtb-private |
| FleetShell-IPSec-Management | `subnet-02387719b5b2c3352` | 172.16.52.0/24 | eu-west-2a | PRIVATE | rtb-private |
| FleetShell-IPSec-Backend-a | `subnet-01a513292ea15ae83` | 172.16.53.0/24 | eu-west-2a | PRIVATE | rtb-backend |
| FleetShell-IPSec-Backend-b | `subnet-08213d03f2940855c` | 172.16.54.0/24 | eu-west-2b | PRIVATE | rtb-backend |

All four mgmt subnets (LVS-mgmt-a/b, ReturnGW-mgmt-a/b) are created and
associated with rtb-private.

### EIPs

| Name | Alloc ID | Public IP | Notes |
|---|---|---|---|
| FleetShell-IPSec-VIP | `eipalloc-095ac59bb763cd2ce` | **3.11.124.22** | Customer-facing; moves to VRRP master's secondary IP on failover |
| FleetShell-IPSec-NatGW | `eipalloc-0ac2fb2dd51415b30` | 35.177.240.42 | NAT Gateway |
| FleetShell-IPSec-mgmt-master | see ASG tag `ipsec-mgmt-eip` on `fleetipsec-lvs-master` | - | Permanent management EIP for master node primary IP |
| FleetShell-IPSec-mgmt-backup | see ASG tag `ipsec-mgmt-eip` on `fleetipsec-lvs-backup` | - | Permanent management EIP for backup node primary IP |

Management EIP allocation IDs are stored as the `ipsec-mgmt-eip` ASG tag
(PropagateAtLaunch=true). Discover them with:
```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names fleetipsec-lvs-master fleetipsec-lvs-backup \
  --query 'AutoScalingGroups[*].{ASG:AutoScalingGroupName,MgmtEIP:Tags[?Key==`ipsec-mgmt-eip`]|[0].Value}' \
  --region eu-west-2
```

### Route Tables

| Name | ID | Default route | Associations |
|---|---|---|---|
| FleetShell-IPSec-rtb-public | `rtb-0ca8eab40e09c76ae` | `0.0.0.0/0 -> igw-0599736bc51a9ac5c` | LVS-a, LVS-b |
| FleetShell-IPSec-rtb-vpn | `rtb-01c3275faa537fcc1` | set by ipsecpulse notify-master | VPN-a, VPN-b |
| FleetShell-IPSec-rtb-private | `rtb-0540e3736995912c5` | `0.0.0.0/0 -> nat-0fb75bf0679751582` | ReturnGW-a/b, Management, LVS-mgmt-a/b, ReturnGW-mgmt-a/b |
| FleetShell-IPSec-rtb-backend | `rtb-0a446e715fc3ec757` | `0.0.0.0/0 -> Return GW master eth0 ENI` (set by `fleetpulse notify-master`) | Backend-a, Backend-b |

### Security Groups

| Name | ID | Purpose |
|---|---|---|
| FleetShell-IPSec-sg-lvs | `sg-0406887cfe67d8f15` | ESP/IKE from internet; VRRP within self |
| FleetShell-IPSec-sg-vpn | `sg-04dcc0342150eb53b` | IPSec from LVS; BGP from ReturnGW |
| FleetShell-IPSec-sg-returngw | `sg-0516f1d2561c7754d` | BGP from VPN; all from VPC |
| FleetShell-IPSec-sg-management | `sg-053524ea7dcdb64f1` | PostgreSQL from VPN; SSH from CLI_RemoteAccess |
| FleetShell-IPSec-sg-backend | see `make_sg_backend.sh` | Inbound ICMP + TCP 80 + TCP 8080 from `198.51.100.0/24`; SSH from CLI_RemoteAccess. Attach to all backend server instances/tasks. |
| FleetShell-IPSec-sg-endpoints | `sg-0438c989d6fe0f276` | TCP 443 inbound from `172.16.53.0/24` + `172.16.54.0/24`. Attached to VPC interface endpoint ENIs only. |

### Other resources

| Resource | ID | Notes |
|---|---|---|
| NAT Gateway | `nat-0fb75bf0679751582` | In LVS-a subnet |
| RDS PostgreSQL | `fleetshell-ipsec-strongswan` | Engine: PostgreSQL 18.4; Multi-AZ; db.t4g.medium |
| RDS subnet group | `fleetshell-ipsec-rds` | Management (AZ-a) + ReturnGW-b (AZ-b) |

---

## Architecture -- Full Stack

```
                       Floating EIP  3.11.124.22  (one IP, all customers)
                             |        targets the VRRP master's secondary IP
                    +--------v--------+
                    |   LVS pair      |  Alpine Linux
                    |   keepalived    |  c6in.xlarge x 2  (dev: xlarge; prod: 4xlarge)
                    |   nftables      |  active/standby
                    |   ipsecpulse    |  AZ-a primary, AZ-b standby
                    |   ipsecscale    |  runs on master only
                    +--------+--------+
                             |  DNAT: jhash(src_ip) % N
                             |  handles: UDP 500, UDP 4500, proto 50 (raw ESP)
                    +--------v----------------------------+
                    |  VPN Concentrators (ASG)            |  Debian 12
                    |  StrongSwan  IKEv1 + IKEv2          |  c6in.4xlarge
                    |  VPP         data plane             |  3-N instances
                    |  FRR         BGP /32 routes         |  AZ-a + AZ-b
                    |  ipsecnode   per-node daemon        |
                    +--------+----------------------------+
                             |  BGP (up to 600k /32 host routes)
                    +--------v--------+
                    |  Return GW pair |  Alpine Linux
                    |  FRR BGP        |  c6in.2xlarge x 2
                    |  keepalived VIP |  active/standby
                    +--------+--------+
                             |  default gateway for backend servers
                    +--------v--------+
                    |  Backend servers|  any OS
                    +-----------------+
```

### Supporting infrastructure

| Component | Location | Purpose |
|---|---|---|
| NAT Gateway | LVS-a subnet | Outbound internet for private subnets |
| RDS PostgreSQL | Management + ReturnGW-b (Multi-AZ) | Originally intended for StrongSwan SQL plugin (see Implementation Notes). Now available for device registry / management plane use. ipsecnode does NOT use it at runtime. |
| MemoryDB/Valkey | shared (existing) | PSK store (`fleetipsec:psk:<ip>`), tunnel config (`fleetipsec:site:<ip>`), NAT mappings (`fleetipsec:nat:<ip>`), half-open IKE SA state, ipsecscale coordination |

### BGP ASN and Peer IP Assignments

Fixed for the entire fleet. Baked into every VPN concentrator AMI and every
Return GW AMI from Build Order step 4 onward.

| Role | ASN | Notes |
|---|---|---|
| VPN concentrators | **AS 65001** | All nodes share one ASN; eBGP toward Return GW |
| Return GW pair | **AS 65002** | Both nodes share one ASN |

Return GW **fixed eth0 private IPs** (chosen in Build Order step 4;
baked into fleetroute AMI in step 7):

| Node | Fixed eth0 IP | Subnet | Notes |
|---|---|---|---|
| ReturnGW-master | **172.16.51.4** | ReturnGW-a (172.16.51.0/27) | First usable after AWS-reserved .0-.3 |
| ReturnGW-backup | **172.16.51.36** | ReturnGW-b (172.16.51.32/27) | First usable after AWS-reserved .32-.35 |

VPN concentrators (172.16.49.0/24 and 172.16.50.0/24) peer with both
Return GW nodes simultaneously. Each VPN node has dynamic DHCP IPs;
the Return GW uses `bgp listen range` to accept sessions from both
VPN subnets without pre-configuring individual peer IPs.

Route advertisement flow:
- Each VPN node adds `ip route add <mapped_global_ip>/32 blackhole` via
  ipsecnode (Increment 6c) on CHILD_SA up, and removes it on CHILD_SA down.
- FRR redistributes static routes filtered by prefix-list
  `CUSTOMER-HOST-ROUTES` (permit /32 only) via `EXPORT-CUSTOMER` route-map.
- Return GW advertises nothing back to VPN nodes (REJECT-ALL inbound
  route-map on VPN node BGP neighbors). VPN node forwarding is VPP-only.

---

## Key Architecture Decisions (with reasoning)

### 1. LVS + nftables, not AWS NLB or GWLB

AWS NLB does not support IP protocol 50 (raw ESP). AWS GWLB supports proto 50
but hashes UDP flows (5-tuple) and ESP flows (3-tuple) differently, meaning
IKE and ESP from the same customer can land on different VPN concentrators --
breaking the IPSec SA. A large fraction of the installed customer base cannot
be forced to use NAT-T (UDP 4500 encapsulation), so raw ESP must be handled.

LVS with nftables `jhash ip saddr` hashes on source IP only, giving identical
routing decisions for UDP 500, UDP 4500, and proto 50 from the same customer.

### 2. Two NICs on LVS nodes -- data plane and management/heartbeat separated

Each LVS node has two ENIs:

- **eth0** -- public subnet (LVS-a or LVS-b). Carries all customer ESP/IKE
  traffic. Has two private IPs: a dynamically assigned primary IP and a fixed
  secondary IP (172.16.48.10 for master, 172.16.48.40 for backup). The
  customer-facing EIP targets the secondary IP on the VRRP master. A permanent
  management EIP on the primary IP provides stable outbound internet access.
- **eth1** -- management subnet (LVS-mgmt-a or LVS-mgmt-b, PRIVATE). Carries
  VRRP unicast heartbeat and SSH only. Attached at boot by aeroplug.

Rationale: at 25,000 tunnels with IKE keepalives and DPD traffic, eth0 can
sustain high PPS bursts. VRRP packets (84 bytes each) competing on the same
RX ring risk being dropped during a burst, which would trigger a spurious
failover. A dedicated eth1 gives:
- Independent RX/TX ring buffers and interrupt vectors for each traffic class.
- CPU interrupt affinity can pin eth0 IRQs to data-plane cores and eth1 IRQs
  to a control-plane core, keeping heartbeat latency stable under load.
- SSH remains responsive even when eth0 is under heavy load.

### 3. No VXLAN / no IPVS connection sync on the LVS nodes

The IPSec LB uses **stateless** nftables DNAT: `jhash(src_ip) % N` is a
pure function with no per-connection memory. Any node computes the same
answer, so the new master routes identically to the old one with no sync.
IPSec session state lives on the VPN concentrators, not on the LB.
IPSec DPD tolerates the ~5-10 s EIP re-association window.

### 4. Single NIC on LVS nodes for data plane (no eth2 VXLAN)

aeroftp needs eth2 for VXLAN connection-state sync because IPVS tracks
per-connection state and that state must survive failover. No such requirement
exists here -- see decision #3 above.

### 5. ipsecscale runs always on both LVS nodes; detects role via a file

ipsecscale reads `/run/ipsec-role` -- a plain-text file containing `master` or
`backup` -- written by the keepalived notify scripts on every VRRP state
transition. It is added to the default runlevel; the notify scripts never
start or stop it.

**Role file details:**
- Path: `/run/ipsec-role` (tmpfs -- re-created on every boot)
- Content: `master\n` or `backup\n`
- Ownership: `keepalived_script:nogroup` (gid 65533)
- Written by: `ipsecpulse notify-master` / `ipsecpulse notify-backup`
- Permissions: `0o644`
- Pre-created in keepalived `start_pre` before keepalived itself starts

### 6. ipsecnode is a separate per-node daemon on VPN concentrators

Each VPN concentrator runs `ipsecnode` independently without any leader
election. It handles node-local concerns: StrongSwan tunnel events via VICI
socket, VPP VRF and NAT entry management, FRR /32 route management, ASG
lifecycle hooks, and Prometheus metrics/health endpoints.

### 7. IKEv1 + IKEv2 support with `rightid=%any`

StrongSwan is configured with `rightid=%any` to accept any peer identity.
PSKs are stored in MemoryDB (Valkey) under `fleetipsec:psk:<peer_ip>` and
loaded into charon at startup (and on change) by ipsecnode via the VICI
`load-shared` command (see Architecture Decision #12).

PSK lookup behaviour varies by IKE version and mode:
- **IKEv1 Main Mode**: StrongSwan must derive keys before identities are
  exchanged (messages 5-6 are encrypted). It looks up the PSK by the packet
  source IP. Clients may send any identity; it is accepted post-auth via
  `rightid=%any`. Works correctly regardless of what the client puts in
  its local identity config.
- **IKEv2 + IKEv1 Aggressive Mode**: StrongSwan uses the peer's stated IKE
  identity for lookup. If the client identifies as its public IP (common
  default), the lookup works directly. If the client uses a different identity
  (internal IP, FQDN), the device record must carry an `ike_identity` field
  so ipsecnode can register the PSK under that identity too (see Decision #13).

### 8. Per-tunnel VRF + static 1:1 NAT on VPN concentrators

Every customer tunnel is isolated in its own Linux VRF within VPP. The
existing mapping database (customer device internal IP -> unique globally
routable IP) is loaded as static 1:1 NAT entries in VPP at tunnel-up time.
Return traffic: each unique IP has a `/32` host route advertised via FRR BGP
to the Return GW pair (up to 600,000 entries).

### 9. Debian 12 Bookworm for VPN concentrators, Alpine for everything else

VPP (`fd.io` packagecloud repo) and FRR (`frrouting.org` repo) both have
official Debian Bookworm packages. Alpine does not have VPP in apk and
building from source is impractical.

Ubuntu 24.04 was the original choice but was abandoned: investigation into
the `valkeyauth` C plugin approach (see Decision #12 history) revealed that
`libstrongswan-dev` no longer exists on any current distro (dropped from
Debian after Bullseye, never packaged by Canonical for Noble). This triggered
a full redesign of credential management -- see Decision #12. With the C plugin
approach dropped, Ubuntu offered no advantage over Debian Bookworm, and
Debian is the more stable server base.

### 10. Shared MemoryDB (Valkey) cluster

The existing `dev-valkey-aeroftp` cluster is reused with key prefix
`fleetipsec:`. The VPN concentrator SG has been added to the MemoryDB cluster.
Valkey stores half-open IKE SA state (TTL 30 s) as a safety net for the rare
case where IKE_SA_INIT and IKE_AUTH arrive at different VPN nodes during a
hash boundary event.

### 11. Genuine cross-AZ design -- each HA node owns its AZ end-to-end

Every component is pinned to its own AZ for both eth0 and eth1:

- LVS master: eth0 in LVS-a (AZ-a), eth1 in LVS-mgmt-a (AZ-a)
- LVS backup: eth0 in LVS-b (AZ-b), eth1 in LVS-mgmt-b (AZ-b)
- Return GW master: eth0 in ReturnGW-a (AZ-a), eth1 in ReturnGW-mgmt-a (AZ-a)
- Return GW backup: eth0 in ReturnGW-b (AZ-b), eth1 in ReturnGW-mgmt-b (AZ-b)

VRRP unicast between 172.16.48.68 (AZ-a) and 172.16.48.84 (AZ-b) is plain IP
(proto 112); VPC inter-subnet L3 routing handles it automatically.

**Customer-facing EIP and management EIPs:** the LVS nodes are in PUBLIC
subnets routed via the IGW. Each node needs two public IP associations on eth0:

- **Management EIP** (permanent, on primary IP): provides stable outbound
  internet access for EC2 API calls (aeroplug, ipsecpulse, ipsecscale)
  regardless of VRRP role. Associated to the primary IP early in `start_pre`
  (step 2) via `ipsecpulse associate-mgmt-eip`. Survives all customer EIP
  movements. When an instance is terminated, the ENI is deleted and AWS
  automatically returns the EIP to the unassociated pool; the next instance's
  `start_pre` re-associates it to the new primary IP.

- **Customer-facing EIP** (floating, on secondary IP): `3.11.124.22` targets
  the VRRP master's fixed secondary IP (172.16.48.10 or 172.16.48.40). Moved
  by `ipsecpulse notify-master` on every VRRP master transition.

**Critical AWS behaviour discovered in testing:** associating ANY EIP to an
instance -- even to a secondary private IP -- causes AWS to silently release
the auto-assigned public IP that was on the primary IP. This means
`AssociatePublicIpAddress: true` in the Launch Template cannot be relied upon
for permanent outbound access once the customer EIP has been associated. The
dedicated management EIP on the primary IP is the only reliable solution.

**Fixed secondary IP numbering convention:** same offset (+10) from the base
of each LVS /27 subnet, making it immediately readable in the AWS console:

- Master (172.16.48.0/27): secondary IP = **172.16.48.10**
- Backup (172.16.48.32/27): secondary IP = **172.16.48.40**

If the customer EIP points to .10, the master is active. If it points to .40,
the backup has promoted. If neither, failover is in progress.

**VIP reservation ENIs** prevent AWS DHCP from accidentally assigning .10 or
.40 as primary IPs to new instances. Each is a free-standing ENI that holds
.10 / .40 as a secondary IP permanently. `start_pre` steals the IP onto eth0
atomically with `--allow-reassignment`. `stop_post` returns it atomically to
the reservation ENI -- but only after confirming via IMDS that this instance
still holds the IP (TOCTOU guard prevents stealing it back from a replacement
instance that may have already claimed it).

**Return GW VIP** is not a floating IP -- the route-table approach is used
instead (see open questions).

### 12. ipsecnode owns all StrongSwan credential management via VICI

A custom C plugin (`valkeyauth`) was prototyped but abandoned. `libstrongswan-dev`
does not exist on any current Debian or Ubuntu release (dropped after Debian
Bullseye; never packaged by Canonical for Noble or Jammy). No viable path
existed to compile a C plugin without significant build complexity.

**Decision:** ipsecnode (Rust) is the single process that bridges Valkey and
StrongSwan. It uses the VICI protocol directly over `/var/run/charon.vici`
for both credential management and tunnel lifecycle events -- no C plugin,
no secrets file on disk, no `swanctl` subprocess calls.

**Startup sequence:**
1. ipsecnode connects to `/var/run/charon.vici` and subscribes to
   `child-updown` events.
2. It scans `fleetipsec:psk:*` in Valkey, fetches each device record, and
   issues one VICI `load-shared` command per device, registering the PSK
   under the correct identity set (see Decision #13).
3. It loads CA certificates from a configured path via VICI `load-cert`.
4. It subscribes to Valkey keyspace notifications on `fleetipsec:psk:*`,
   `fleetipsec:site:*`, and `fleetipsec:nat:*`.

**Runtime credential updates (non-disruptive):**
- New device registered in Valkey: pubsub event fires, ipsecnode issues a
  single VICI `load-shared` -- existing tunnels are unaffected.
- Device removed: ipsecnode issues VICI `unload-shared`.
- `swanctl --load-creds` is NOT used; all credential operations go through
  the VICI socket directly.

**Valkey key schema:**
```
fleetipsec:psk:<tunnel_gw_ip>
    PSK string (plain text)

fleetipsec:site:<tunnel_gw_ip>
    JSON -- tunnel configuration and IKE crypto parameters.
    Every device in Valkey gets an explicit per-device VICI load-conn;
    there is no catch-all fallback.
    All fields except customer_id are optional with strong defaults.
    {
        "customer_id":  "acme-corp",
        "ike_identity": "10.5.0.1",     // optional; see Decision #13
        "static_ip":    true,
        "ike_version":  2,

        // Each crypto field accepts a single value OR a JSON array.
        // ipsecnode computes the cartesian product to build the proposal list.
        // Absent = single strong default (aes256-sha256-modp2048 / aes256gcm16).
        "ike_enc":  ["aes256", "aes128"],  // or "aes256"
        "ike_auth": "sha256",
        "ike_dh":   [14, 19],
        "esp_enc":  ["aes256gcm", "aes256"],
        "esp_auth": ["none", "sha256"],
        "esp_pfs":  14,

        // Traffic selectors
        "remote_ts": ["10.67.0.0/16", "141.67.0.0/16"],  // customer device side
        "local_ts":  ["10.67.250.0/24"]  // optional; only for customers that
                                          // assign their own addresses to our
                                          // backend servers.  Absent = 0.0.0.0/0
    }

fleetipsec:nat:<tunnel_gw_ip>
    JSON -- per-device NAT mappings for this tunnel.
    Loaded by ipsecnode on CHILD_SA UP (Increments 6c + 6d).
    {
        "device_nat": [
            {"internal_ip": "10.67.1.5",   "global_ip": "198.51.100.5"},
            {"internal_ip": "10.67.1.6",   "global_ip": "198.51.100.6"}
        ],
        "backend_nat": [
            {"customer_view_ip": "10.67.250.250", "real_ip": "194.138.39.18"},
            {"customer_view_ip": "10.67.250.251", "real_ip": "194.138.39.19"}
        ]
    }
    backend_nat is absent for customers that use real backend addresses directly.
```

NAT data flow (with VPP, Increment 6d):
```
Forward  src=10.67.1.5, dst=10.67.250.250
  SNAT: 10.67.1.5     -> 198.51.100.5  (medical device global identity)
  DNAT: 10.67.250.250 -> 194.138.39.18 (customer backend view -> real IP)
  -> backend sees: src=198.51.100.5, dst=194.138.39.18

Return   src=194.138.39.18, dst=198.51.100.5
  Return GW routes 198.51.100.5/32 to this concentrator (FRR, Increment 6c)
  DNAT: 198.51.100.5  -> 10.67.1.5     (back to medical device)
  SNAT: 194.138.39.18 -> 10.67.250.250 (restore customer backend view)
  -> into tunnel: src=10.67.250.250, dst=10.67.1.5
```

FRR advertises one /32 per `global_ip` entry in `device_nat`, not one per tunnel.

Field values for crypto:
- `ike_enc` / `esp_enc`: `"aes128"`, `"aes192"`, `"aes256"`, `"aes128gcm"`, `"aes192gcm"`, `"aes256gcm"`
- `ike_auth` / `esp_auth`: `"sha256"`, `"sha384"`, `"sha512"`, `"none"`
- `ike_dh` / `esp_pfs`: DH group number `1,2,5,14,15,16,19,20,21,24` (or `0`/absent = no PFS for `esp_pfs`)
- GCM encryption implies `esp_auth="none"` (authentication is built in)

**VICI `load-shared` payload per device:**
```
id:     unique string, e.g. "psk-<site_public_ip>"
type:   "IKE"
data:   <PSK bytes>
owners: [ <site_public_ip> ]               always present
        + [ <ike_identity> ]                 if device record has ike_identity field
```

### 13. IKEv1 Aggressive Mode and certificate clients

**IKEv1 Aggressive Mode PSK:**
In IKEv1 Main Mode the PSK is always looked up by source IP (StrongSwan
cannot know the peer identity before decrypting messages 5-6). In IKEv1
Aggressive Mode and IKEv2 the peer's stated IKE identity is used for lookup.
If a client identifies itself with something other than its public IP (internal
IP, FQDN), the lookup fails unless the PSK is also registered under that
identity.

Solution: an optional `ike_identity` field in `fleetipsec:site:<public_ip>`.
When present, ipsecnode registers the PSK under both the public IP AND the
stated IKE identity (two entries in the VICI `owners` list). The device
registration process must capture the IKE identity for any aggressive-mode
device that does not identify by public IP. Devices without this field
are treated as Main Mode / public-IP-identity devices.

**Certificate-based clients:**
VPN nodes do NOT need individual client certificates. The client sends its
certificate in the IKE `CERT` payload; the node validates it against the
CA certificate. Only a small set of CA certs (one per customer PKI or one
global CA) needs to be loaded -- the same set on every node.

ipsecnode loads CA certs at startup via VICI `load-cert` from a local
directory (e.g. `/etc/ipsecnode/ca/`). CA certs are baked into the AMI
or pushed via configuration management. Certificate revocation (CRL/OCSP)
is handled dynamically by StrongSwan using URLs embedded in client certs.
No per-device cert pre-loading is needed or possible.

### 14. Return GW data-plane routing -- RESOLVED (2026-08-05)

**The gap (resolved):** Customer global IPs (e.g. 198.51.100.133/32) are not VPC IP
addresses. AWS VPC routes traffic based on destination IP using the source ENI's route
table. Non-VPC destination IPs follow the default route (NAT GW), not to the VPN
concentrator. However, within the SAME SUBNET, the VPC honours L2 MAC-based delivery:
a packet from eth3 (172.16.50.4, in VPN-b) to VPN concentrator (172.16.50.119, also
in VPN-b) with dst=198.51.100.133 IS delivered correctly by the VPC fabric.

**Solution implemented -- IPIP between Return GW nodes + VPN-subnet ENI (eth3):**
- Each Return GW node has eth3 in its local AZ VPN subnet (master: VPN-a 172.16.49.4,
  backup: VPN-b 172.16.50.4).
- An IPIP tunnel (ipip-gw) runs between the two Return GW BGP ENI IPs (172.16.51.4
  and 172.16.51.36). Cross-AZ customer traffic is tunnelled to the peer Return GW
  node which has local eth3 access to the VPN concentrators in its AZ.
- FRR BGP installs routes: same-AZ concentrators via eth3 (L2), remote-AZ via ipip-gw.
- The VPN concentrator's ens5 receives the forwarded packet (src=original backend IP,
  dst=customer global IP). VPP does the reverse DNAT.

**Critical sysctl finding:** `net.ipv4.conf.all.rp_filter = 0` (disabled) is required.
rp_filter=2 (loose) silently drops forwarded packets on the ipip-gw tunnel interface
because the source IP (e.g. 172.16.51.23 from ReturnGW-a) has no visible return path
via ipip-gw. The drop happens between PREROUTING and FORWARD with no log entry.
nftables trace (`meta nftrace set 1`) was the tool that revealed this: trace stopped
at PREROUTING before the fix, flowed to FORWARD oif=eth3 after.

**AMI changes needed for production build:**
- `_etc_sysctl.d_50-fleetroute.conf`: rp_filter changed from 2 to 0.
- `_etc_nftables_fleetroute.nft`: added `iifname "eth2" ip protocol 4 accept`
  (IPIP protocol must be allowed in INPUT for the tunnel to decapsulate).
- `_etc_init.d_keepalived`: added eth3 attach + IPIP tunnel setup + `dev eth2`
  on the ip tunnel add command.
- `fleetroute.pkr.hcl`: re-enable all 5 rc-update lines for production build.
- `aeroplug/src/attach.rs`: --takeover now correctly writes --write-ip-file.

---

### 15. Per-customer VRF isolation on VPN concentrators (Increment 6e)

**Problem:** The global VPP NAT table uses `internal_ip` as the key for
`nat44 add static mapping local <internal_ip> external <global_ip>`. With
180,000 medical devices behind 25,000 tunnels, hundreds of customers share
common internal IPs (e.g. 192.168.1.10). The second customer to connect
silently overwrites the first customer's NAT mapping. The `ip rule from
<internal_ip>/32 lookup 200` and `ip route replace <internal_ip>/32 dev
vpp-outer` entries are also in a single global namespace.

**Solution: XFRM interfaces + per-site VPP fib tables + per-site tap pairs.**

**XFRM interface per site (created at VICI load-conn time):**
- `ip link add xfrm-{hex} type xfrm dev ens5 if_id {if_id}`
- `if_id` = `u32::from(peer_ip.parse::<Ipv4Addr>())` -- derived from the
  customer gateway public IP, which is globally unique. No allocator needed.
  Name example: `xfrm-3eee6094` for 62.238.96.148.
- StrongSwan VICI `load-conn` includes `if_id_in = if_id`, `if_id_out = if_id`,
  `mark_out = if_id` in the child SA config.
- Inbound (decapsulate): StrongSwan installs XFRM state with `if_id`; all
  decapsulated packets from that tunnel appear arriving on `xfrm-{hex}`.
- Outbound (encapsulate): traffic routed to `xfrm-{hex}` is encrypted by
  the XFRM state with matching `if_id`.
- Lifecycle: created in `credentials::load_one_device`, deleted in
  `credentials::unload_one_device`.

**Per-site VPP VRF + tap (created on CHILD_SA UP, destroyed on DOWN):**
- `vrf_id = if_id` (same value, u32 from peer IPv4 address). VPP accepts any
  u32 as a fib table ID; public IPs are all > 16M so no conflict with reserved
  Linux tables (0-255).
- VPP commands: `ip table add {vrf_id}`, `create tap host-if-name vpp-{hex}`,
  `set interface ip table <vpp_tap> {vrf_id}`, `set interface ip address
  <vpp_tap> {tap_vpp_ip}/30`, `set interface state <vpp_tap> up`.
- Kernel: `ip addr add {tap_kern_ip}/30 dev vpp-{hex}`, `ip link set vpp-{hex} up`.
- NAT: `nat44 add static mapping local {internal_ip} external {global_ip} vrf
  {vrf_id}` -- per-site VRF isolates NAT tables; same internal_ip in two
  different VRFs coexist without conflict.
- `set interface nat44 in <per_site_tap> out vpp-outer` -- the shared outside
  interface (vpp-outer) handles all post-SNAT traffic regardless of VRF.

**Forward routing (inside -> VPP, per-site):**
- `ip rule add iif xfrm-{hex} prio 100 lookup {fwd_table}` (allocated
  10000+ by task-local VrfAllocator in event_listener_task).
- `ip route add default via {tap_vpp_ip} dev vpp-{hex} table {fwd_table}`.

**Return routing (VPP -> XFRM encrypt, per-site):**
- nftables mangle map `ipsecnode/vpp_mark { type iface_index : mark }` with
  rule `iif @vpp_taps meta mark set iif map @vpp_mark`. Added in `vpp::init()`.
  On CHILD_SA UP: add `{ifindex} : {if_id}` to both the set and map via
  `nft add element`. On DOWN: remove.
- `ip rule add iif vpp-{hex} prio 200 lookup 9999`.
- Shared table 9999 (created once): `ip route add default dev ens5 table 9999`.
- StrongSwan `mark_out = if_id` means the XFRM output policy for this CHILD_SA
  requires the packet mark to equal `if_id`. The nftables mangle sets this mark
  on packets arriving from vpp-{hex}, so the correct tunnel is selected even
  when two customers have the same `internal_ip`.

**Tap IP allocation:**
- `VrfAllocator` is task-local in `event_listener_task` (no shared state).
- Allocates: `fwd_table` from range 10000+, `ret_table` 60000+,
  `tap_subnet_idx` 0+ -> /30 from 10.127.0.0/16.
- Subnet n: VPP IP = 10.127.{n>>6}.{(n&63)*4+1}/30,
             kernel IP = 10.127.{n>>6}.{(n&63)*4+2}/30.
- IDs freed to a Vec freelist on CHILD_SA DOWN for reuse.

**Production capacity per c6in.4xlarge node:**
- Max concurrent sites: ~5,000 (memory bound: ~6-12 GB for taps + VRFs).
- NAT sessions: `nat44 plugin enable sessions 500000` (raise from 65536).
- Hugepages: `vm.nr_hugepages = 8192` = 16 GB (raise from 1024).
- Concentrators needed for 25,000 tunnels: 5 nodes (5 x 5,000).

---

### 16. Backend DNAT -- nftables PREROUTING with globally unique customer_view_ip

**Problem:** Customers may have devices configured to connect to a virtual IP
(e.g. `194.138.39.18`) that is NOT the real backend address in the VPC. The
`backend_nat` field in `NatRecord` (already deserialized) maps these virtual
IPs to real VPC IPs.

**Decision:** Handle `backend_nat` translations in the Linux kernel using
nftables PREROUTING DNAT, NOT inside VPP. VPP NAT44 static mappings only
translate source on inside->outside (SNAT) -- there is no standard mechanism
for destination NAT on the inside interface.

**How it works:**
- Forward: decapsulated packet arrives on ens5 with `dst=customer_view_ip`.
  nftables PREROUTING DNAT: `dst=customer_view_ip -> real_ip`. Conntrack
  tracks the connection.
- The packet then goes through VPP via vpp-{hex} (per-site tap). VPP applies
  device SNAT: `src=internal_ip -> global_ip`. Backend sees:
  `src=global_ip, dst=real_ip`.
- Return: backend replies `src=real_ip, dst=global_ip`. VPP reverses SNAT:
  `dst=global_ip -> internal_ip`. Kernel receives `src=real_ip, dst=internal_ip`
  on vpp-{hex}. Conntrack matches REPLY direction and applies reverse SNAT:
  `src=real_ip -> customer_view_ip` in POSTROUTING -- which fires BEFORE
  xfrm4_output_finish() encrypts the inner packet. Customer sees correct
  `src=customer_view_ip` inside the tunnel.

**Implementation in ipsecnode (Increment 6f):**
- `vpp::init()`: create nftables nat table `ipsecnode_bnat` with named map
  `bnat_map { type ipv4_addr : ipv4_addr }`, PREROUTING chain with rule
  `iifname ens5 dnat ip to ip daddr map @bnat_map`, and empty POSTROUTING
  chain (registers conntrack hook).
- On CHILD_SA UP: for each `backend_nat` entry, `nft add element ip
  ipsecnode_bnat bnat_map { customer_view_ip : real_ip }`.
- On CHILD_SA DOWN: `nft delete element ...`.

**Constraint:** `customer_view_ip` MUST be globally unique across all customers
on the same concentrator. Operators allocate `customer_view_ip` values from a
dedicated range (e.g. 194.138.39.0/24) with the same discipline as `global_ip`.
RFC 1918 overlapping `customer_view_ip` values across customers require VPP VRF
support (future increment; not currently implemented).

**Step 1 (manual test) PASSED:** nftables DNAT rule installed manually on
concentrator; helena1 curled 194.138.39.18, which was DNAT'd to 172.16.53.6.
Conntrack correctly reversed the SNAT on the return path.

---

### 17. On-demand tunnels -- start_action=trap + inactivity teardown

**Goal:** Tunnels should not be permanently maintained. When a device (or a
backend server on the AWS side) generates traffic, the tunnel is established
on-demand. When idle, the tunnel tears down and concentrator resources are freed.
This enables natural scale-in on concentrators.

**Mechanism:**
- `start_action = "trap"` (instead of `"none"`) in the VICI child SA config.
  StrongSwan installs XFRM trap policies. When the first packet matching the
  traffic selector arrives on EITHER side, StrongSwan auto-initiates IKE.
- `inactivity = 300` (seconds) in the child SA config. StrongSwan tears down
  a CHILD_SA that has carried no traffic for 5 minutes.
- `dpd_action = "restart"` (already set) re-establishes a dropped tunnel if
  the remote side is still reachable (DPD probe succeeds).

**Effect on ipsecnode:**
- VPP VRFs are already created on CHILD_SA UP and destroyed on DOWN -- the
  VRF design (Architecture Decision #15) is fully compatible with on-demand
  tunnels. No additional changes needed in vpp.rs.
- `start_action` and `inactivity` are per-site parameters added to
  `SiteRecord` (optional, with defaults matching current behaviour).

**Constraint for AWS-initiated tunnels:**
- For the trap policy to be specific enough (so concentrator initiates toward
  the RIGHT customer when backend traffic arrives), `local_ts` must NOT be
  `0.0.0.0/0`. It must include the device's `global_ip` range so the trap
  policy matches that customer only.
- `static_ip = true` required; dynamic-IP (CGNAT) devices cannot be dialled
  into from the AWS side.
- The routing path (backend subnet -> concentrator -> customer) needs design
  before this is testable. Deferred; see open topics.

**Status:** Design documented. Implementation deferred until AWS-initiated
tunnel routing design is complete.

---

## Binaries

### Shared from aerosuite -- via git submodule at `vendor/aerosuite`

| Crate | Path | Purpose |
|---|---|---|
| `aerocore` | `vendor/aerosuite/aerocore` | AWS API, IMDS, SigV4, credential helpers |
| `aeroplug` | `vendor/aerosuite/aeroplug` | ENI attach/detach (`aeroplug eni`); secondary IP assign/unassign (`aeroplug ip`) |

### `ipsecpulse` -- boot-time config generator (LVS nodes) -- IMPLEMENTED

Single binary with four modes:

| Mode | Invocation | Purpose |
|---|---|---|
| boot | `ipsecpulse` (no subcommand) | Reads IMDS, builds State, renders all config files |
| associate-mgmt-eip | `ipsecpulse associate-mgmt-eip` | Associates permanent management EIP to eth0 primary IP |
| notify-master | `ipsecpulse notify-master` | Associates customer EIP to secondary IP, updates rtb-vpn, writes role file |
| notify-backup | `ipsecpulse notify-backup` | Writes role file only |

**Boot run** (called from keepalived `start_pre` step 9):
1. IMDSv2 token + instance-id
2. Read 6 IMDS tags: `ipsec-lb-role`, `ipsec-vip-outside`, `ipsec-vip-inside`,
   `ipsec-lb-peer-mgmt-ip`, `ipsec-vpn-asg`, `ipsec-rtb-vpn`
3. Read NIC layout from IMDS (eth0 + eth1, already attached by this point)
4. Fetch VPN concentrator IPs from ASG via `DescribeInstances`
5. Serialise State to `/run/ipsecpulse.state` (0o644)
6. Render and write:
   - `/etc/keepalived/vrrp.conf` (unicast VRRP on eth1, no virtual_ipaddress)
   - `/etc/keepalived/notify-master.sh`
   - `/etc/keepalived/notify-backup.sh`
   - `/etc/nftables.d/ipsec-nat.nft` (DNAT + SNAT, SNAT source = secondary IP)

**State struct** (persisted to `/run/ipsecpulse.state`, read by notify subcommands):
```
instance_id        EC2 instance ID
role               "master" | "backup"
region             AWS region
eth0_eni_id        ENI ID of eth0
eth0_primary_ip    primary private IP of eth0 (dynamic, managed by AWS)
eth0_secondary_ip  fixed secondary IP of eth0 (from ipsec-vip-inside tag)
                   used as customer EIP target and nftables SNAT source
eth1_ip            primary IP of eth1 (management NIC)
eth1_prefix        subnet prefix length of eth1 subnet
peer_mgmt_ip       peer node's eth1 fixed IP (for VRRP unicast)
eip_alloc_id       customer-facing EIP allocation ID
rtb_vpn_id         route table ID for VPN subnets
vpn_asg_name       VPN concentrator ASG name
vpn_ips            private IPs of running VPN concentrators (sorted)
```

**associate-mgmt-eip** (called from keepalived `start_pre` step 2):
Reads `ipsec-mgmt-eip` tag from IMDS, reads eth0 ENI ID and primary IP from
IMDS, calls `AssociateAddress` with `AllowReassociation=true`. Safe to call
on restart (no-op if already associated). This call uses the auto-assigned
public IP from the LT for outbound access; the management EIP then permanently
replaces it.

**notify-master** (called by keepalived via generated notify-master.sh):
Loads State from disk, calls `AssociateAddress` to move the customer EIP to
`eth0_secondary_ip` (with `PrivateIpAddress` explicitly set), calls
`ReplaceRoute` / `CreateRoute` to update rtb-vpn, writes `master\n` to
`/run/ipsec-role`.

**notify-backup** (called by keepalived via generated notify-backup.sh):
Writes `backup\n` to `/run/ipsec-role`. No AWS API calls.

**Required EC2 instance tags (set on ASG with PropagateAtLaunch=true):**

```
ipsec-lb-role              "master" | "backup"
ipsec-vip-outside          eipalloc-095ac59bb763cd2ce  (customer EIP)
ipsec-vip-inside           172.16.48.10  (master)  | 172.16.48.40  (backup)
                           Fixed secondary IP on eth0. Customer EIP targets this.
                           SNAT source in nftables. Assigned to eth0 at boot
                           by aeroplug (start_pre step 3).
ipsec-vip-reservation-eni  ENI ID of the VIP reservation ENI for this node.
                           Holds ipsec-vip-inside as secondary IP when not in
                           use, preventing AWS DHCP from assigning it as a
                           primary IP to another instance.
ipsec-mgmt-eip             Allocation ID of this node's permanent management EIP.
                           Associated to eth0 primary IP in start_pre step 2.
ipsec-lb-peer-mgmt-ip      172.16.48.84 (for master) | 172.16.48.68 (for backup)
                           Peer's eth1 fixed IP for VRRP unicast.
ipsec-vpn-asg              fleetipsec-vpn
ipsec-rtb-vpn              rtb-01c3275faa537fcc1
```

### `ipsecscale` -- autoscaling daemon (LVS nodes) -- STUB

Long-running daemon on both LVS nodes. Reads `/run/ipsec-role` each cycle;
only the master acts. Responsibilities: backend pool management, ASG scaling
decisions, rtb-vpn maintenance, Valkey coordination (`fleetipsec:scale:`).

**Sizing (25,000 tunnels, 180,000 devices, c6in.4xlarge):**

| Metric | Per-node limit | Production target |
|---|---|---|
| Active tunnels | 5,000-8,000 | 5,000 |
| Devices | ~36,000 | 5,000 tunnels x 7.2 avg |
| NAT sessions | 500,000 (configurable) | set at VPP startup |
| Throughput | ~15 Gbps usable | ~360 Mbps at 180k x 10 kbps avg |
| Hugepages | 8,192 (16 GB) | production sysctl |
| Nodes steady state | 5 | 25,000 / 5,000 |
| ASG max | 10 | handles reconnect bursts |

**Scale-out criteria (add a node):**
- `avg_tunnels_per_node > 4,000` (80% of 5,000 target), OR
- `any_node_tunnels > 6,000`.

**Scale-in criteria (remove a node):**
- `avg_tunnels_per_node < 1,500` AND `desired_count > 2` (HA minimum).

**Scale-out sequence:**
1. `SetDesiredCapacity(N+1)` on ASG.
2. Wait for new node's `:9101/health` to return OK.
3. Rewrite LVS nftables DNAT pool: `jhash(src_ip) % (N+1)`. New connections
   land on the new node; existing tunnels stay on their current nodes.

**Scale-in sequence:**
1. Pick the lowest-tunnel node; remove from LVS pool (`jhash % (N-1)`).
2. Wait up to 300 s for tunnels to drain (DPD reconnect moves devices to
   surviving nodes naturally).
3. `CompleteLifecycleAction(CONTINUE)` -- ASG terminates the instance.

**Rehashing note:** `jhash(src_ip) % N` reassigns approximately `1/N` of
source IPs when N changes. Existing CHILD_SAs remain alive on their current
nodes until the next DPD failure or rekey. No forced teardown is needed.

**ipsecscale polls** each VPN node's `:9101/metrics` (or `/health`) for
tunnel count. The primary signal is active CHILD_SA count, not CPU or
throughput. Not yet implemented.

### `ipsecnode` -- per-node tunnel lifecycle daemon (VPN nodes) -- STUB

Long-running daemon on every VPN concentrator. Single process that owns both
the Valkey side and the StrongSwan side via VICI. No C plugin, no secrets
file, no `swanctl` subprocess calls for credential management.

**Responsibilities:**
- Connect to `/var/run/charon.vici` at startup; subscribe to `child-updown`
  events
- Bulk-load all PSKs from Valkey via VICI `load-shared` at startup
- Load CA certificates via VICI `load-cert` from `/etc/ipsecnode/ca/`
- Subscribe to Valkey keyspace notifications (`fleetipsec:psk:*`,
  `fleetipsec:site:*`); issue incremental `load-shared` / `unload-shared`
  VICI commands on change -- non-disruptive to existing tunnels
- On `child-updown` UP: look up `fleetipsec:site:<peer_ip>` in Valkey;
  tell VPP to create VRF + install 1:1 NAT; tell FRR to advertise /32 route
- On `child-updown` DOWN: tear down VRF/NAT in VPP; withdraw /32 from FRR
- Disable src/dest check on eth0 at startup (EC2 API via aerocore)
- ASG termination lifecycle hook: drain tunnels, call CompleteLifecycleAction
- Prometheus metrics + health endpoint on port 9101

**VICI** is a binary protocol over a Unix domain socket. The `rsvici` crate
on crates.io provides an async Rust VICI client. Increments 6a and 6b are
tightly coupled (VICI connection needed for both credential loading and
tunnel events) and should be implemented together.

Not yet implemented.

---

## Packer AMIs

### `aerobake/fleetscale/` -- IPSec LB (Alpine) -- IMPLEMENTED, TESTED

**Status:** cold boot, failover, and failback tested successfully in dev.
Instance type c6in.xlarge for dev (c6in.4xlarge for production).

**NIC layout:**
- eth0: public NIC (LVS-a/b subnet). Two private IPs: dynamic primary +
  fixed secondary (.10/.40). Management EIP on primary. Customer EIP on
  secondary when VRRP master.
- eth1: management NIC (LVS-mgmt-a/b subnet). VRRP heartbeat + SSH only.
  Attached at boot by aeroplug.

**keepalived init script (`_etc_init.d_keepalived`) -- 11-step start_pre:**

1. Read IMDS tags: `ipsec-lb-role`, `ipsec-lb-peer-mgmt-ip`, `ipsec-vip-inside`,
   `ipsec-vip-reservation-eni`, `ipsec-mgmt-eip`
2. `ipsecpulse associate-mgmt-eip` -- associates permanent management EIP to
   eth0 primary IP; uses the LT auto-assigned IP for this one call
3. `aeroplug ip --assign $VIP_INSIDE --allow-reassignment` -- steals the fixed
   secondary IP from the reservation ENI onto eth0; then `ip addr add .../32 dev eth0`
4. `aeroplug eni --tag ipsec-lb-mgmt=$ROLE --attach --device-index 1` -- attach
   eth1 with retry loop (up to 6 attempts, 5 s apart)
5. Wait for eth1 to appear in sysfs (up to 60 s)
6. Bring up eth1: `ip link set eth1 up`, assign IP and prefix from IMDS,
   add explicit route to peer's /28 via eth1 gateway (VPC router = subnet-base + 1)
7. Policy routing for eth1 SSH reply path (currently commented out)
8. Sleep 5 s to allow CT stabilisation before VRRP election
9. Run `ipsecpulse` (boot mode) -- renders all keepalived/nftables config files
10. Prime proto 112 conntrack toward peer (prevents spurious master election at cold boot)
11. Reload nftables nat table: `nft flush table ip nat && nft -f /etc/nftables.d/ipsec-nat.nft`
    Pre-create `/run/ipsecpulse-notify.log` and `/run/ipsec-role` with correct ownership.

**stop_post:**
1. Fetch IMDS token
2. IMDS check: confirm this instance still holds `ipsec-vip-inside` on its eth0
   ENI before returning it. If a replacement instance has already claimed it via
   start_pre, IMDS will show it gone -- skip the return to avoid stealing from
   the running replacement (TOCTOU guard).
3. If still held: `ip addr del .../32 dev eth0` then
   `aeroplug ip --eni $RESERVATION_ENI --assign --allow-reassignment` to
   return the IP atomically to the reservation ENI (no pool window).
4. Remove eth1 IP, bring eth1 down
5. `aeroplug eni --detach` to release the management ENI

**NOTE:** the management EIP is NOT disassociated in stop_post. It stays on
the primary IP permanently while the instance is alive. When the instance is
terminated, AWS deletes the ENI and automatically returns the EIP to the
unassociated pool.

**Key config files:**
- `_etc_nftables_fleetscale.nft` -- filter table (INPUT rules for eth0 + eth1)
- `_etc_nftables.d_ipsec-nat.nft` -- placeholder; overwritten by ipsecpulse at boot
- `_etc_keepalived_keepalived.conf` -- static; includes generated vrrp.conf
- `_etc_sysctl.d_50-fleetscale.conf` -- conntrack + forwarding + softirq tuning
- `_etc_modules-load.d_fleetscale.conf` -- loads `nf_conntrack_proto_esp`
- `_etc_conf.d_keepalived` -- sets REGION and VRRP_PASS env vars
- `_etc_init.d_ipsecscale` -- OpenRC init for ipsecscale (stub binary for now)

### `aerobake/fleetnode/` -- VPN Concentrator (Debian 12 Bookworm) -- IN PROGRESS

### `aerobake/fleetroute/` -- Return GW (Alpine) -- TODO

---

## nftables Rules for the LVS Nodes

File: `aerobake/fleetscale/_etc_nftables_fleetscale.nft`

```
Inbound DNAT (PREROUTING, generated into ipsec-nat.nft by ipsecpulse):
  ip protocol 50                   -> jhash ip saddr mod N map {0:vpn1, 1:vpn2, ...}
  ip protocol udp udp dport 500    -> jhash ip saddr mod N map {0:vpn1, 1:vpn2, ...}
  ip protocol udp udp dport 4500   -> jhash ip saddr mod N map {0:vpn1, 1:vpn2, ...}
  Uses inline anonymous maps -- no named map or $VARIABLE in mod position.

Return SNAT (POSTROUTING, generated into ipsec-nat.nft by ipsecpulse):
  oifname "eth0" ip saddr {172.16.49.0/24, 172.16.50.0/24} snat to <secondary-ip>
  <secondary-ip> = eth0_secondary_ip from State (172.16.48.10 or 172.16.48.40)
  Stateless -- no conntrack dependency for the SNAT rule itself.

Filter (INPUT on eth0, in fleetscale.nft):
  Allow: icmp, lo, established/related
  Allow: UDP 500, UDP 4500, proto 50 from 0.0.0.0/0
  Reject everything else.

Filter (INPUT on eth1, in fleetscale.nft):
  Allow: TCP 22 from CLI_RemoteAccess SG range
  Allow: proto 112 (VRRP) from peer LVS node
  Allow: icmp, lo, established/related
  Reject everything else.
```

---

## sysctl Tuning for LVS Nodes

```
# ESP conntrack
net.netfilter.nf_conntrack_max                = 500000
net.netfilter.nf_conntrack_udp_timeout        = 300
net.netfilter.nf_conntrack_udp_timeout_stream = 600
# nf_conntrack_proto_esp loaded via modules-load.d

# Forwarding
net.ipv4.ip_forward              = 1
net.ipv4.conf.all.rp_filter      = 1

# Softirq throughput (c6in.4xlarge has 16 vCPUs)
net.core.netdev_budget           = 1200
net.core.netdev_budget_usecs     = 8000

# Socket buffers for high-PPS UDP
net.core.rmem_max                = 134217728
net.core.wmem_max                = 134217728
```

---

## Build Order

1. **`ipsecpulse` + `aerobake/fleetscale/`** -- COMPLETE. Cold boot, failover,
   and failback tested in dev. Remaining work: ipsecscale integration.
   **Fix applied:** `ipsecpulse associate-mgmt-eip` now calls
   `ModifyNetworkInterfaceAttribute` (SourceDestCheck=false) immediately after
   associating the management EIP. Every future ASG replacement instance fixes
   itself automatically at boot.
2. **`aerobake/fleetnode/` VPN infra** -- COMPLETE. IAM role/profile, Launch
   Template `fleetipsec-lt-vpn`, ASG `fleetipsec-vpn` with drain lifecycle hook
   all created.
3. **`aerobake/fleetnode/` -- rebase to Debian 12 Bookworm + AMI rebuild** -- COMPLETE (AMI rebuild in progress for swanctl config fix).
   Debian 12 AMI, ssh user `admin`, FRR from `frrouting.org`, VPP from `fdio/release`.
   Ubuntu-specific packages removed. `valkeyauth/` artefacts removed.
   swanctl.conf: `install_policy` keyword not supported in StrongSwan 5.9.8
   swanctl format; replaced with bypass-vpc (172.16.0.0/16) and bypass-office
   (192.168.13.0/24) pass-mode connections. ami-0d3c80537d8b691f0 (LT v7) had
   the broken config baked in; replaced by LT v8 (`ami-02dd075664df52991`).
   T1 testing complete on Bookworm (see Implementation Notes).
4. **`aerobake/fleetnode/` -- FRR BGP** -- COMPLETE. BGP base config baked into
   AMI. ASN 65001 (VPN nodes) peering with ASN 65002 (Return GW) at fixed IPs
   172.16.51.4 and 172.16.51.36. EXPORT-CUSTOMER route-map enforces /32-only
   export. FRR still DISABLED in AMI -- enable at T3 (after Return GW built).
   Rebuild AMI, run `update_lt_vpn_ami.sh`, then `cycle_vpn_instance.sh`.
5. **`aerobake/fleetnode/` -- VPP** -- startup.conf in AMI.  **COMPLETE (step 5).**
   Two new files: `_etc_vpp_startup.conf` (DPDK disabled, af_packet mode,
   hugepages via sysctl) and `_etc_vpp_setup.gate` (empty CLI startup).
   VPP is ENABLED (was masked); `ipsecnode.service` now orders after `vpp.service`.
   `vm.nr_hugepages = 1024` added to `_etc_sysctl.d_50-fleetnode.conf`.
   **AMI rebuild required** -- see "Next Session Starting Point".
6. **`ipsecnode` Increment 6a+6b** -- COMPLETE (2026-08-04). VICI connection,
   `child-updown` event loop, bulk PSK + per-site `load-conn` from Valkey,
   Valkey keyspace pubsub, CA cert loading, src/dest check disable, health :9101.
   Catch-all swanctl connections removed -- every site must have a Valkey record.
   `OneOrMany<T>` proposal profiles, cartesian-product builder in `proposals.rs`.
   `local_ts` + `remote_ts` both configurable per site. `mapped_global_ip`
   removed from `SiteRecord` (kept as `Option` for backward compat).
   T1 tested and passing on freshly baked AMI.
   - 6c: FRR /32 route management -- **COMPLETE**. `nat.rs` module with
     `NatRecord`/`DeviceNatEntry`/`BackendNatEntry` types. `on_child_up` adds
     `ip route replace blackhole <global_ip>/32` and caches per-peer state
     with a refcount for re-keying safety. `on_child_down` removes routes when
     the last CHILD_SA for a peer goes down. `event_listener_task` now accepts
     `redis::Client` for NAT record lookups.
     **Test passed (2026-08-04):** `fleetipsec:nat:62.238.96.148` seeded with
     `198.51.100.133` for helena1. `blackhole 198.51.100.133` appeared in
     `ip route show` on CHILD_SA UP and disappeared on DOWN.
   - 6d: VPP tap interface + NAT44 data plane -- **COMPLETE**.
     New `vpp.rs` module. `vpp::init()` at startup: creates `vpp-inner`/`vpp-outer`
     tap interfaces (IPs 10.255.0.1/30 and 10.255.0.5/30), enables NAT44,
     sets inside/outside, adds VPP default route via outer tap, adds Linux
     table-200 default route to vpp-inner.
     On CHILD_SA UP: VPP static NAT mapping + VPP return-path route +
     Linux policy rule (`ip rule from <internal_ip>/32 lookup 200`) +
     upgrades global_ip route from blackhole to `dev vpp-outer`.
     On CHILD_SA DOWN: reverses all of the above.
     VPP unavailability is non-fatal (degraded mode, no data plane).
     `nat.rs route_del` no longer specifies `blackhole` type (works for both
     blackhole and dev routes).
     **T4 PASSED (2026-08-06).** See T4 section and Next Session Starting Point.
     **KNOWN ISSUE:** global VPP NAT table breaks when two customers share the
     same device internal_ip. Fixed in Increment 6e.
   - 6e: Per-customer VRF isolation -- **IN PROGRESS**.
     Replaces global vpp-inner + table-200 with per-site XFRM interfaces,
     per-site VPP fib tables, and per-site tap pairs. See Architecture
     Decision #15 for full design. Key constants:
       - Physical NIC: `ens5` (Nitro naming, Debian Bookworm AMI)
       - XFRM interface name: `xfrm-{peer_ip_hex8}` (e.g. xfrm-3eee6094)
       - Per-site tap kernel name: `vpp-{peer_ip_hex8}` (e.g. vpp-3eee6094)
       - if_id = u32::from(peer_ip as Ipv4Addr) (unique, no allocator needed)
       - Forward routing table: allocated 10000+ (VrfAllocator, task-local)
       - Return routing table: allocated 60000+ (VrfAllocator, task-local)
       - Tap /30 subnet: allocated from 10.127.0.0/16 (VrfAllocator)
       - Shared return table 9999: `default dev ens5`
       - nftables mangle map `ipsecnode/vpp_mark`: ifindex -> mark (if_id)
     Production sysctl values (raise from dev defaults):
       - `nat44 plugin enable sessions 500000` (was 65536 -- too low)
       - `vm.nr_hugepages = 8192` (was 1024 = 2 GB; per-site taps need ~16 GB)
   - 6f: Backend DNAT via nftables PREROUTING -- see Architecture Decision #16.
     Tested manually (Step 1 PASSED). Implement in ipsecnode after 6e.
   - 6g: ASG lifecycle hook heartbeat
   - 6h: Valkey half-open IKE SA state
7. **`aerobake/fleetroute/`** -- Return GW AMI (Alpine): FRR BGP + keepalived. **COMPLETE (code written, not yet deployed).** New `fleetpulse` binary (workspace member). Fixed IPs 172.16.51.4 (master) and 172.16.51.36 (backup). `bgp listen range` accepts dynamic VPN node pool. Route-table failover approach (no floating IP). Infrastructure scripts: `make_enis_returngw.sh`, `make_rtb_backend.sh`, `make_lt_returngw.sh`, `make_asg_returngw.sh`.
8. **`ipsecscale`** -- LVS autoscaling daemon. See ipsecscale section for
   concrete sizing and scale-out criteria.
   - 25,000 tunnels across 5 x c6in.4xlarge concentrators (5,000/node).
   - Scale-out trigger: avg tunnels/node > 4,000 OR any node > 6,000.
   - Scale-in trigger: avg tunnels/node < 1,500 AND desired > 2.
   - Scale-out: ASG SetDesiredCapacity(N+1), wait for :9101 health OK,
     add to LVS nftables pool (jhash % N+1).
   - Scale-in: remove from LVS pool, wait 300 s drain, CompleteLifecycleAction.
   - Rehashing: jhash(src_ip) % N shifts ~1/N of source IPs on resize;
     existing tunnels reconnect naturally via DPD.

---

## Infrastructure -- Completed Actions

All infrastructure scripts are in `infrastructure/`. Scripts that have been
executed have their output appended in the file after a `RESULT` marker.

| Script | Status | Notes |
|---|---|---|
| `make_subnets.sh` | Done | All subnets created |
| `make_security_groups.sh` | Done | All SGs created |
| `make_security_rules.sh` | Done | All SG rules applied |
| `make_eip_routetables.sh` | Done | EIPs + route tables created |
| `make_route_associations.sh` | Done | Route table associations |
| `make_mgmt_subnets.sh` | Done | LVS-mgmt-a/b + ReturnGW-mgmt-a/b created |
| `make_mgmt_associations.sh` | Done | mgmt subnets associated to rtb-private |
| `make_NATGW_RDS.sh` | Done | NAT GW + RDS created |
| `make_iam_lvs.sh` | Done | IAM instance profile |
| `make_enis_lvs.sh` | Done | Pre-created management ENIs (eth1) |
| `make_lt_lvs.sh` | Done | Launch Template `fleetipsec-lt-lvs` (lt-097024e3facf45bd3) |
| `update_lt_lvs_publicip.sh` | Done | LT v2: AssociatePublicIpAddress=true (current default) |
| `make_asg_lvs.sh` | Done | ASGs `fleetipsec-lvs-master` + `fleetipsec-lvs-backup` |
| `make_vip_reservation_enis.sh` | Done | VIP reservation ENIs; `ipsec-vip-reservation-eni` ASG tags set |
| `make_iam_vpn.sh` | Done | IAM role `fleetipsec-vpn-role` + instance profile `fleetipsec-vpn-profile` |
| `make_lt_vpn.sh` | Done | Launch Template `fleetipsec-lt-vpn` (lt-02a4499a34fa61c3b); v1 = Ubuntu 24.04 stand-in; current default v8 = Debian Bookworm `ami-02dd075664df52991` |
| `make_asg_vpn.sh` | Done | ASG `fleetipsec-vpn` (min=1 max=10) + lifecycle hook `fleetipsec-vpn-drain` |
| `update_lt_vpn_srcdstcheck.sh` | Done | LT v2: user data disables src/dest check at boot; running instance `eni-0a3b04ae06663662f` fixed manually |
| `update_lt_vpn_remove_userdata.sh` | Done | LT v3: removed awscli user data; src/dest check will be handled by ipsecnode at startup |
| `update_lt_vpn_ami.sh` | Done | LT v4: fleetnode skeleton AMI `ami-0e4b56716bd7d28f6` |
| `make_tag_vip_inside.sh` | Done | `ipsec-vip-inside` ASG tags set (.10 and .40) |
| `make_mgmt_eips.sh` | Done | Management EIPs allocated; `ipsec-mgmt-eip` ASG tags set |
| `make_rtb_backend.sh` | Done | `FleetShell-IPSec-rtb-backend` (`rtb-0a446e715fc3ec757`). No default route -- set by `fleetpulse notify-master` on VRRP election. |
| `make_sg_backend.sh` | Done | `FleetShell-IPSec-sg-backend` (`sg-0516f1d2561c7754d` -- check script for actual ID). Allows ICMP + TCP 80 + TCP 8080 inbound from `198.51.100.0/24`; SSH from `CLI_RemoteAccess`. |
| `make_subnets_backend.sh` | Done | `FleetShell-IPSec-Backend-a` (`subnet-01a513292ea15ae83`, 172.16.53.0/24, AZ-a) + `FleetShell-IPSec-Backend-b` (`subnet-08213d03f2940855c`, 172.16.54.0/24, AZ-b). Both associated with `rtb-0a446e715fc3ec757`. |
| `make_vpc_endpoints_backend.sh` | Done | S3 gateway endpoint (`vpce-0e96b7a35f98814ee`) on rtb-backend. Interface endpoints: ECR API (`vpce-0ce0b1dbd9132e371`), ECR DKR (`vpce-07e51ffc9257f76e2`), SSM (`vpce-007ba3bbe76f41014`), SSMMessages (`vpce-0e76ffe5b3bfa9533`), EC2Messages (`vpce-0d3947acf8d9bf3e5`). Endpoint SG: `sg-0438c989d6fe0f276` (`FleetShell-IPSec-sg-endpoints`). |

### Packer AMIs

| AMI ID | Name | Base OS | Built | Contents |
|---|---|---|---|---|
| `ami-0cbada86feaa752f7` | `fleetscale-alpine` | Alpine 3.23.3 | (prior) | keepalived, nftables, ipsecpulse, aeroplug, ipsecscale stub |
| `ami-0e4b56716bd7d28f6` | `fleetnode-ubuntu2404` | Ubuntu 24.04 LTS | 2026-08-03 | skeleton only -- superseded, do not use |
| `ami-0fc1555de9422edb4` | `fleetnode-ubuntu2404` | Ubuntu 24.04 LTS | 2026-08-03 | StrongSwan 5.9.13; Ubuntu base -- superseded, do not use |
| `ami-05cb5d404a127a9e7` | `fleetnode-ubuntu2404` | Ubuntu 24.04 LTS | 2026-08-03 | superseded, do not use |
| `ami-0d3c80537d8b691f0` | `fleetnode-bookworm` | Debian 12 Bookworm | 2026-08-03 | superseded -- swanctl config had invalid install_policy keyword; do not use |
| `ami-02dd075664df52991` | `fleetnode-bookworm` | Debian 12 Bookworm | 2026-08-04 | current AMI (LT v8); bypass-vpc + bypass-office; StrongSwan, FRR (disabled), VPP (masked); ipsecnode stub |

### Pre-created ENIs (must not be deleted)

| ENI name | ENI ID | Subnet | Fixed IP | Tag | Purpose |
|---|---|---|---|---|---|
| `fleetipsec-eni-lvs-mgmt-master` | `eni-0df0c11c6fbc81542` | LVS-mgmt-a (172.16.48.64/28) | 172.16.48.68 | `ipsec-lb-mgmt=master` | eth1 for master LVS node |
| `fleetipsec-eni-lvs-mgmt-backup` | `eni-0c180dfe894914611` | LVS-mgmt-b (172.16.48.80/28) | 172.16.48.84 | `ipsec-lb-mgmt=backup` | eth1 for backup LVS node |
| `fleetipsec-eni-vip-master` | see `aws ec2 describe-network-interfaces --filters Name=tag:ipsec-vip-reservation,Values=master` | LVS-a (172.16.48.0/27) | secondary: 172.16.48.10 | `ipsec-vip-reservation=master` | Holds .10 when not on instance |
| `fleetipsec-eni-vip-backup` | see `aws ec2 describe-network-interfaces --filters Name=tag:ipsec-vip-reservation,Values=backup` | LVS-b (172.16.48.32/27) | secondary: 172.16.48.40 | `ipsec-vip-reservation=backup` | Holds .40 when not on instance |
| `fleetipsec-eni-returngw-mgmt-master` | (create when needed) | ReturnGW-mgmt-a (172.16.51.64/28) | 172.16.51.68 | `ipsec-gw-mgmt=master` | eth1 for master ReturnGW |
| `fleetipsec-eni-returngw-mgmt-backup` | (create when needed) | ReturnGW-mgmt-b (172.16.51.96/28) | 172.16.51.100 | `ipsec-gw-mgmt=backup` | eth1 for backup ReturnGW |

### Launch Templates

| Name | ID | Current default | Notes |
|---|---|---|---|
| `fleetipsec-lt-lvs` | `lt-097024e3facf45bd3` | v2+ (check current) | c6in.xlarge (dev), AssociatePublicIpAddress=true, InstanceMetadataTags=enabled |
| `fleetipsec-lt-vpn` | `lt-02a4499a34fa61c3b` | v8 | c6in.xlarge (dev), no public IP, sg-vpn, InstanceMetadataTags=enabled; src/dest check disabled by ipsecnode at startup (Increment 6a); current AMI `ami-02dd075664df52991` (Debian Bookworm) |

When building a new AMI, create a new LT version pointing to it and set as
default **before** terminating running instances:
```bash
aws ec2 create-launch-template-version \
  --launch-template-name fleetipsec-lt-lvs \
  --source-version '$Latest' \
  --launch-template-data '{"ImageId":"ami-NEWID"}' \
  --region eu-west-2

aws ec2 modify-launch-template \
  --launch-template-name fleetipsec-lt-lvs \
  --default-version '$Latest' \
  --region eu-west-2
```

### IAM Instance Profiles

| Profile | Role | Managed policies | Used by |
|---|---|---|---|
| `ecsInstanceRole` | (existing shared role) | AmazonEC2FullAccess, AutoScalingFullAccess, AmazonSSMManagedInstanceCore, AWSSecretsManagerClientReadOnlyAccess, + others | LVS nodes (dev), shared with aerosuite |
| `fleetipsec-vpn-profile` | `fleetipsec-vpn-role` | AmazonEC2FullAccess, AutoScalingFullAccess, AmazonSSMManagedInstanceCore, AWSSecretsManagerClientReadOnlyAccess, CloudWatchAgentServerPolicy | VPN concentrator nodes |

### ASGs and Instance Tags

All LVS instance tags (set on ASG with PropagateAtLaunch=true):

| Tag | `fleetipsec-lvs-master` | `fleetipsec-lvs-backup` | Notes |
|---|---|---|---|
| `ipsec-lb-role` | `master` | `backup` | VRRP priority; notify script behaviour |
| `ipsec-lb-cluster` | `fleetipsec-lb` | `fleetipsec-lb` | Shared cluster label |
| `ipsec-vip-outside` | `eipalloc-095ac59bb763cd2ce` | `eipalloc-095ac59bb763cd2ce` | Customer EIP |
| `ipsec-vip-inside` | `172.16.48.10` | `172.16.48.40` | Fixed secondary IP; EIP target + SNAT source |
| `ipsec-vip-reservation-eni` | ENI ID of `fleetipsec-eni-vip-master` | ENI ID of `fleetipsec-eni-vip-backup` | Reservation ENI holding .10/.40 when not on instance |
| `ipsec-mgmt-eip` | alloc ID of master mgmt EIP | alloc ID of backup mgmt EIP | Permanent management EIP for primary IP |
| `ipsec-lb-peer-mgmt-ip` | `172.16.48.84` | `172.16.48.68` | Peer eth1 IP for VRRP unicast |
| `ipsec-vpn-asg` | `fleetipsec-vpn` | `fleetipsec-vpn` | VPN concentrator ASG |
| `ipsec-rtb-vpn` | `rtb-01c3275faa537fcc1` | `rtb-01c3275faa537fcc1` | Route table updated on master transition |

### VPN ASG (`fleetipsec-vpn`)

| Resource | Value | Notes |
|---|---|---|
| ASG name | `fleetipsec-vpn` | Spans VPN-a (eu-west-2a) + VPN-b (eu-west-2b) |
| Subnets | `subnet-05a86c0fe6eec7b10`, `subnet-0ab2ba73e9b587e2e` | 172.16.49.0/24 + 172.16.50.0/24 |
| Sizing | min=1 max=10 desired=1 | Raise max for production (10 x c6in.4xlarge = 25k tunnels) |
| Lifecycle hook | `fleetipsec-vpn-drain` | TERMINATING, 300 s heartbeat, default=ABANDON |

VPN instance tags (set on ASG with PropagateAtLaunch=true):

| Tag | Value | Notes |
|---|---|---|
| `Name` | `fleetipsec-vpn` | Console display name |
| `ipsec-vpn-cluster` | `fleetipsec-vpn` | Cluster label; used by ipsecscale to discover pool members |
| `ipsec-vpn-asg` | `fleetipsec-vpn` | ASG name; used by ipsecnode for lifecycle hook calls |
| `ipsec-rds-endpoint` | `fleetshell-ipsec-strongswan.cpgmocimewi5.eu-west-2.rds.amazonaws.com` | Retained for future use; ipsecnode does NOT query it at runtime |
| `ipsec-valkey-endpoint` | `clustercfg.dev-valkey-aeroftp.ak121m.memorydb.eu-west-2.amazonaws.com:6379` | Half-open IKE SA state store |

---

## Deferred: rtb-vpn default route

Set automatically by `ipsecpulse notify-master` on first master election:
```bash
aws ec2 create-route \
  --route-table-id rtb-01c3275faa537fcc1 \
  --destination-cidr-block 0.0.0.0/0 \
  --network-interface-id <eni-id-of-master-lvs-eth0>
```
On subsequent failovers, `ipsecscale` replaces this route with the new
master's ENI ID.

---

## Testing Framework

Four incremental test stages. Each builds on the previous.

### T1 -- IKE SA establishment (NAT-T, no data plane)

**What is active:** StrongSwan + ipsecnode (Increment 6a+6b). FRR disabled. VPP masked.

**What this proves:**
- ipsecnode starts, connects to VICI, loads PSKs from Valkey via `load-shared`
- IKEv1 Main Mode + NAT-T negotiates end-to-end through the LVS
- IKEv2 + NAT-T negotiates; MOBIKE supported
- `child-updown` events appear in ipsecnode logs
- No xfrm tunnel policies installed until a CHILD_SA is active (bypass policies protect VPC/office)

**Risk to management access:** zero.

**Procedure:**
1. Seed Valkey with koi's test PSK:
   ```bash
   # On any host with TLS-capable redis-cli and MemoryDB access:
   redis-cli -u rediss://<memorydb-endpoint>:6379 \
     SET fleetipsec:psk:185.17.205.224 testpsk123
   redis-cli -u rediss://<memorydb-endpoint>:6379 \
     SET fleetipsec:site:185.17.205.224 \
     '{"mapped_global_ip":"203.0.113.1","customer_id":"koi-test"}'
   ```
2. Build and deploy the new AMI (includes ipsecnode 6a+6b + FRR config).
3. From koi: `swanctl --initiate --child fleetipsec-ikev2` (IKEv2) or `--child fleetipsec-ikev1` (IKEv1).
4. Verify on VPN node: `swanctl --list-sas` shows the CHILD_SA; `journalctl -u ipsecnode` shows `CHILD_SA UP`.

**Status:** COMPLETE (2026-08-04). IKEv2 + NAT-T established end-to-end through LVS.
ipsecnode loaded PSK from Valkey via VICI `load-shared`, received `child-updown` events
with correct peer_ip/peer_id/conn_name/child_id/ike_sa fields.

VICI `child-updown` event structure (StrongSwan 5.9.8, confirmed by trace log):
```
{
  "<ike_sa_name>": {           // e.g. "fleetipsec-ikev2" -- IKE SA name is the key
    "remote-host": "<peer_ip>",
    "remote-id":   "<peer_id>",
    "uniqueid":    "<ike_sa_id>",
    "state":       "ESTABLISHED",
    "child-sas": {
      "<child_sa_name>": {      // e.g. "fleetipsec-ikev2-9"
        "name":     "<conn_name>",
        "uniqueid": "<child_id>",
        "state":    "INSTALLED" | "DELETED",
        "remote-ts": [...],
        "local-ts":  [...]
      }
    }
  },
  "up": "yes"                  // present on UP; absent on DOWN
}
```

Known issues fixed during T1:
- IMDS path double-prefix bug (`meta-data/mac` → `mac`)
- VICI `load-conn` field names: underscores, `remote_addrs` must be `Vec<String>`
- VICI `child-updown` event: serde_vici emits bytes not strings; `ViciRawValue`
  custom Deserialize handles `visit_bytes` for all VICI octet-strings
- LVS SG missing ingress rule for VPN node management traffic (all from sg-vpn)
- MemoryDB SG missing TCP 6379 inbound rule from VPN subnets
- rtb-vpn default route verified correct; MemoryDB `CONFIG SET` not supported
  (non-fatal; keyspace events configured via parameter group)
- IMDS timeout capped at 5 s (was 30 s default, blocking startup)

Add `bypass-lan` to koi's `fleet-test.conf` before re-testing to prevent SSH loss:
```
bypass-lan {
    children { bypass-lan {
        local_ts = 192.168.13.0/24; remote_ts = 192.168.13.0/24
        mode = pass; start_action = trap
    }}
}
```

### T2 -- Data path through kernel xfrm (narrow selectors)

**What is active:** StrongSwan only. ipsecnode logs events.
No new AMI needed -- testable on the current running instance.

**What this proves:** kernel xfrm encapsulates/decapsulates ESP correctly
end-to-end through the LVS DNAT path.

**Risk to management access:** zero -- the narrow selectors (RFC 5737 test-net
subnets, 192.0.2.0/30 and 198.51.100.0/30) never match VPC or office traffic.

**Procedure (on the running VPN node, no AMI rebuild required):**
1. SSH into the VPN node.
2. Add a dummy interface for the ping target:
   ```bash
   sudo ip link add dummy0 type dummy
   sudo ip addr add 192.0.2.1/30 dev dummy0
   sudo ip link set dummy0 up
   ```
3. No `test-narrow.conf` needed on the VPN node -- the catch-all connection
   (`0.0.0.0/0 <-> 0.0.0.0/0`) accepts and narrows any proposal.
4. On koi: upload a `test-narrow.conf` to `/etc/swanctl/conf.d/`:
   ```
   connections {
     test-narrow {
       version      = 2
       local_addrs  = %any
       remote_addrs = 3.11.124.22
       proposals    = aes256-sha256-modp2048
       local  { auth = psk }
       remote { auth = psk; id = %any }
       children {
         test-narrow {
           local_ts      = 198.51.100.0/30
           remote_ts     = 192.0.2.0/30
           esp_proposals = aes256gcm16
           start_action  = none
         }
       }
     }
   }
   secrets { ike-koi { id = %any; secret = testpsk123 } }
   ```
5. `swanctl --load-all && swanctl --initiate --child test-narrow`
6. `ping -I 198.51.100.1 192.0.2.1` from koi.
7. Verify on VPN node: `ip -s xfrm state show` shows increasing packet counters.

**Status:** COMPLETE (2026-08-04). Full xfrm data path verified end-to-end.
seagull (192.168.13.133) pinged dummy0 (194.138.39.18) on the VPN node via
the IPsec tunnel. 0% packet loss, ~27ms RTT.

Lessons learned during T2:
- `send_redirects` must be disabled on the customer gateway (koi) LAN interface.
  `net.ipv4.conf.all.send_redirects=0` alone is NOT sufficient -- Linux uses
  OR(all, interface) semantics. Must also set the per-interface value to 0.
- `bypass-office` in fleetipsec.conf interferes with the tunnel reply path when
  test devices are in the office LAN range (192.168.13.x). Removed permanently
  -- management SSH arrives via bastion (172.16.x.x), covered by bypass-vpc.
- StrongSwan `dir out` xfrm policy applies to both locally-generated AND
  forwarded packets (Linux checks XFRM_POLICY_OUT in the output phase of the
  forward path). No separate `dir fwd` policy is needed for the customer
  gateway to encapsulate forwarded device traffic.

### T3 -- FRR /32 route advertisement

**Pre-requisites:** Return GW AMI built and running (Build Order step 7).
ipsecnode Increment 6c implemented.

**What this proves:** FRR BGP sessions come up between VPN nodes (AS 65001)
and Return GW (AS 65002); `/32` host routes for customer `mapped_global_ip`
appear in Return GW's BGP table on CHILD_SA UP.

### T4 -- VPP data plane

**Status: PASSED (2026-08-06).** Full VPP NAT + return path via Return GW confirmed.

Helena1 (62.238.96.148) IKEv2+NAT-T tunnel. dummy0 holds 192.168.13.133/32
(simulated customer device). Traffic selector: local=192.168.13.133/32,
remote=172.16.53.6/32 (backend container in Backend-a). VPP SNAT:
192.168.13.133->198.51.100.133. HTTP GET to 172.16.53.6:8080 succeeded
end-to-end. Return path: backend->rtb-backend->Return GW master->ipip-gw->
Return GW backup->eth3->VPN concentrator ens5->vpp-outer->VPP reverse NAT->
xfrm encrypt->helena1.

Bugs found and fixed during T4:
1. FRR disabled on VPN concentrator (Packer had `systemctl disable frr`).
   Fixed: `systemctl enable frr` in fleetnode.pkr.hcl.
2. `net.ipv4.conf.default.rp_filter=1` on Return GW backup caused ipip-gw to
   silently drop forwarded packets (MAX(all=0, ipip-gw=1)=1, strict mode).
   Fixed: `net.ipv4.conf.default.rp_filter=0` added to 50-fleetroute.conf.

Client-side note: on the test gateway (helena1), a route with `src` prefsrc
is required so curl uses the correct source IP without SO_BINDTODEVICE:
`ip route add 172.16.53.6 via <gw> dev eth0 src 192.168.13.133`
The test IP (192.168.13.133) must be assigned to a local interface (dummy0 or
a secondary IP on eth0). SO_BINDTODEVICE must NOT be used -- decapsulated
packets appear on eth0, not on dummy0, so a device-bound socket never receives
the SYN-ACK.

---

## Implementation Notes (lessons learned in dev)

### LVS src/dest check disabled automatically by ipsecpulse

The nftables SNAT rule (`oifname eth0 ip saddr {172.16.49.0/24, 172.16.50.0/24} snat
to <secondary-ip>`) only fires on RETURN traffic (VPN node to customer). FORWARD
traffic (customer to VPN node, post-DNAT) leaves eth0 with the original customer
source IP. AWS drops this with src/dest check enabled.

Fix applied in `ipsecpulse associate-mgmt-eip`: immediately after associating
the management EIP, ipsecpulse calls `ModifyNetworkInterfaceAttribute` with
`SourceDestCheck.Value=false` on eth0. Every ASG replacement instance now
fixes itself automatically at boot. Both running LVS eth0 ENIs were also fixed
manually during earlier testing.

### StrongSwan credential management -- C plugin approach abandoned

A custom C plugin (`valkeyauth`) was prototyped (source retained in
`aerobake/fleetnode/valkeyauth/` for reference, not built into the AMI).
The approach was abandoned because `libstrongswan-dev` no longer exists on
any current Debian or Ubuntu release (dropped from Debian after Bullseye;
never packaged by Canonical). No viable path existed to compile a C plugin
without significant build fragility.

The chosen approach -- ipsecnode owning all credential management via VICI
`load-shared`/`unload-shared` commands -- is simpler, has zero C code, and
gives better operational properties (incremental updates, non-disruptive
reloads). See Architecture Decision #12.

### Traffic selectors and management access

With the catch-all connection and `local_ts = remote_ts = 0.0.0.0/0`, StrongSwan
installs an outbound xfrm policy that captures ALL packets from the VPN node,
including SSH reply traffic. Management SSH breaks.

Mitigation in AMI: `bypass-management` passthrough connection for `172.16.0.0/16`
prevents VPC-internal traffic (including bastion SSH) from being tunneled.

In production: customer devices propose their own LAN (e.g. `10.x.x.x/24`) as
`local_ts`, so the VPN node's outbound xfrm policy only encrypts traffic destined
for that specific LAN. Office-network SSH (from `192.168.13.x`) is never captured.

Future (Increment 5 -- VPP): when VPP owns the data plane, investigate
suppressing xfrm policy installation. StrongSwan 5.9.8 swanctl.conf does
not support `install_policy` (that is ipsec.conf/stroke syntax). The bypass
connections (bypass-vpc, bypass-office) are the 5.9.8-compatible approach
and remain in place regardless.

### StrongSwan ESP PFS and the initial CHILD_SA

ipsecnode correctly loads `esp_proposals=["aes256gcm16-modp2048"]` into charon
via VICI `load-conn` (confirmed by debug log). However, the initial CHILD_SA
(created inside IKE_AUTH) always negotiates without PFS -- this is correct
IKEv2 behaviour, not a bug.

In IKEv2, PFS for a CHILD_SA requires an explicit Diffie-Hellman exchange: a
`KE` payload inside IKE_AUTH (initial SA) or CREATE_CHILD_SA (rekeying).
When the initiator's ESP proposal list contains BOTH PFS and non-PFS variants,
StrongSwan does not include `KE` in IKE_AUTH. The responder cannot select a
DH-requiring proposal without `KE` present, so it selects the first non-PFS
match -- resulting in `AES_GCM_16_256/NO_EXT_SEQ` for the initial CHILD_SA.

PFS IS applied on rekeying: the CREATE_CHILD_SA exchange includes `KE` with
`modp2048`, and the rekeyed CHILD_SA uses PFS from that point forward. The
`esp_pfs=14` Valkey field is therefore meaningful and enforced -- just not
visible in the initial SA.

To force PFS on the initial CHILD_SA the initiator must send ONLY DH-bearing
proposals and include `KE` in IKE_AUTH. For our use case (responder role)
this is not needed.

IKE phase is unaffected: IKE DH is mandatory and was enforced correctly
(`aes256-sha256-modp2048` accepted, others rejected).

### T1 testing -- IKEv1 + IKEv2 NAT-T on Debian 12 Bookworm (Build Order step 3)

- Client: koi (`swanctl --initiate`), public IP `185.17.205.224`
- Path: koi -> EIP `3.11.124.22` -> LVS DNAT -> VPN node `172.16.50.71`
- IKEv1 Main Mode + NAT-T: established. Phase 1 `AES_CBC_256/HMAC_SHA2_256_128/PRF_HMAC_SHA2_256/MODP_2048`, Phase 2 `ESP:AES_GCM_16_256/NO_EXT_SEQ`
- IKEv2 + NAT-T: established. Same proposals. MOBIKE supported. Initial CURVE_25519 KE rejected with INVAL_KE; koi retried with MODP_2048 and succeeded (expected -- our proposals list only MODP_2048).
- Bypass policies confirmed: no xfrm tunnel policies installed until a tunnel SA is active.

### First successful IKEv1 tunnel (dev test, Ubuntu era)

- Client: koi (`swanctl --initiate --child s2-ikev1-natt`), `185.17.205.224`
- Path: koi → EIP `3.11.124.22` → LVS DNAT → VPN node `172.16.49.23`
- IKE: Main Mode, NAT-T negotiated (switched UDP 500 → UDP 4500 mid-handshake)
- Phase 1 proposal selected: `IKE:AES_CBC_256/HMAC_SHA2_256_128/PRF_HMAC_SHA2_256/MODP_2048`
- Phase 2 proposal selected: `ESP:AES_GCM_16_256/NO_EXT_SEQ`
- Return path confirmed: VPN node reply arrived at koi as `3.11.124.22` (SNAT working)

---

## Open Design Questions

### Return GW floating VIP -- cross-subnet problem

ReturnGW-a and ReturnGW-b eth0 ENIs are in different /27 subnets
(172.16.51.0/27 and 172.16.51.32/27). A floating secondary IP cannot migrate
between subnets.

**Recommended solution (route-table approach):** add `0.0.0.0/0 -> <master-ReturnGW-eth0-ENI>`
to the route table used by backend servers. On failover the notify script
replaces the route's ENI target. No floating IP needed. The `ipsec-gw-vip` tag
is replaced by `ipsec-gw-rtb` (the route table ID to update). This is
consistent with how rtb-vpn is managed.

**Fixed eth0 IPs:** 172.16.51.4 (master) and 172.16.51.36 (backup) -- chosen
in Build Order step 4 and hardcoded into the VPN concentrator FRR config.
The fleetroute AMI (step 7) must assign these as static private IPs on eth0
(specified in the Launch Template or cloud-init). See BGP ASN section above.

### Return GW boot script

The `aerobake/fleetroute` AMI needs to render `keepalived.conf` at boot from
IMDS tags (VRRP unicast peer address differs per node). Options:
- Minimal shell script reading IMDS tags (sufficient for the static two-node case)
- Minimal `fleetpulse` binary (subset of ipsecpulse, no EIP/nftables logic)

### ipsecscale -- not yet implemented

See the design notes in the original `ipsecscale` section. Key points:
- Reads `/run/ipsec-role` each cycle; only master acts
- On promotion to master: immediately rediscover VPN pool via `DescribeInstances`
  and regenerate `ipsec-nat.nft` (backup's file is stale during its standby period)
- Scale-out rehashing: adding one backend reshuffles ~1/(N+1) of source IPs on
  next tunnel re-establishment; mitigate with cooldown periods

### ipsecnode -- Increment 6a+6b complete (T1 passing)

Core functionality working. See "Next Session Starting Point" at the top
of this file for what to implement next (T2, step 5 VPP, Increment 6c/6d).

Key source files:
- `ipsecnode/src/main.rs` -- startup sequence, task orchestration
- `ipsecnode/src/vici.rs` -- VICI commands, `ViciRawValue`, event parsing
- `ipsecnode/src/credentials.rs` -- `SiteRecord`, PSK + conn bulk load, pubsub
- `ipsecnode/src/proposals.rs` -- `OneOrMany<T>`, cartesian-product builders
- `ipsecnode/src/health.rs` -- HTTP :9101
- `ipsecnode/src/aws.rs` -- src/dest check disable via EC2 API

Hook points for 6c and 6d are stubbed in `vici.rs::handle_child_updown()`.
The `peer_ip` (= customer gateway public IP) is already extracted there;
use it to GET `fleetipsec:nat:<peer_ip>` for the device NAT mappings.

---

## Important Cross-References

- aerosuite reference: `~/software/aerosuite/` -- read before writing anything
- aeropulse (model for ipsecpulse): `vendor/aerosuite/aeropulse/src/main.rs`
- aeroscale (model for ipsecscale): `vendor/aerosuite/aeroscale/src/main.rs`
- aeroplug (reused unchanged): `vendor/aerosuite/aeroplug/src/`
- aerocore (shared utilities): `vendor/aerosuite/aerocore/src/`
- Existing nftables (model): `vendor/aerosuite/aerobake/aeroscale/_etc_nftables_aeroscaler.nft`
- Existing sysctl (model): `vendor/aerosuite/aerobake/aeroscale/_etc_sysctl.d_50-aeroscaler.conf`
- Existing keepalived conf (model): `vendor/aerosuite/aerobake/aeroscale/_etc_keepalived_keepalived.conf`
