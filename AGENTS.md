# FleetSuite — Agent Bootstrap Document

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
  AGENTS.md                   ← this file
  Cargo.toml                  ← Rust workspace (ipsecpulse, ipsecscale, ipsecnode)
  .gitmodules                 ← declares vendor/aerosuite submodule
  vendor/
    aerosuite/                ← git submodule → git@github.com:michaelrommel/aerosuite.git
                                  aerocore and aeroplug are consumed from here via
                                  path dependencies; they are NOT workspace members
                                  (nested workspaces are not supported by Cargo)
  ipsecpulse/                 ← NEW binary (adapted from aerosuite/aeropulse)
  ipsecscale/                 ← NEW binary (ASG orchestration daemon — runs on LVS)
  ipsecnode/                  ← NEW binary (per-node tunnel lifecycle daemon — runs on VPN nodes)

  aerobake/
    fleetscale/               ← IPSec LB AMI   (Alpine, adapted from aeroscale/)
    fleetsec/                 ← VPN concentrator AMI  (Ubuntu 24.04, new)
    fleetroute/               ← Return-path GW AMI    (Alpine, new)
  infrastructure/             ← AWS CLI scripts + their output
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
every dep that aerocore uses — including `sha2`, `hmac`, `hex`,
`serde_urlencoded` — at versions matching aerosuite exactly. If aerosuite adds
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

The two `LVS-mgmt-*` subnets are a **pending** infrastructure action — see
Infrastructure Commands below. They carry the VRRP heartbeat and SSH
management traffic for the LVS nodes on dedicated second NICs (eth1).

### EIPs

| Name | Alloc ID | Public IP |
|---|---|---|
| FleetShell-IPSec-VIP | `eipalloc-095ac59bb763cd2ce` | **3.11.124.22** (customer-facing) |
| FleetShell-IPSec-NatGW | `eipalloc-0ac2fb2dd51415b30` | 35.177.240.42 |

### Route Tables

| Name | ID | Default route | Associations |
|---|---|---|---|
| FleetShell-IPSec-rtb-public | `rtb-0ca8eab40e09c76ae` | `0.0.0.0/0 → igw-0599736bc51a9ac5c` | LVS-a, LVS-b |
| FleetShell-IPSec-rtb-vpn | `rtb-01c3275faa537fcc1` | _added by ipsecpulse/notify-master.sh_ | VPN-a, VPN-b |
| FleetShell-IPSec-rtb-private | `rtb-0540e3736995912c5` | `0.0.0.0/0 → nat-0fb75bf0679751582` | ReturnGW-a, ReturnGW-b, Management, LVS-mgmt-a*, LVS-mgmt-b* |

\* LVS-mgmt and ReturnGW-mgmt subnets associated once created.

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
| RDS PostgreSQL | `fleetshell-ipsec-strongswan` | Engine: PostgreSQL 18.4 (16.3 was unavailable); Multi-AZ; db.t4g.medium |
| RDS subnet group | `fleetshell-ipsec-rds` | Management (AZ-a) + ReturnGW-b (AZ-b) |

---

## Architecture — Full Stack

