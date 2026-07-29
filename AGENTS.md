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
  Cargo.toml                  ← Rust workspace (to be created)
  aerocore/                   ← COPIED from aerosuite — AWS/IMDS utilities
  aeroplug/                   ← COPIED from aerosuite — ENI + secondary-IP mgmt
  ipsecpulse/                 ← NEW binary (adapted from aerosuite/aeropulse)
  ipsecscale/                 ← NEW binary (VPN orchestration daemon)

  aerobake/
    fleetscale/               ← IPSec LB AMI   (Alpine, adapted from aeroscale/)
    fleetsec/                 ← VPN concentrator AMI  (Ubuntu 24.04, new)
    fleetroute/               ← Return-path GW AMI    (Alpine, new)
```

When this session began, `~/software/fleetsuite/` had just been created empty.
The copy steps listed under **Immediate First Steps** below had not yet been run.

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

### New subnets to be created (commands reviewed, not yet executed at time of writing)

See the **Infrastructure Commands** section at the bottom of this file for the
exact AWS CLI commands. All subnets live in the same VPC and use the clean block
`172.16.48.0/21` which does not overlap with any existing subnet.

```
172.16.48.0/27   FleetShell-IPSec-LVS-a         eu-west-2a  PUBLIC   IPSec LB primary
172.16.48.32/27  FleetShell-IPSec-LVS-b         eu-west-2b  PUBLIC   IPSec LB standby
172.16.49.0/24   FleetShell-IPSec-VPN-a         eu-west-2a  PRIVATE  VPN concentrators
172.16.50.0/24   FleetShell-IPSec-VPN-b         eu-west-2b  PRIVATE  VPN concentrators
172.16.51.0/27   FleetShell-IPSec-ReturnGW-a    eu-west-2a  PRIVATE  Return-path GWs
172.16.51.32/27  FleetShell-IPSec-ReturnGW-b    eu-west-2b  PRIVATE  Return-path GWs
172.16.52.0/24   FleetShell-IPSec-Management    eu-west-2a  PRIVATE  RDS, bastion, NAT GW
```

Route tables:
- `FleetShell-IPSec-rtb-public` → LVS subnets, `0.0.0.0/0 → IGW`
- `FleetShell-IPSec-rtb-vpn` → VPN subnets, `0.0.0.0/0 → LVS floating secondary IP` (added after LVS boots)
- `FleetShell-IPSec-rtb-private` → ReturnGW + Management, `0.0.0.0/0 → NAT GW`

---

## Architecture — Full Stack

```
                       Floating EIP  (one IP, all customers)
                             │
                    ┌────────▼────────┐
                    │   LVS pair      │  Alpine Linux
                    │   keepalived    │  c6in.4xlarge × 2
                    │   nftables      │  active/standby
                    │   ipsecpulse    │  AZ-a primary, AZ-b standby
                    └────────┬────────┘
                             │  DNAT: jhash(src_ip) % N
                             │  handles: UDP 500, UDP 4500, proto 50 (raw ESP)
                    ┌────────▼────────────────────┐
                    │  VPN Concentrators (ASG)     │  Ubuntu 24.04
                    │  StrongSwan  IKEv1 + IKEv2   │  c6in.4xlarge
                    │  VPP         data plane       │  3–N instances
                    │  FRR         BGP /32 routes   │  AZ-a + AZ-b
                    │  ipsecscale  orchestration    │
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
                    │  (not built     │
                    │   here)         │
                    └─────────────────┘
