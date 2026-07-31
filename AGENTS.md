# FleetSuite -- Agent Bootstrap Document

This file summarises the architecture, decisions, and outstanding tasks for the
`fleetsuite` project. Read it in full before making any changes. It is the
authoritative reference for a new agent session picking up this work.

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
    fleetsec/                 <- VPN concentrator AMI (Ubuntu 24.04) -- TODO
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
| Bastion host | `192.168.30.1` port 22 user `rommel` | SSH agent forwarding, both legs |

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

### Security Groups

| Name | ID | Purpose |
|---|---|---|
| FleetShell-IPSec-sg-lvs | `sg-0406887cfe67d8f15` | ESP/IKE from internet; VRRP within self |
| FleetShell-IPSec-sg-vpn | `sg-04dcc0342150eb53b` | IPSec from LVS; BGP from ReturnGW |
| FleetShell-IPSec-sg-returngw | `sg-0516f1d2561c7754d` | BGP from VPN; all from VPC |
| FleetShell-IPSec-sg-management | `sg-053524ea7dcdb64f1` | PostgreSQL from VPN; SSH from CLI_RemoteAccess |

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
                    |  VPN Concentrators (ASG)            |  Ubuntu 24.04
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
| RDS PostgreSQL | Management + ReturnGW-b (Multi-AZ) | StrongSwan SQL plugin: PSK store + connection configs |
| MemoryDB/Valkey | shared (existing) | Half-open IKE SA state, ipsecscale coordination |

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
election. It handles node-local concerns: StrongSwan vici events, VPP VRF
and NAT entry management, FRR /32 route management, ASG lifecycle hooks,
and Prometheus metrics/health endpoints.

### 7. IKEv1 support with `rightid=%any`

StrongSwan is configured with `rightid=%any` to ignore the IKE identity and
look up the PSK by **peer IP address**. PSKs are in the RDS PostgreSQL database
via the StrongSwan SQL plugin.

### 8. Per-tunnel VRF + static 1:1 NAT on VPN concentrators

Every customer tunnel is isolated in its own Linux VRF within VPP. The
existing mapping database (customer device internal IP -> unique globally
routable IP) is loaded as static 1:1 NAT entries in VPP at tunnel-up time.
Return traffic: each unique IP has a `/32` host route advertised via FRR BGP
to the Return GW pair (up to 600,000 entries).

### 9. Ubuntu 24.04 for VPN concentrators, Alpine for everything else

VPP has official `fd.io` apt packages for Ubuntu. Alpine does not have VPP in
apk and building from source is impractical.

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

See the original design notes below for the scale-out sequence and rehashing
behaviour. Not yet implemented.

### `ipsecnode` -- per-node tunnel lifecycle daemon (VPN nodes) -- STUB

Long-running daemon on every VPN concentrator. Handles: StrongSwan vici
tunnel up/down events, VPP VRF + NAT entry management, FRR /32 host routes,
ASG termination lifecycle hooks, Prometheus metrics + health endpoint.

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

### `aerobake/fleetsec/` -- VPN Concentrator (Ubuntu 24.04) -- TODO

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
2. **`aerobake/fleetroute/`** -- Return GW AMI (Alpine): FRR BGP + keepalived.
   See open questions for boot script approach.
3. **`ipsecscale`** -- LVS autoscaling daemon.
4. **`ipsecnode`** -- VPN concentrator per-node daemon.
5. **`aerobake/fleetsec/`** -- VPN concentrator AMI (Ubuntu, most complex).

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
| `make_tag_vip_inside.sh` | Done | `ipsec-vip-inside` ASG tags set (.10 and .40) |
| `make_mgmt_eips.sh` | Done | Management EIPs allocated; `ipsec-mgmt-eip` ASG tags set |

### Pre-created ENIs (must not be deleted)

| ENI name | ENI ID | Subnet | Fixed IP | Tag | Purpose |
|---|---|---|---|---|---|
| `fleetipsec-eni-lvs-mgmt-master` | `eni-0df0c11c6fbc81542` | LVS-mgmt-a (172.16.48.64/28) | 172.16.48.68 | `ipsec-lb-mgmt=master` | eth1 for master LVS node |
| `fleetipsec-eni-lvs-mgmt-backup` | `eni-0c180dfe894914611` | LVS-mgmt-b (172.16.48.80/28) | 172.16.48.84 | `ipsec-lb-mgmt=backup` | eth1 for backup LVS node |
| `fleetipsec-eni-vip-master` | see `aws ec2 describe-network-interfaces --filters Name=tag:ipsec-vip-reservation,Values=master` | LVS-a (172.16.48.0/27) | secondary: 172.16.48.10 | `ipsec-vip-reservation=master` | Holds .10 when not on instance |
| `fleetipsec-eni-vip-backup` | see `aws ec2 describe-network-interfaces --filters Name=tag:ipsec-vip-reservation,Values=backup` | LVS-b (172.16.48.32/27) | secondary: 172.16.48.40 | `ipsec-vip-reservation=backup` | Holds .40 when not on instance |
| `fleetipsec-eni-returngw-mgmt-master` | (create when needed) | ReturnGW-mgmt-a (172.16.51.64/28) | 172.16.51.68 | `ipsec-gw-mgmt=master` | eth1 for master ReturnGW |
| `fleetipsec-eni-returngw-mgmt-backup` | (create when needed) | ReturnGW-mgmt-b (172.16.51.96/28) | 172.16.51.100 | `ipsec-gw-mgmt=backup` | eth1 for backup ReturnGW |

### Launch Template

| Name | ID | Current default | Notes |
|---|---|---|---|
| `fleetipsec-lt-lvs` | `lt-097024e3facf45bd3` | v2+ (check current) | c6in.xlarge (dev), AssociatePublicIpAddress=true, InstanceMetadataTags=enabled |

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

### ipsecnode -- not yet implemented

See the design notes in the original `ipsecnode` section.

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