```
                       Floating EIP  3.11.124.22  (one IP, all customers)
                             │
                    ┌────────▼────────┐
                    │   LVS pair      │  Alpine Linux
                    │   keepalived    │  c6in.4xlarge × 2
                    │   nftables      │  active/standby
                    │   ipsecpulse    │  AZ-a primary, AZ-b standby
                    │   ipsecscale    │  runs on master only
                    └────────┬────────┘
                             │  DNAT: jhash(src_ip) % N
                             │  handles: UDP 500, UDP 4500, proto 50 (raw ESP)
                    ┌────────▼────────────────────┐
                    │  VPN Concentrators (ASG)     │  Ubuntu 24.04
                    │  StrongSwan  IKEv1 + IKEv2   │  c6in.4xlarge
                    │  VPP         data plane       │  3–N instances
                    │  FRR         BGP /32 routes   │  AZ-a + AZ-b
                    │  ipsecnode   per-node daemon  │
                    └────────┬────────────────────┘
                             │  BGP (up to 600k /32 host routes)
                    ┌────────▼────────┐
                    │  Return GW pair │  Alpine Linux
                    │  FRR BGP        │  c6in.2xlarge × 2
                    │  keepalived VIP │  active/standby
                    └────────┬────────┘
                             │  default gateway for backend servers
                    ┌────────▼────────┐
                    │  Backend servers│  any OS
                    └─────────────────┘
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
IKE and ESP from the same customer can land on different VPN concentrators —
breaking the IPSec SA. A large fraction of the installed customer base cannot
be forced to use NAT-T (UDP 4500 encapsulation), so raw ESP must be handled.

LVS with nftables `jhash ip saddr` hashes on source IP only, giving identical
routing decisions for UDP 500, UDP 4500, and proto 50 from the same customer.

### 2. Two NICs on LVS nodes — data plane and management/heartbeat separated

Each LVS node has two ENIs:

- **eth0** — public subnet (LVS-a or LVS-b). Carries all customer ESP/IKE
  traffic. The EIP is associated to the primary private IP of this ENI on
  the master node. Each LVS node has a different primary IP (AZ-a: 172.16.48.x,
  AZ-b: 172.16.48.3x); the EIP re-associates on failover.
- **eth1** — management subnet (LVS-mgmt-a or LVS-mgmt-b, PRIVATE). Carries
  VRRP unicast heartbeat and SSH only.

Rationale: at 25,000 tunnels with IKE keepalives and DPD traffic, eth0 can
sustain high PPS bursts. VRRP packets (84 bytes each) competing on the same
RX ring risk being dropped during a burst, which would trigger a spurious
failover. A dedicated eth1 gives:
- Independent RX/TX ring buffers and interrupt vectors for each traffic class.
- CPU interrupt affinity can pin eth0 IRQs to data-plane cores and eth1 IRQs
  to a control-plane core, keeping heartbeat latency stable under load.
- SSH remains responsive even when eth0 is under heavy load.

This is different from aeroftp (which needed three NICs: public, IPVS-backend
GW, and VXLAN sync). Here eth1 serves only heartbeat + management — no VXLAN,
no IPVS backend subnet requirement.

### 3. No VXLAN / no IPVS connection sync on the LVS nodes

The IPSec LB uses **stateless** nftables DNAT: `jhash(src_ip) % N` is a
pure function with no per-connection memory. Any node computes the same
answer, so the new master routes identically to the old one with no sync.
IPSec session state lives on the VPN concentrators, not on the LB.
IPSec DPD tolerates the ~5–10 s EIP re-association window.

### 4. Single NIC on LVS nodes for data plane (no eth2 VXLAN)

aeroftp needs eth2 for VXLAN connection-state sync because IPVS tracks
per-connection state and that state must survive failover. No such requirement
exists here — see decision #3 above.

### 5. ipsecscale runs on the LVS master, not on VPN concentrators

The autoscaling daemon follows the same pattern as aeroscale in aeroftp: it
runs exclusively on whichever LVS node currently holds the master role.
Keepalived's `notify-master.sh` starts ipsecscale; `notify-backup.sh` stops
it. This gives a single active decision-maker for ASG scale-in/out without
any distributed consensus mechanism.

ipsecscale on the LVS master is responsible for:
- Monitoring VPN concentrator health (via CloudWatch / direct health probe).
- Deciding when to add or remove VPN concentrator instances from the ASG.
- Updating the nftables backend pool when the VPN instance list changes.
- Updating the `rtb-vpn` default route (`0.0.0.0/0 → eth0 ENI of master LVS`)
  when LVS failover occurs or the VPN pool changes.

### 6. ipsecnode is a separate per-node daemon on VPN concentrators

Each VPN concentrator runs `ipsecnode` independently. It handles node-local
concerns that have nothing to do with fleet-level scaling:
- StrongSwan vici event subscription (tunnel up/down → provision/deprovision).
- VPP VRF creation + static 1:1 NAT entry management.
- FRR /32 host route management (redistributed into BGP).
- ASG `EC2_INSTANCE_TERMINATING` lifecycle hook handling (graceful drain).
- Prometheus `/metrics` (port 9090) and `/health` endpoints.

### 7. IKEv1 support with `rightid=%any`

A large fraction of the installed customer base runs older CPE firmware that
places the CPE's inside interface IP in the IKE identity payload, and many
customers share the same identity value. StrongSwan is configured with
`rightid=%any` to ignore the identity and look up the PSK by **peer IP address**
(which is unique per customer in the non-CGN case). PSKs are in the RDS
PostgreSQL database via the StrongSwan SQL plugin.

### 8. Per-tunnel VRF + static 1:1 NAT on VPN concentrators

Every customer tunnel is isolated in its own Linux VRF within VPP. The
existing mapping database (customer device internal IP → unique globally
routable IP) is loaded as **static 1:1 NAT entries** in VPP at tunnel-up time.
Return traffic: each unique IP has a `/32` host route advertised via FRR BGP
to the Return GW pair (up to 600,000 entries).

### 9. Ubuntu 24.04 for VPN concentrators, Alpine for everything else

VPP has official `fd.io` apt packages for Ubuntu. Alpine does not have VPP in
apk and building from source is impractical.

### 10. Shared MemoryDB (Valkey) cluster

The existing `dev-valkey-aeroftp` cluster is reused with key prefix
`fleetipsec:`. The VPN concentrator SG (`sg-04dcc0342150eb53b`) has been added
to the MemoryDB cluster. Valkey stores half-open IKE SA state (TTL 30 s) as a
safety net for the rare case where IKE_SA_INIT and IKE_AUTH arrive at different
VPN nodes during a hash boundary event.

### 11. Genuine cross-AZ design — each HA node owns its AZ end-to-end

Every component is pinned to its own AZ for both its data-plane NIC (eth0)
and its management/heartbeat NIC (eth1):

- LVS master: eth0 in LVS-a (AZ-a), eth1 in LVS-mgmt-a (AZ-a)
- LVS backup: eth0 in LVS-b (AZ-b), eth1 in LVS-mgmt-b (AZ-b)
- Return GW master: eth0 in ReturnGW-a (AZ-a), eth1 in ReturnGW-mgmt-a (AZ-a)
- Return GW backup: eth0 in ReturnGW-b (AZ-b), eth1 in ReturnGW-mgmt-b (AZ-b)

This differs deliberately from the aeroftp design, where both LB nodes' inside
and sync ENIs share a single AZ-b subnet. That made aeroftp implicitly
single-AZ for its control plane.

Consequences:

**VRRP unicast works cross-AZ without any special plumbing.** Proto 112 packets
between 172.16.48.68 (AZ-a) and 172.16.48.84 (AZ-b) are ordinary VPC inter-
subnet L3 traffic; no EIP, no overlay, no floating IP is required for the
heartbeat path.

**An AZ failure takes out exactly one node end-to-end.** If AZ-a fails, the
master LVS node loses both eth0 and eth1 simultaneously; the backup detects
heartbeat loss on its own (AZ-b) eth1 and transitions to MASTER cleanly.
The converse holds for AZ-b failure.

**No additional EIPs are needed.** EIPs are regional, not AZ-scoped. The
single customer-facing EIP (`eipalloc-095ac59bb763cd2ce`, 3.11.124.22)
re-associates to whichever node becomes MASTER via `ec2:AssociateAddress`
regardless of AZ. The same applies to any future Return GW EIP if the
route-table VIP approach (Decision #11 open question) is not chosen.

**`ipsec-vip-inside` (floating secondary private IP) is incompatible with
cross-AZ** and is dropped from the design. `AssignPrivateIpAddresses` is
subnet-scoped; a secondary IP from the LVS-a /27 cannot be assigned to the
LVS-b /27 ENI. The SNAT source IP in nftables is instead derived from
`/latest/meta-data/local-ipv4` at boot (the master's current eth0 primary IP)
and written into `/etc/nftables.d/ipsec-nat.nft` by ipsecpulse.

**Return GW VIP** faces the same subnet-scoping constraint (ReturnGW-a and
ReturnGW-b eth0 ENIs are in different /27 subnets). The route-table approach
is the correct solution: `0.0.0.0/0 → <master-ReturnGW-eth0-ENI>` in the
backend servers' route table, updated on failover. See open question in the
Pending Infrastructure section.

---

## Binaries

### Shared from aerosuite — via git submodule at `vendor/aerosuite`

These are consumed as path dependencies, **not** modified. If a change is
needed, make it in aerosuite, push, then bump the submodule pin in fleetsuite.

| Crate | Path | Purpose |
|---|---|---|
| `aerocore` | `vendor/aerosuite/aerocore` | AWS API, IMDS, credential helpers |
| `aeroplug` | `vendor/aerosuite/aeroplug` | ENI attach/detach; secondary IP assign/unassign |

### New binaries

#### `ipsecpulse` — boot-time config generator (LVS nodes)

Adapt from `aerosuite/aeropulse`. Runs at instance boot before keepalived
starts. Queries EC2 API and generates:

- `/etc/keepalived/vrrp.conf` — unicast VRRP on **eth1** (management NIC)
- `/etc/keepalived/notify-master.sh` — calls `aws ec2 associate-address` to
  move the EIP to this node's eth0 ENI (primary IP); writes the primary IP
  into `/etc/nftables.d/ipsec-nat.nft` as the SNAT source; reloads nftables;
  then updates `rtb-vpn` (`0.0.0.0/0 → eth0 ENI ID`) via EC2 API; then starts
  `ipsecscale`
- `/etc/keepalived/notify-backup.sh` — stops `ipsecscale`; no-op otherwise
- `/etc/nftables.d/ipsec-dnat.nft` — jhash DNAT rules with current VPN node
  list fetched from the ASG

EC2 instance tags required:
```
ipsec-lb-role       "master" | "backup"
ipsec-lb-cluster    shared value for both LB nodes (e.g. "fleetipsec-lb")
ipsec-vip-outside   EIP allocation ID  (eipalloc-095ac59bb763cd2ce)
ipsec-lb-peer-mgmt-ip  peer's eth1 fixed IP for VRRP unicast
                        master ASG: 172.16.48.84 (lvs-mgmt-b)
                        backup ASG: 172.16.48.68 (lvs-mgmt-a)