```

### Supporting infrastructure

| Component | Location | Purpose |
|---|---|---|
| NAT Gateway | FleetShell-IPSec-LVS-a subnet | Outbound internet for private subnets (package installs during dev) |
| RDS PostgreSQL | FleetShell-IPSec-Management | StrongSwan SQL plugin: PSK store + connection configs |
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

### 2. No VXLAN / no IPVS connection sync on the LVS nodes

The aeroftp LVS uses IPVS connection-state sync over a VXLAN tunnel (because
AWS does not support multicast) to survive failover without dropping FTP
sessions. This is not needed here because:

- The IPSec LB uses **stateless** nftables DNAT: `jhash(src_ip) % N` is a
  pure function with no per-connection memory. Any node computes the same
  answer, so the new master routes identically to the old one with no sync.
- IPSec session state (SA keys, sequence numbers, VRF/NAT entries) lives on
  the **VPN concentrators**, not on the LB. LB failover does not affect it.
- The SNAT return rule is also stateless: every matching packet is rewritten to
  the VIP unconditionally, without consulting conntrack.
- IPSec DPD tolerates the ~5–10 s EIP re-association window; FTP TCP does not.

### 3. Single NIC on LVS nodes (unlike aeroftp which uses three)

aeroftp needs eth1 because IPVS NAT mode requires the LB to be the default
gateway of the backend servers in their own subnet, and eth2 for VXLAN sync.
Neither requirement exists here:

- VPC routing handles cross-subnet forwarding from the LVS subnet to the VPN
  concentrator subnets without a dedicated interface.
- VPN concentrators use the LVS **floating secondary IP** on eth0 as their
  default gateway. One secondary private IP on eth0 serves as both the
  internal default GW and the target of the EIP (external VIP).

### 4. IKEv1 support with `rightid=%any`

A large fraction of the installed customer base runs older CPE firmware that
always places the CPE's inside interface IP (e.g. 192.168.1.1) in the IKE
identity payload. Many customers share this identity. StrongSwan is configured
with `rightid=%any` to ignore the identity payload entirely and look up the
PSK by **peer IP address** instead (which is unique per customer in the
non-CGN case). PSKs are stored in the RDS PostgreSQL database via the
StrongSwan SQL plugin and loaded at runtime.

### 5. Per-tunnel VRF + static 1:1 NAT on VPN concentrators

Every customer tunnel is isolated in its own Linux VRF within VPP. The
existing mapping database (customer device internal IP → unique globally
routable IP) is loaded directly as **static 1:1 NAT entries** in VPP at
tunnel-up time. No intermediate address pool is needed. Non-contiguous unique
IPs per customer are not a problem for static NAT.

Return traffic routing: each unique IP has a `/32` host route in the global
routing table pointing to the customer's VRF. These routes are advertised via
BGP (FRR on each VPN concentrator) to the Return GW pair, which holds up to
600,000 such entries and acts as the default gateway for all backend servers.

### 6. Ubuntu 24.04 for VPN concentrators, Alpine for everything else

VPP has official `fd.io` apt packages for Ubuntu. StrongSwan and FRR are
also first-class on Ubuntu. Alpine does not have VPP in apk and building it
from source is impractical. LVS nodes and Return GW nodes have no such
dependency and stay on Alpine for consistency with aeroftp.

### 7. Shared MemoryDB (Valkey) cluster

The existing `dev-valkey-aeroftp` cluster is reused. Key prefix `fleetipsec:`
avoids collision. The VPN concentrators need to be added to the MemoryDB
security groups (a reviewed command is included below). Valkey is used to
store half-open IKE SA state (DH keys + nonces, TTL 30 s) as a safety net for
the rare case where IKE_SA_INIT and IKE_AUTH land on different VPN nodes during
a hash boundary event.

---

## Binaries

### Copied from aerosuite (do not modify without backporting)

| Binary | Source | Purpose |
|---|---|---|
| `aeroplug eni` | `aerosuite/aeroplug` | Attach/detach ENI; takeover from unresponsive node |
| `aeroplug ip` | `aerosuite/aeroplug` | Assign/unassign secondary private IP (floating VIP) |
| `aerocore` | `aerosuite/aerocore` | Shared AWS API, IMDS, credential helpers |

### New binaries to build

#### `ipsecpulse` (adapt from `aerosuite/aeropulse`)

Runs at instance boot on LVS nodes before keepalived starts. Queries EC2 API
(same peer-discovery pattern as aeropulse) and generates:

- `/etc/keepalived/vrrp.conf` — unicast VRRP on eth0 only (no eth2)
- `/etc/keepalived/notify-master.sh` — calls `aeroplug ip --assign` for the
  floating secondary IP, then `aws ec2 associate-address` for the EIP
- `/etc/keepalived/notify-backup.sh` — no-op
- `/etc/nftables.d/ipsec-dnat.nft` — the jhash DNAT rules, with the current
  list of VPN concentrator IPs fetched from the ASG at boot time

EC2 instance tags required (same pattern as aeropulse):
```
ipsec-lb-role       "master" | "backup"
ipsec-lb-cluster    shared value for both LB nodes (e.g. "fleetipsec-lb")
ipsec-vip-outside   EIP allocation ID
ipsec-vip-inside    secondary private IP to float (e.g. 172.16.48.20)
ipsec-vpn-asg       name of the VPN concentrator ASG
```

#### `ipsecscale` (new, loosely inspired by aeroscale)

Long-running daemon on each VPN concentrator. Responsibilities:

1. **Tunnel lifecycle** — subscribes to StrongSwan vici events:
   - `child-updown INSTALLED`: query RDS for customer device mappings →
     provision VPP VRF + static NAT entries → add FRR static /32 routes
     (redistributed into BGP) → write half-open state to Valkey
   - `child-updown CLOSED`: reverse all of the above
2. **ASG lifecycle hooks** — handles `autoscaling:EC2_INSTANCE_TERMINATING`
   gracefully: send StrongSwan DELETE for all SAs, drain VPP, withdraw BGP
   routes, complete lifecycle hook
3. **Metrics** — expose Prometheus `/metrics` on port 9090: active tunnels,
   VRF count, NAT entry count, BGP route count
4. **Health** — expose `/health` for ASG target group health checks

Environment / config (in `/etc/conf.d/ipsecscale`):
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

Base: `aerobake/aeroscale/fleetscale.pkr.hcl` (copy of aeroscale.pkr.hcl, renamed)

**Remove** from aeroscale skeleton:
- `ipvsadm` package
- `_etc_modules-load.d_keepalived.conf` (ip_vs_* modules)
- `aeroscale` binary and its init.d/conf.d/logrotate
- eth2 / VXLAN references in nftables and sysctl

**Replace**:
- `_etc_nftables_aeroscaler.nft` → new `_etc_nftables_fleetscale.nft`
  (proto 50 + UDP 500 + UDP 4500 jhash DNAT; stateless SNAT for return path)
- `_etc_sysctl.d_50-aeroscaler.conf` → remove IPVS/FTP tuning, keep
  forwarding + conntrack; add `nf_conntrack_proto_esp` tuning
- `_etc_keepalived_keepalived.conf` → remove all virtual_server blocks,
  keep only `include` stubs for vrrp.conf and backends.conf (now VPN node list)

**Add**:
- `ipsecpulse` binary (built from `fleetsuite/ipsecpulse`)
- `_etc_init.d_ipsecpulse` — OpenRC service, runs before keepalived

### `aerobake/fleetsec/` — VPN Concentrator (Ubuntu 24.04)

New packer script — not based on aeroscale. Key packages:
```
strongswan  libcharon-extra-plugins  strongswan-pki
libstrongswan-extra-plugins  strongswan-plugin-eap-mschapv2
vpp  vpp-plugin-dpdk  vpp-plugin-nat  vpp-plugin-crypto-openssl
frr
prometheus-node-exporter
ipsecscale  (built from fleetsuite/ipsecscale)
aeroplug    (built from fleetsuite/aeroplug)
```

SSH via bastion (same pattern as aeroscale.pkr.hcl).

StrongSwan configuration template files to include:
- `/etc/strongswan.d/charon-sql.conf` — enable SQL plugin, PostgreSQL DSN
- `/etc/ipsec.conf` skeleton with `rightid=%any`, `keyexchange=ike`
- `/etc/strongswan.d/charon.conf` — raise `cookie_threshold` for CGN

VPP startup configuration:
- DPDK on ENA (`dev 0000:xx:xx.x` — discovered at boot via sysfs)
- `nat44` plugin enabled
- Unix socket for VPP API (used by ipsecscale)

FRR configuration:
- BGP router, peering with Return GW nodes
- `redistribute static` to pick up /32 host routes added by ipsecscale

### `aerobake/fleetroute/` — Return GW (Alpine)

Minimal Alpine AMI:
- `frr` (BGP only, no OSPF/IS-IS)
- `keepalived` (VIP for backend default gateway, VRRP unicast)
- `iproute2`, `prometheus-node-exporter`
- Sysctl: `net.ipv4.ip_forward=1`, large FIB tuning for 600k routes
- No custom Rust binaries needed (keepalived manages the VIP natively)

FRR BGP peers: all VPN concentrators (addresses discovered from ASG at deploy
time and written into `/etc/frr/frr.conf`).

---

## StrongSwan SQL Schema

The RDS PostgreSQL database `strongswan` must be initialised with StrongSwan's
canonical schema. The relevant tables for this deployment are:

```
identities          peer identity records
ike_configs         IKE proposal + addressing (right=%any, local addr)
peer_configs        per-connection config (rightid=%any, keyexchange=ike)
child_configs       child SA / traffic selector config
shared_secrets      PSK per peer IP: (type='PSK', identity=<peer_ip>)
```

StrongSwan ships the schema in:
`/usr/share/doc/strongswan/examples/stroke/sql/sqlite.sql` (adapt to Postgres).

The `ipsecscale` daemon also uses two additional application tables:
```
tunnel_assignments   (customer_id, vpn_node_ip, vrf_id, created_at)
device_mappings      (customer_id, internal_ip, unique_ip)
```
`device_mappings` is pre-populated from the existing concentrator's mapping
export. `tunnel_assignments` is written by `ipsecscale` at runtime.

---

## nftables Rules for the LVS Nodes

The file `aerobake/fleetscale/_etc_nftables_fleetscale.nft` must implement:

```
Inbound DNAT (PREROUTING):
  ip protocol { udp }  udp dport 500   → jhash ip saddr mod N → VPN node
  ip protocol { udp }  udp dport 4500  → jhash ip saddr mod N → VPN node
  ip protocol 50                       → jhash ip saddr mod N → VPN node

  Where N = number of healthy VPN concentrators (written by ipsecpulse at boot;
  nftables map updated by keepalived notify scripts on ASG change events).