ipsec-vpn-asg       name of the VPN concentrator ASG
ipsec-rtb-vpn       route table ID for VPN subnets  (rtb-01c3275faa537fcc1)
```
Note: `ipsec-vip-inside` (floating secondary private IP) has been removed from
the design. Secondary private IPs are subnet-scoped and cannot migrate between
LVS-a (172.16.48.0/27) and LVS-b (172.16.48.32/27). The EIP is associated
directly to the master's eth0 primary IP; the SNAT source is derived from
IMDS `local-ipv4` at boot. See Architecture Decision #11.

#### `ipsecscale` — autoscaling daemon (LVS master only)

Long-running daemon on whichever LVS node currently holds the master role.
Started/stopped by keepalived notify scripts (see ipsecpulse above).
Analogous to `aeroscale` in aeroftp.

Responsibilities:
1. **Backend pool management** — polls ASG and VPN health endpoints; updates
   nftables with the current healthy VPN node list; rewrites
   `/etc/nftables.d/ipsec-nat.nft` and reloads the nat table.
2. **ASG scaling decisions** — monitors aggregate tunnel count and per-node
   load; calls EC2 `SetDesiredCapacity` when thresholds are breached.
3. **rtb-vpn maintenance** — when the master changes (ipsecpulse notify-master
   already sets the initial route), ipsecscale also updates the route on any
   subsequent eth0 ENI change (e.g. instance replacement).
4. **Coordination via Valkey** — key prefix `fleetipsec:scale:`.

**Scale-out sequence (reference for implementation):**

```
1. ipsecscale detects load threshold exceeded
2. SetDesiredCapacity(N+1) on fleetipsec-vpn ASG
3. New VPN concentrator boots; ipsecnode starts; /health returns 200
4. ipsecscale polls until new instance is InService AND health probe passes
5. Regenerate /etc/nftables.d/ipsec-nat.nft with N+1 backends; reload nat table:
     nft flush table ip nat
     nft -f /etc/nftables.d/ipsec-nat.nft
   (flush + reload only the nat table — filter table is unaffected)
6. New IKE negotiations distribute across N+1 backends
   Existing ESP SAs continue via conntrack — no disruption