Return SNAT (POSTROUTING):
  oifname "eth0" ip protocol 50  snat to <floating-secondary-ip>
  oifname "eth0" ip protocol udp snat to <floating-secondary-ip>

  Stateless — does not depend on conntrack. Works identically on whichever
  LVS node currently holds the floating secondary IP.

Filter (INPUT):
  Allow: icmp, lo, established/related
  Allow: UDP 500, UDP 4500, proto 50 from 0.0.0.0/0
  Allow: TCP 22 from CLI_RemoteAccess SG range
  Allow: proto 112 (VRRP) from peer LVS node
  Reject everything else.
```

The floating secondary IP and VPN node list are written into
`/etc/nftables.d/ipsec-vars.nft` by `ipsecpulse` at boot, and included by the
main ruleset, so the ruleset itself is static.

---

## sysctl Tuning for LVS Nodes

Remove from aeroscale skeleton: IPVS timeouts, FTP port reservations, tcp_fastopen.

Add / change:
```
# ESP conntrack
net.netfilter.nf_conntrack_max              = 500000
net.netfilter.nf_conntrack_udp_timeout      = 300
net.netfilter.nf_conntrack_udp_timeout_stream = 600
# net.netfilter.nf_conntrack_proto_esp loaded via modules-load

# Forwarding
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 1