```

**The rehashing problem:** when the pool grows from N to N+1, the modulo
changes and approximately 1/(N+1) of all source IPs hash to a different
backend. Existing tunnels are transparent (conntrack maintains the mapping)
but tunnels that re-establish (DPD, rekey) will land on a potentially new
concentrator. At 25,000 tunnels, adding one backend reshuffles ~6 % on next
re-establishment (~1,500 tunnels briefly reconnecting). This is acceptable;
mitigate by scaling out before load is critical and enforcing a cooldown after
each scale event before re-evaluating thresholds.

Long-term improvement: replace `mod N` with rendezvous / Maglev hashing so
that adding a backend only remaps the minimum 1/(N+1) fraction rather than a
modulo-boundary-dependent set. This is a ipsecscale implementation detail;
the nftables file format (inline anonymous map) supports it without changes.

**Startup behaviour (critical for failover correctness):** when ipsecscale
starts on a newly promoted MASTER node, it must **immediately** rediscover the
current VPN pool via `DescribeInstances` and regenerate `ipsec-nat.nft` before
entering the monitoring loop. This ensures the new master's nftables reflects
any pool changes that occurred while it was the backup (scale events are only
applied to the master's nftables; the backup's file is stale until it promotes).

#### `ipsecnode` — per-node tunnel lifecycle daemon (VPN concentrators)

Long-running daemon on every VPN concentrator. Handles node-local concerns
only; runs identically on every node without any leader election.

Responsibilities:
1. **Tunnel lifecycle** — subscribes to StrongSwan vici events:
   - `child-updown INSTALLED`: query RDS for customer device mappings →
     provision VPP VRF + static NAT entries → add FRR /32 routes →
     write half-open state to Valkey (`fleetipsec:hastate:<peer_ip>`)
   - `child-updown CLOSED`: reverse all of the above
2. **ASG lifecycle hooks** — handles `autoscaling:EC2_INSTANCE_TERMINATING`:
   send StrongSwan DELETE for all SAs, drain VPP, withdraw BGP routes,
   complete lifecycle hook via EC2 API
3. **Metrics** — Prometheus `/metrics` on port 9090: active tunnels, VRF
   count, NAT entry count, BGP route count
4. **Health** — `/health` for ASG target group / ipsecscale health probes

Environment / config (`/etc/conf.d/ipsecnode`):
```
VALKEY_URL      rediss://clustercfg.dev-valkey-aeroftp.ak121m.memorydb.eu-west-2.amazonaws.com:6379
DB_URL          postgres://strongswan:<pass>@<rds-endpoint>:5432/strongswan
REGION          eu-west-2
VPN_ASG_NAME    fleetipsec-vpn
CLOUDWATCH_NS   FleetIPSec
```

---

## Packer AMIs

### `aerobake/fleetscale/` — IPSec LB (Alpine)

Base: copy of `aerobake/aeroscale/aeroscale.pkr.hcl`, renamed
`fleetscale.pkr.hcl`.

**NIC layout change vs aeroscale:**
- eth0: public NIC — data plane, EIP (associated to primary IP on MASTER transition)
- eth1: management NIC (LVS-mgmt-a/b subnet) — VRRP heartbeat + SSH

**Remove** from aeroscale skeleton:
- `ipvsadm` package
- `_etc_modules-load.d_keepalived.conf` (ip_vs_* modules)
- `aeroscale` binary and its init.d/conf.d/logrotate
- eth2 / VXLAN references in nftables and sysctl

**Replace**:
- `_etc_nftables_aeroscaler.nft` → `_etc_nftables_fleetscale.nft`
  (proto 50 + UDP 500 + UDP 4500 jhash DNAT; stateless SNAT for return path)
- `_etc_sysctl.d_50-aeroscaler.conf` → remove IPVS/FTP tuning, keep
  forwarding + conntrack; add `nf_conntrack_proto_esp` tuning
- `_etc_keepalived_keepalived.conf` → VRRP on eth1 (not eth0); remove all
  virtual_server blocks; keep `include` stubs for vrrp.conf and backends.conf

**Add**:
- `ipsecpulse` binary (built from `fleetsuite/ipsecpulse`)
- `ipsecscale` binary (built from `fleetsuite/ipsecscale`)
- `aeroplug` binary (from `vendor/aerosuite/aeroplug`)
- `_etc_init.d_ipsecpulse` — OpenRC service, runs before keepalived
- `_etc_init.d_ipsecscale` — OpenRC service, started by notify-master.sh

### `aerobake/fleetsec/` — VPN Concentrator (Ubuntu 24.04)

New packer script. Key packages:
```
strongswan  libcharon-extra-plugins  strongswan-pki
libstrongswan-extra-plugins  strongswan-plugin-eap-mschapv2
vpp  vpp-plugin-dpdk  vpp-plugin-nat  vpp-plugin-crypto-openssl
frr
prometheus-node-exporter
ipsecnode   (built from fleetsuite/ipsecnode)
aeroplug    (built from vendor/aerosuite/aeroplug)
```

StrongSwan configuration:
- `/etc/strongswan.d/charon-sql.conf` — SQL plugin, PostgreSQL DSN
- `/etc/ipsec.conf` skeleton with `rightid=%any`, `keyexchange=ike`
- `/etc/strongswan.d/charon.conf` — raise `cookie_threshold` for CGN

VPP startup config:
- DPDK on ENA (`dev 0000:xx:xx.x` discovered at boot via sysfs)
- `nat44` plugin enabled
- Unix socket for VPP API (used by ipsecnode)

FRR config:
- BGP router, peering with Return GW nodes
- `redistribute static` to pick up /32 host routes added by ipsecnode

### `aerobake/fleetroute/` — Return GW (Alpine)

Minimal Alpine AMI:
- `frr` (BGP only), `keepalived` (VIP for backend default gateway), `iproute2`,
  `prometheus-node-exporter`
- Two NICs: eth0 (ReturnGW-a/b subnet) for BGP + data forwarding; eth1
  (ReturnGW-mgmt-a/b subnet) for VRRP heartbeat + SSH. Same rationale as LVS:
  a spurious Return GW failover drops return traffic for all customers
  simultaneously, so heartbeat must be isolated from data-plane RX pressure.
- keepalived VRRP configured on eth1 (unicast between the two nodes)
- Sysctl: `net.ipv4.ip_forward=1`, large FIB tuning for 600k routes
- No custom Rust binaries needed

FRR BGP peers: all VPN concentrators (addresses from ASG at deploy time,
written into `/etc/frr/frr.conf`).

---

## StrongSwan SQL Schema

Database: `strongswan` on RDS instance `fleetshell-ipsec-strongswan`
(PostgreSQL 18.4).

Core StrongSwan tables (from `/usr/share/doc/strongswan/examples/stroke/sql/sqlite.sql`,
adapted to PostgreSQL):
```
identities          peer identity records
ike_configs         IKE proposal + addressing (right=%any, local addr)
peer_configs        per-connection config (rightid=%any, keyexchange=ike)
child_configs       child SA / traffic selector config
shared_secrets      PSK per peer IP: (type='PSK', identity=<peer_ip>)
```

Application tables written by `ipsecnode`:
```
tunnel_assignments   (customer_id, vpn_node_ip, vrf_id, created_at)
device_mappings      (customer_id, internal_ip, unique_ip)
```
`device_mappings` is pre-populated from the existing concentrator export.

---

## nftables Rules for the LVS Nodes

File: `aerobake/fleetscale/_etc_nftables_fleetscale.nft`

```
Inbound DNAT (PREROUTING):
  ip protocol udp  udp dport 500   → jhash ip saddr mod N → VPN node
  ip protocol udp  udp dport 4500  → jhash ip saddr mod N → VPN node
  ip protocol 50                   → jhash ip saddr mod N → VPN node