# Softirq throughput (critical — c6in.4xlarge has 16 vCPUs)
net.core.netdev_budget       = 1200
net.core.netdev_budget_usecs = 8000

# Socket buffers for high-PPS UDP
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
```

---

## Immediate First Steps for a New Session

Run these in order. The `cp` commands assume the AWS infrastructure (subnets,
SGs, NAT GW, RDS) has already been created by the human operator.

```bash
cd ~/software/fleetsuite

# 1. Copy shared Rust crates from aerosuite
cp -r ~/software/aerosuite/aerocore .
cp -r ~/software/aerosuite/aeroplug .

# 2. Scaffold new crates
cargo new --bin ipsecpulse
cargo new --bin ipsecscale

# 3. Create workspace Cargo.toml
cat > Cargo.toml << 'EOF'
[workspace]
resolver = "2"
members = ["aerocore", "aeroplug", "ipsecpulse", "ipsecscale"]

[workspace.dependencies]
anyhow             = "1"
tokio              = { version = "1", features = ["full"] }
clap               = { version = "4", features = ["derive", "env"] }
serde              = { version = "1", features = ["derive"] }
serde_json         = "1"
redis              = { version = "1.2", features = ["tls-rustls", "tokio-rustls-comp"] }
reqwest            = { version = "0.13", features = ["json"] }
chrono             = "0.4"
tracing            = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
tokio-postgres     = "0.7"
axum               = "0.7"
thiserror          = "2"