Return SNAT (POSTROUTING):
  oifname "eth0" ip protocol 50  snat to <eth0-primary-ip>
  oifname "eth0" ip protocol udp snat to <eth0-primary-ip>
  Stateless — no conntrack dependency.
  <eth0-primary-ip> = master node's eth0 primary IP, read from IMDS local-ipv4
  at boot by ipsecpulse and written into /etc/nftables.d/ipsec-nat.nft.
  The EIP is associated directly to this primary IP on MASTER transition.
  (A floating secondary private IP cannot cross the LVS-a/LVS-b subnet
  boundary — see Architecture Decision #11.)

Filter (INPUT on eth0):
  Allow: icmp, lo, established/related
  Allow: UDP 500, UDP 4500, proto 50 from 0.0.0.0/0
  Reject everything else.

Filter (INPUT on eth1):
  Allow: TCP 22 from CLI_RemoteAccess SG range
  Allow: proto 112 (VRRP) from peer LVS node
  Allow: icmp, lo, established/related
  Reject everything else.
```

The eth0 primary IP and VPN node list are written into
`/etc/nftables.d/ipsec-nat.nft` by `ipsecpulse` at boot (complete nat table
with inline anonymous maps; updated by `ipsecscale` when the pool changes).

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

Implement in this sequence:

1. **`ipsecpulse`** — boot-time config generator for LVS nodes
2. **`aerobake/fleetscale/`** — LVS AMI (Alpine): config files, nftables, 2-NIC keepalived
3. **`aerobake/fleetroute/`** — Return GW AMI (Alpine): minimal FRR + keepalived
4. **`ipsecscale`** — LVS autoscaling daemon
5. **`ipsecnode`** — VPN concentrator per-node daemon
6. **`aerobake/fleetsec/`** — VPN concentrator AMI (Ubuntu, most complex)

---

## Infrastructure Commands (reference — operator executes)

All prior steps (subnets, EIPs, route tables, security groups, NAT GW, RDS,
route table associations) have been executed. Results are in `infrastructure/`.

### Pending: management/heartbeat subnets (LVS and Return GW)

Both the LVS nodes and the Return GW nodes use a two-NIC layout:
- **eth0** — data-plane NIC (existing public/private subnet)
- **eth1** — management NIC (new subnet below) — VRRP heartbeat + SSH only

Rationale for both node types: VRRP heartbeat packets (84 bytes, proto 112)
must not compete with data-plane traffic on the same RX ring. A spurious
failover on either pair drops all customer traffic. The Return GW VIP is the
default gateway for all backend servers, making its heartbeat equally critical
to protect. All four subnets below are associated with `rtb-private` (NAT GW
for outbound). Execute all four creates first, then all four associations.

```bash
# ── LVS management — eth1 for LVS nodes ──────────────────────────────────

# AZ-a (eth1 for LVS-a node)
aws ec2 create-subnet \
  --vpc-id vpc-0595e17ce290fb050 \
  --cidr-block 172.16.48.64/28 \
  --availability-zone eu-west-2a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=FleetShell-IPSec-LVS-mgmt-a}]'

# AZ-b (eth1 for LVS-b node)
aws ec2 create-subnet \
  --vpc-id vpc-0595e17ce290fb050 \
  --cidr-block 172.16.48.80/28 \
  --availability-zone eu-west-2b \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=FleetShell-IPSec-LVS-mgmt-b}]'

# ── Return GW management — eth1 for Return GW nodes ──────────────────────

# AZ-a (eth1 for ReturnGW-a node)
aws ec2 create-subnet \
  --vpc-id vpc-0595e17ce290fb050 \
  --cidr-block 172.16.51.64/28 \
  --availability-zone eu-west-2a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=FleetShell-IPSec-ReturnGW-mgmt-a}]'