[profile.release]
opt-level      = 3
lto            = "fat"
codegen-units  = 1
panic          = "abort"
strip          = true
EOF

# 4. Copy and rename the LB packer skeleton
cp -r ~/software/aerosuite/aerobake/aeroscale ./aerobake/fleetscale
mv ./aerobake/fleetscale/aeroscale.pkr.hcl ./aerobake/fleetscale/fleetscale.pkr.hcl

# 5. Create stub directories for new AMIs
mkdir -p ./aerobake/fleetsec
mkdir -p ./aerobake/fleetroute

# 6. Verify the workspace compiles (aerocore + aeroplug should build cleanly)
cargo build 2>&1 | head -40
```

After these steps the session is ready to implement in this order:
1. `ipsecpulse` binary
2. `aerobake/fleetscale/` — adapt config files, replace nftables rules
3. `aerobake/fleetroute/` — minimal Return GW AMI
4. `ipsecscale` binary
5. `aerobake/fleetsec/` — VPN concentrator AMI (Ubuntu, most complex)

---

## Infrastructure Commands (for reference — already reviewed by operator)

These were prepared in the previous session. The operator was going to execute
them. Verify with `aws ec2 describe-subnets --filters Name=vpc-id,Values=vpc-0595e17ce290fb050`
before assuming they are in place.

```bash
# Subnets — see subnet table above for CIDRs and AZs
aws ec2 create-subnet --vpc-id vpc-0595e17ce290fb050 --cidr-block 172.16.48.0/27  --availability-zone eu-west-2a --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=FleetShell-IPSec-LVS-a}]'
aws ec2 create-subnet --vpc-id vpc-0595e17ce290fb050 --cidr-block 172.16.48.32/27 --availability-zone eu-west-2b --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=FleetShell-IPSec-LVS-b}]'
aws ec2 create-subnet --vpc-id vpc-0595e17ce290fb050 --cidr-block 172.16.49.0/24  --availability-zone eu-west-2a --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=FleetShell-IPSec-VPN-a}]'
aws ec2 create-subnet --vpc-id vpc-0595e17ce290fb050 --cidr-block 172.16.50.0/24  --availability-zone eu-west-2b --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=FleetShell-IPSec-VPN-b}]'
aws ec2 create-subnet --vpc-id vpc-0595e17ce290fb050 --cidr-block 172.16.51.0/27  --availability-zone eu-west-2a --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=FleetShell-IPSec-ReturnGW-a}]'
aws ec2 create-subnet --vpc-id vpc-0595e17ce290fb050 --cidr-block 172.16.51.32/27 --availability-zone eu-west-2b --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=FleetShell-IPSec-ReturnGW-b}]'
aws ec2 create-subnet --vpc-id vpc-0595e17ce290fb050 --cidr-block 172.16.52.0/24  --availability-zone eu-west-2a --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=FleetShell-IPSec-Management}]'