# AZ-b (eth1 for ReturnGW-b node)
aws ec2 create-subnet \
  --vpc-id vpc-0595e17ce290fb050 \
  --cidr-block 172.16.51.96/28 \
  --availability-zone eu-west-2b \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=FleetShell-IPSec-ReturnGW-mgmt-b}]'

# ── Associate all four new subnets with rtb-private ───────────────────────

aws ec2 associate-route-table \
  --route-table-id rtb-0540e3736995912c5 \
  --subnet-id subnet-049c91ca98e7d3637

aws ec2 associate-route-table \
  --route-table-id rtb-0540e3736995912c5 \
  --subnet-id subnet-07da62f2872b072b7

aws ec2 associate-route-table \
  --route-table-id rtb-0540e3736995912c5 \
  --subnet-id subnet-063a83cf5653196c7

aws ec2 associate-route-table \
  --route-table-id rtb-0540e3736995912c5 \
  --subnet-id subnet-0ee35e39252ccf95a
```

### Deferred: rtb-vpn default route

The `0.0.0.0/0` route in `rtb-vpn` points to the eth0 ENI of whichever LVS
node is currently master. It cannot be created until after the first LVS node
boots and `ipsecpulse` associates the EIP to the master's eth0 primary IP. It is set
automatically by `ipsecpulse`'s `notify-master.sh` script:

```bash
aws ec2 create-route \
  --route-table-id rtb-01c3275faa537fcc1 \
  --destination-cidr-block 0.0.0.0/0 \
  --network-interface-id <eni-id-of-master-lvs-eth0>