# EIPs
aws ec2 allocate-address --domain vpc --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=FleetShell-IPSec-VIP}]'
aws ec2 allocate-address --domain vpc --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=FleetShell-IPSec-NatGW}]'

# Route tables
aws ec2 create-route-table --vpc-id vpc-0595e17ce290fb050 --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=FleetShell-IPSec-rtb-public}]'
aws ec2 create-route-table --vpc-id vpc-0595e17ce290fb050 --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=FleetShell-IPSec-rtb-vpn}]'
aws ec2 create-route-table --vpc-id vpc-0595e17ce290fb050 --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=FleetShell-IPSec-rtb-private}]'

# Security groups (create first, then add rules with resolved IDs)
aws ec2 create-security-group --vpc-id vpc-0595e17ce290fb050 --group-name FleetShell-IPSec-sg-lvs        --description "IPSec LB: proto50 ESP + IKE from internet"
aws ec2 create-security-group --vpc-id vpc-0595e17ce290fb050 --group-name FleetShell-IPSec-sg-vpn        --description "VPN concentrators: IPSec from LVS, BGP, Valkey, RDS"
aws ec2 create-security-group --vpc-id vpc-0595e17ce290fb050 --group-name FleetShell-IPSec-sg-returngw   --description "Return GW: BGP from VPN concentrators"
aws ec2 create-security-group --vpc-id vpc-0595e17ce290fb050 --group-name FleetShell-IPSec-sg-management --description "Management: RDS, bastion"

# NAT Gateway — subnet ID from LVS-a create output above; EIP alloc from allocate-address output
aws ec2 create-nat-gateway --subnet-id <subnet-FleetShell-IPSec-LVS-a> --allocation-id <eipalloc-NatGW> --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=FleetShell-IPSec-NatGW}]'

# RDS subnet group + instance
aws rds create-db-subnet-group --db-subnet-group-name fleetshell-ipsec-rds --db-subnet-group-description "StrongSwan SQL backend" --subnet-ids <subnet-Management> <subnet-ReturnGW-b>
aws rds create-db-instance --db-instance-identifier fleetshell-ipsec-strongswan --db-instance-class db.t4g.medium --engine postgres --engine-version "16.3" --master-username strongswan --master-user-password <PASSWORD> --allocated-storage 20 --storage-type gp3 --db-subnet-group-name fleetshell-ipsec-rds --vpc-security-group-ids <sg-management> --no-publicly-accessible --backup-retention-period 7 --multi-az --db-name strongswan --tags '[{Key=Name,Value=FleetShell-IPSec-StrongSwan}]'

# Add VPN concentrator SG to MemoryDB cluster
aws memorydb update-cluster --cluster-name dev-valkey-aeroftp --security-group-ids sg-06d737ea5595c275d sg-0709bc00b444b3a9a sg-04e471905c7422a96 sg-065f9193da9f46436 <sg-vpn>
```

---

## Important Cross-References

- Full architecture discussion and decision rationale: chat history in the
  previous session (not preserved here — this file is the distilled result)
- aerosuite reference: `~/software/aerosuite/` — read before writing anything
- aeropulse (model for ipsecpulse): `~/software/aerosuite/aeropulse/src/main.rs`
- aeroplug (reused unchanged): `~/software/aerosuite/aeroplug/src/`
- aerocore (shared utilities): `~/software/aerosuite/aerocore/src/`
- Existing nftables (model to adapt): `~/software/aerosuite/aerobake/aeroscale/_etc_nftables_aeroscaler.nft`
- Existing sysctl (model to adapt): `~/software/aerosuite/aerobake/aeroscale/_etc_sysctl.d_50-aeroscaler.conf`
- Existing keepalived conf (model to adapt): `~/software/aerosuite/aerobake/aeroscale/_etc_keepalived_keepalived.conf`