```

On subsequent LVS failovers, `ipsecscale` replaces this route with the new
master's ENI ID using `aws ec2 replace-route`.

---

## Pending: Launch Templates, Autoscaling Groups, and Instance Tags

### Pre-created management ENIs (4 — must exist before first boot)

LVS and Return GW nodes each have two NICs. The management NIC (eth1) is in
a dedicated private subnet for VRRP heartbeat and SSH. Because each ASG is
single-AZ, its eth0 subnet is already AZ-pinned by the ASG subnet
configuration. Keeping **one Launch Template per node type** (rather than one
per AZ) requires eth1 to be attached at boot rather than baked into the LT
network interface block.

**Established pattern (aeroftp reference):** the aeroftp project uses exactly
this approach. Its four pre-created ENIs follow a consistent convention:

| aeroftp ENI | ENI ID | Subnet | Fixed IP | Tag |
|---|---|---|---|---|
| LB primary inside (eth1) | `eni-0dfcf7192df724525` | AeroFTP-lb-internal (172.16.32.0/26, AZ-b) | 172.16.32.15 | `aeroftp-lb=master` |
| LB backup inside (eth1) | `eni-01d3d24e8bca6d1c4` | AeroFTP-lb-internal (172.16.32.0/26, AZ-b) | 172.16.32.16 | `aeroftp-lb=backup` |
| LB master sync (eth2) | `eni-0efb904624f53dd78` | AeroFTP-lb-sync (172.16.32.128/26, AZ-b) | 172.16.32.135 | `aeroftp-lb-sync=master` |
| LB backup sync (eth2) | `eni-0d51669319c208e0f` | AeroFTP-lb-sync (172.16.32.128/26, AZ-b) | 172.16.32.136 | `aeroftp-lb-sync=backup` |

Key observations:
- **Both** master and backup ENIs share the **same subnet** — a single
  control-plane subnet, AZ-b only. AZ isolation of the heartbeat is not a
  goal; isolating heartbeat traffic from data-plane RX pressure is.
- **Single tag key, role as value**: `aeroftp-lb=master` / `aeroftp-lb=backup`.
  At boot, aeropulse calls `aeroplug eni --tag aeroftp-lb=master --attach`
  (substituting the role it read from its own IMDS tag). No multi-tag
  conjunction needed.
- **Fixed consecutive IPs** (.15/.16, .135/.136) are known in advance and
  stored as instance tags (`keepalived-peer-sync`) on the opposite node so
  the peer address for VRRP unicast is available from IMDS without an EC2
  API call.

Apply the same pattern for fleetsuite, **but with one critical difference**: each
node's management ENI must be in its **own AZ subnet** (not a shared single-AZ
subnet as aeroftp uses). This is what makes the design genuinely cross-AZ:

- If AZ-a fails: the master LVS node loses both eth0 and eth1. The backup node's
  eth1 is in AZ-b (still up), it detects heartbeat loss, and transitions to
  MASTER. ✓
- If AZ-b fails: the backup node loses both eth0 and eth1. The master's eth1 is
  in AZ-a (still up) and continues operating as MASTER. ✓

VRRP unicast between 172.16.48.68 (AZ-a) and 172.16.48.84 (AZ-b) is plain IP
(proto 112). VPC inter-subnet L3 routing handles it automatically — no EIP,
no floating IP, no tunnel required.

Aeroftp's single-AZ-only management subnets were an accepted limitation;
fleetsuite's subnet layout (with AZ-specific `*-mgmt-a` and `*-mgmt-b` subnets
already created) was already designed to avoid this.

| ENI name | Subnet | AZ | Fixed IP | Tag |
|---|---|---|---|---|
| `fleetipsec-eni-lvs-mgmt-master` | LVS-mgmt-a `subnet-049c91ca98e7d3637` (172.16.48.64/28) | AZ-a | 172.16.48.68 | `ipsec-lb-mgmt=master` |
| `fleetipsec-eni-lvs-mgmt-backup` | LVS-mgmt-b `subnet-07da62f2872b072b7` (172.16.48.80/28) | AZ-b | 172.16.48.84 | `ipsec-lb-mgmt=backup` |
| `fleetipsec-eni-returngw-mgmt-master` | ReturnGW-mgmt-a `subnet-063a83cf5653196c7` (172.16.51.64/28) | AZ-a | 172.16.51.68 | `ipsec-gw-mgmt=master` |
| `fleetipsec-eni-returngw-mgmt-backup` | ReturnGW-mgmt-b `subnet-0ee35e39252ccf95a` (172.16.51.96/28) | AZ-b | 172.16.51.100 | `ipsec-gw-mgmt=backup` |

At boot, ipsecpulse reads its own `ipsec-lb-role` IMDS tag and calls:
```
aeroplug eni --tag ipsec-lb-mgmt=<role> --attach
```

SG for all four management ENIs: `sg-011b3ebfcfbcca22d` (`CLI_RemoteAccess`)
plus the relevant node SG (`sg-lvs` or `sg-returngw`) for VRRP proto 112.

---

### Launch Templates (3)

Each LT must have `MetadataOptions → InstanceMetadataTags = enabled` so
ipsecpulse / ipsecnode can read tags from IMDS at boot.

Network interfaces in the LT specify **eth0 only**; eth1 is attached at boot
by the init script (see pre-created management ENIs above). For the VPN
concentrator LT, only eth0 is ever present; the ASG subnet config spans both
VPN-a and VPN-b.

| Name | AMI source | Instance type | eth0 SG(s) | Notes |
|---|---|---|---|---|
| `fleetipsec-lt-lvs` | aerobake/fleetscale | c6in.4xlarge | `sg-lvs` + `CLI_RemoteAccess` | eth1 attached at boot from pre-created ENI |
| `fleetipsec-lt-vpn` | aerobake/fleetsec | c6in.4xlarge | `sg-vpn` + `CLI_RemoteAccess` | single NIC; ASG spans VPN-a + VPN-b |
| `fleetipsec-lt-returngw` | aerobake/fleetroute | c6in.2xlarge | `sg-returngw` + `CLI_RemoteAccess` | eth1 attached at boot from pre-created ENI |

All three LTs must attach an **IAM instance profile** with at minimum:

- `ec2:DescribeInstances`, `ec2:DescribeNetworkInterfaces`
- `ec2:AssignPrivateIpAddresses`, `ec2:UnassignPrivateIpAddresses` (aeroplug ip)
- `ec2:AttachNetworkInterface`, `ec2:DetachNetworkInterface` (aeroplug eni)
- `ec2:AssociateAddress`, `ec2:DisassociateAddress` (EIP for LVS master)
- `ec2:CreateRoute`, `ec2:ReplaceRoute` (rtb-vpn management by ipsecpulse / ipsecscale)
- `autoscaling:DescribeAutoScalingGroups`, `autoscaling:SetDesiredCapacity` (ipsecscale)
- `autoscaling:CompleteLifecycleAction`, `autoscaling:RecordLifecycleActionHeartbeat` (ipsecnode drain)
- `cloudwatch:PutMetricData` (ipsecscale + ipsecnode)
- Connect to MemoryDB cluster (done via SG membership; no IAM permission needed)

---

### Autoscaling Groups (5)

The four HA-node ASGs are each **single-AZ and single-subnet** so that a
replacement instance always lands in the same AZ and can attach the correct
pre-created management ENI. The VPN concentrator ASG spans both VPN subnets.

| ASG name | LT | Min | Max | eth0 Subnet | Purpose |
|---|---|---|---|---|---|
| `fleetipsec-lvs-master` | `fleetipsec-lt-lvs` | 1 | 2 | LVS-a `subnet-0fe6d05bc51c16ed8` | LVS primary (AZ-a) |
| `fleetipsec-lvs-backup` | `fleetipsec-lt-lvs` | 1 | 2 | LVS-b `subnet-071e009038ce73f87` | LVS standby (AZ-b) |
| `fleetipsec-returngw-master` | `fleetipsec-lt-returngw` | 1 | 2 | ReturnGW-a `subnet-017d5b3a6331e26a7` | Return GW primary (AZ-a) |
| `fleetipsec-returngw-backup` | `fleetipsec-lt-returngw` | 1 | 2 | ReturnGW-b `subnet-082703ab573f0f4e9` | Return GW standby (AZ-b) |
| `fleetipsec-vpn` | `fleetipsec-lt-vpn` | 1 | 50 | VPN-a `subnet-05a86c0fe6eec7b10` + VPN-b `subnet-0ab2ba73e9b587e2e` | VPN concentrators |

**Why one ASG per HA node (not one per pair)?**  The `ipsec-lb-role` /
`ipsec-gw-role` tags must differ between the primary and standby nodes. ASG
instance tags propagate uniformly to every instance in the group — you cannot
vary a tag within a single ASG. One ASG per node makes the role tag static and
deterministic at boot without any per-instance bootstrap logic.

---

### Instance Tags

All tags below are set on the **ASG** with `PropagateAtLaunch = true`; they
are then readable from IMDS by ipsecpulse / ipsecnode (requires
`InstanceMetadataTags = enabled` in the LT).

#### LVS nodes — read by ipsecpulse at boot

| Tag | `fleetipsec-lvs-master` | `fleetipsec-lvs-backup` | Notes |
|---|---|---|---|
| `ipsec-lb-role` | `master` | `backup` | Sets VRRP priority; drives notify script behaviour |
| `ipsec-lb-cluster` | `fleetipsec-lb` | `fleetipsec-lb` | Shared label for DescribeInstances peer lookup |
| `ipsec-vip-outside` | `eipalloc-095ac59bb763cd2ce` | `eipalloc-095ac59bb763cd2ce` | EIP alloc ID; master calls `ec2:AssociateAddress` targeting the node's eth0 primary IP on MASTER transition |
| ~~`ipsec-vip-inside`~~ | ~~dropped~~ | ~~dropped~~ | **Removed** — floating secondary private IPs are subnet-scoped and cannot cross LVS-a/LVS-b AZ boundary. SNAT source = IMDS `local-ipv4` at boot. See Architecture Decision #11. |
| `ipsec-lb-peer-mgmt-ip` | `172.16.48.84` (lvs-mgmt-b, AZ-b) | `172.16.48.68` (lvs-mgmt-a, AZ-a) | Peer's eth1 fixed IP (from pre-created ENI); used for VRRP unicast peer address in keepalived.conf. Analogous to `keepalived-peer-sync` in aeroftp. |
| `ipsec-vpn-asg` | `fleetipsec-vpn` | `fleetipsec-vpn` | VPN concentrator ASG name used by ipsecscale |
| `ipsec-rtb-vpn` | `rtb-01c3275faa537fcc1` | `rtb-01c3275faa537fcc1` | Route table updated by ipsecpulse notify-master |

#### Return GW nodes — read by the keepalived boot script

| Tag | `fleetipsec-returngw-master` | `fleetipsec-returngw-backup` | Notes |
|---|---|---|---|
| `ipsec-gw-role` | `master` | `backup` | Sets VRRP priority |
| `ipsec-gw-cluster` | `fleetipsec-gw` | `fleetipsec-gw` | Shared label for peer lookup |
| `ipsec-gw-vip` | ⚠ see open question below | ⚠ see open question below | Floating VIP used as default gateway by backend servers |
| `ipsec-gw-peer-mgmt-ip` | `172.16.51.100` (returngw-mgmt-b, AZ-b) | `172.16.51.68` (returngw-mgmt-a, AZ-a) | Peer's eth1 fixed IP; used for VRRP unicast. Analogous to `keepalived-peer-sync` in aeroftp. |

#### VPN concentrators — no IMDS tags needed

ipsecnode reads its configuration from `/etc/conf.d/ipsecnode` (baked into the
AMI). No IMDS instance tags are required.

---

### Open Design Questions (resolve before implementing ipsecpulse)

#### ~~`ipsec-vip-inside`~~ — resolved, dropped from design

This was an open question. It is now resolved as Architecture Decision #11:
floating secondary private IPs are subnet-scoped; they cannot migrate between
LVS-a (172.16.48.0/27, AZ-a) and LVS-b (172.16.48.32/27, AZ-b). The EIP is
associated directly to the master's eth0 primary IP. The SNAT source is written
into `/etc/nftables.d/ipsec-nat.nft` from IMDS `local-ipv4` at boot by
ipsecpulse. The `ipsec-vip-inside` instance tag is not used.

#### ⚠ Return GW floating VIP — cross-subnet problem

The same subnet-scoping issue applies: Return GW-a and Return GW-b eth0 ENIs
are in different /27 subnets (172.16.51.0/27 and 172.16.51.32/27).

Options:
1. **Route-table approach** (recommended, consistent with rtb-vpn pattern):
   add `0.0.0.0/0 → <master-ReturnGW-eth0-ENI>` to the route table(s) used by
   backend servers. On failover the notify script replaces the route's ENI
   target. No floating IP needed; backend servers route to their default
   gateway via the AWS route table, not a fixed IP. The `ipsec-gw-vip` tag
   is replaced by `ipsec-gw-rtb` (the route table ID to update).
2. **EIP approach**: assign a second EIP to the Return GW pair and associate
   it to the master. Backend servers use the EIP's public IP as their gateway,
   which only works if they route outbound traffic via the internet (unlikely
   for internal backends).
3. **New shared subnet**: create a small /29 that both Return GW nodes join as
   a third interface, strictly for the floating gateway IP. Most complex option.

Option 1 is strongly preferred for an all-private-VPC design.

#### ⚠ Return GW boot script — no Rust binary planned

The `aerobake/fleetroute` AMI is planned with no custom Rust binary. VRRP
unicast configuration (keepalived.conf) must still be written at boot from
IMDS tags. Options:
- Write a minimal shell script that reads the required IMDS tags and renders
  `/etc/keepalived/keepalived.conf` at boot (simpler than a binary, sufficient
  for the static two-node case).
- OR add a minimal `fleetpulse` binary (trivial subset of ipsecpulse, no EIP
  logic, no nftables, just keepalived VRRP config generation).

---

## Important Cross-References

- aerosuite reference: `~/software/aerosuite/` — read before writing anything
- aeropulse (model for ipsecpulse): `vendor/aerosuite/aeropulse/src/main.rs`
- aeroscale (model for ipsecscale): `vendor/aerosuite/aeroscale/src/main.rs`
- aeroplug (reused unchanged): `vendor/aerosuite/aeroplug/src/`
- aerocore (shared utilities): `vendor/aerosuite/aerocore/src/`
- Existing nftables (model): `vendor/aerosuite/aerobake/aeroscale/_etc_nftables_aeroscaler.nft`
- Existing sysctl (model): `vendor/aerosuite/aerobake/aeroscale/_etc_sysctl.d_50-aeroscaler.conf`
- Existing keepalived conf (model): `vendor/aerosuite/aerobake/aeroscale/_etc_keepalived_keepalived.conf`
