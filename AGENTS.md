# FleetSuite -- Agent Bootstrap Document

This file summarises the architecture, decisions, and outstanding tasks for the
`fleetsuite` project. Read it in full before making any changes. It is the
authoritative reference for a new agent session picking up this work.

---

## Next Session Starting Point  <<<  READ THIS FIRST

**Last completed session (2026-08-22):** Port-split scoping fix (bypass-mode
device->backend) -- IN PROGRESS.

THE GAP FOUND: the global service split (`ipsecnode_svcroute`, 8080->proxy pool,
21/22 + 20000-49999 -> aeroftp VIP) lives on `iifname "vpp-outer"`. But the
ENTIRE fleet is customer/bypass mode (`is_customer_mode()` true), and
`setup_site_bypass` forwards decapsulated device traffic straight `xfrm-{hex} ->
ens5` with NO vpp-outer hop. So `ipsecnode_svcroute` NEVER fires for the fleet:
device->proxy (8080) traffic hits the per-site `bnat` `customer_view->real_ip`
DNAT (172.16.53.6, the toml access_server real_ip) as its FINAL destination --
the dynamic proxy pool is bypassed entirely. `pool_proxy`/`ipsecnode_svcroute`
are effectively dead code while the fleet is customer-mode (they only serve the
dormant `backend` mode, of which there are currently zero sites).

THE FIX (per-site, access-view-scoped, single shared pool chain): move the
splits onto the bypass path -- `ipsecnode_bnat` prerouting on `xfrm-{hex}` --
and SCOPE them to the site's access_server customer_view:
```
table ip ipsecnode_bnat {
    chain pool_proxy { dnat to jhash ip saddr mod N map {...} }   # ONE shared chain
    chain prerouting {
        iifname "xfrm-{hex}" ip daddr <access_view> tcp dport 8080        jump pool_proxy
        iifname "xfrm-{hex}" ip daddr <access_view> tcp dport { 21, 22 }  dnat to <FTP_VIP>
        iifname "xfrm-{hex}" ip daddr <access_view> tcp dport 20000-49999 dnat to <FTP_VIP>
        iifname "xfrm-{hex}" ct state new dnat to ip daddr map @bnat_{hex}   # all roles -> real_ip
    }
}
```
nf_nat once-only makes the specific split win over the later default map;
`proxy_pool_task` updates just the one `pool_proxy` chain (now in bnat, not
svcroute). On proxy REMOVAL it also runs `conntrack -F` on the concentrator
(mirrors the LVS fix -- device->proxy conntrack pins to a member; a departed
member black-holes in-flight flows).

>>> PORT-SPLIT SCOPING CONTRACT (discuss with sd_/em_server owners) <<<
The port-based splits apply ONLY to the **access_server** customer_view. Ports
**8080** (HTTP proxy) and **21/22 + 20000-49999** (FTP control + passive data
range) are CLAIMED on the access_server's address and cannot carry any other
service there. sd_server and em_server customer_view traffic is NOT split -- it
passes through untouched (`customer_view -> real_ip` only), so those owners keep
the full port range. The wide 20000-49999 passive-FTP range in particular is
NOT imposed on sd/em (that was the reason to scope per-site rather than a global
`xfrm-*` wildcard). If the proxy/FTP split is ever wanted for sd/em too, it must
be added explicitly and scoped to THEIR customer_view.

BACKEND-MODE NOTE: `ipsecnode_svcroute` (the old global port splits on
vpp-outer) has been REMOVED -- bypass mode never traversed it, and its
global-by-port rules had the same sd/em scoping problem. `cleanup_stale_state()`
deletes any leftover copy on upgrade. If the `backend` VRF mode is ever used, it
needs its OWN port splits on vpp-outer scoped by real_ip (the post-VPP-SNAT dst),
not the removed global rules -- a fresh implementation, tracked as a TODO in
vpp.rs.

----- earlier (2026-08-21) -----
**Prior session:** Proxy ECMP + ipsecscale reconciler +
passive-FTP range -- CODE DONE, committed, NOT in any AMI.

WHAT WAS BUILT:
- fleetproxy dual-homed Squid AMI brought up (curl/IMDS, nftables, tiny-cloud
  reset, KeyName, root profile). squid-infoproxy helper reworked: `--proxy-type
  both` (one lookup authorizes both namespaces + returns a Squid `tag=` for
  intranet-vs-internet routing), SCOPE-TIERED Valkey keys
  (`infoproxy:<pt>:global` / `:model:<partno>` / `:device:<ip>`; helper resolves
  the device model via `HGET systems:by-ip:<ip> partno`), and glob wildcard
  matching (`*.apple.com`, `*suffix`). Portal spooler (fleetshell infoproxy.ts +
  scripts/spool-infoproxy.mjs) rewritten to emit the tiers. First spool run
  UNLINKs the legacy flat per-IP keys.
- **Proxy ECMP membership** (the scaler concept): ipsecscale (LVS master only)
  now reconciles the proxy pool -- DescribeInstances on `fleetshell-proxy-asg`
  (running), keeps the eth0 backend-subnet IP (CIDR filter excludes eth1), TCP
  health-probes :8080, and SETs `fleetipsec:proxy:pool` = `{gen,ips[]}` on
  change. The scaler NEVER touches VPN-node nft directly -- Valkey is the bus.
  Each ipsecnode runs a `proxy_pool_task` (vpp.rs): subscribes to the key +
  periodic 30s reconcile, and rebuilds a jhash-ip-saddr ECMP `dnat` in the
  `pool_proxy` regular chain of `ipsecnode_svcroute` (conntrack pins in-flight;
  jhash gives source affinity for warm helper caches). Config: `SplitRule.pool`
  binds a port to a dynamic pool (8080 -> "proxy"); ipsecnode.toml updated.
- **VPN-NAT watcher** (ipsecscale, runs on BOTH roles): watches the VPN
  concentrator ASG membership and, when it changes (e.g. you CYCLE a
  concentrator), re-renders + hot-reloads THIS LVS node's `ip nat` jhash table
  (/etc/nftables.d/ipsec-nat.nft) so new customers hash across the current node
  set. Reads the VIP secondary IP + VPN ASG name from /run/ipsecpulse.state,
  DescribeInstances the VPN ASG, and reloads atomically (`add table`+`flush
  table`+reload in one `nft -f`). Unlike the proxy pool, this rule lives ON the
  LVS node, so ipsecscale renders+reloads it locally (no Valkey) -- and it runs
  on the BACKUP too (aeroftp pattern) so its local table is always ready for an
  instant VRRP takeover (keys on the node's OWN secondary IP). When a node
  LEAVES the pool it also runs `conntrack -F` (scale-in only -- NOT on scale-out,
  where conntrack pinning must keep tunnels on their node): the LVS DNAT is
  conntrack-backed, so a per-flow binding (e.g. a customer's UDP-4500 NAT-T flow)
  otherwise keeps pointing at a departed node and silently vanishes even after
  the jhash map is corrected (this bit a 2->4->2 cycle: msg1-4 on 500 hit a live
  node, msg5 on 4500 hit a killed one). The proxy pool
  stays MASTER-ONLY (shared Valkey key = single writer). The renderer
  is the NEW shared workspace crate **`ipseccore`** (mirrors aerocore naming) --
  `ipseccore::render_ipsec_nat` + `JHASH_SEED` -- used by BOTH ipsecpulse (boot)
  and ipsecscale (runtime) so the jhash seed/format can never drift (that split
  cost a whole debug session -- Architecture Decision #1). ipsecpulse's
  render_nft_nat is now a thin wrapper over it. The scale-out/in DECISION
  (SetDesiredCapacity on tunnel counts) is still NOT implemented -- membership
  reconcile only.
- **Passive-FTP range**: `SplitRule.port_from/port_to` added; ipsecnode.toml
  routes dport 20000-49999 -> aeroftp VIP (`tcp dport 20000-49999`, a RANGE not
  30k elements). Still OPEN: the fleetshell-gateway must reserve 20000-49999 as
  ephemeral SOURCE ports (see Open TODOs + fleetshell/AGENTS.md §7 Gateway).

DEPLOY PREREQUISITES / NOT DONE:
- Rebuild musl + fleetnode AMI (ipsecnode) AND fleetscale AMI (ipsecscale is no
  longer a stub -- the pkr must bake the new binary) + fleetproxy AMI.
- **LVS node SG must be allowed inbound 6379 on the MemoryDB cluster** so
  ipsecscale can write the pool key (run `infrastructure/make_lvs_valkey_access.sh`;
  mirrors the proxy STEP 3 rule for the LVS SG sg-0406887cfe67d8f15).
- Run the infoproxy spooler once (portal Save-to-Valkey or spool-infoproxy.mjs)
  before any `--proxy-type both` Squid serves, so the tiered keys exist.
- Live-test: scale the proxy ASG and confirm `fleetipsec:proxy:pool` updates and
  the VPN nodes' `pool_proxy` chain rebuilds (`nft list chain ip
  ipsecnode_svcroute pool_proxy`), full HTTP through :8080 across >1 proxy, and
  passive FTP through 20000-49999.

----- earlier (2026-08-18) -----
**Prior session:** Identity-NAT breakage ROOT-CAUSED and
FIXED by design (Option 1 -- per-site VPP bypass).  Cross-project work spanning
fleetsuite (ipsecnode) + ~/software/fleetshell (MDM schema, Valkey spooler,
portal UI).  Code committed; NOT yet in any AMI (musl + fleetnode rebuild
pending).

WHAT WAS BROKEN (whole fleet): backend->device remote access (SSH/RDP/HTTPS all
hang after the first packet) whenever a site uses IDENTITY device NAT
(global_ip == internal_ip).  The device receives the SYN and replies, the reply
is decapsulated and reaches vpp-outer, but the backend never sees it.  ROOT
CAUSE (proven by `nft monitor trace` + `conntrack -L`): the backend<->device
flow hairpins the kernel conntrack stack twice (outside ens5/vpp-outer + inside
xfrm-*/vpp-*), and with identity NAT VPP changes NOTHING, so the forward and
return collapse onto mirror-image conntrack tuples.  nf_nat resolves the
collision by REWRITING the device's source port (observed 8443 -> 11765/4997),
so the reply egresses ens5 from the wrong port and the backend drops it.  The
earlier ct-zone fix (2026-08-12) only ever leaked the FIRST (pre-binding) packet
-- it does NOT fix identity NAT: a single flow ingresses different interfaces
per direction, so no static per-interface zoning can separate the colliding
same-zone tuples.  That ct-zone table (ipsecnode_ctzone) has now been REMOVED
entirely -- it was only ever needed for identity-NAT-through-VPP, which no
longer happens (identity -> bypass), and it actively BROKE customer mode: its
`iifname "xfrm-*" ct zone set 1` put the decapsulated return in zone 1 while the
bypass forward SYN ingresses ens5 in zone 0, so conntrack could not associate
them and the 6g SNAT was never reversed (device SYN-ACK egressed ens5 with
dst=customer_view instead of the backend).  PROVEN live: `nft delete table ip
ipsecnode_ctzone` + `conntrack -F` -> full bidirectional HTTPS immediately.

FLEET REALITY (queried live on the global DB): device.nat_mode was 100%
'customer' (177,723 devices), 0 'platform'.  So identity NAT is what EVERY
production tunnel uses and the bug hit the entire installed base.
gateway.nat_type was the constant '1' on all 20,121 gateways (decoded by
nothing, read by nothing) -- DROPPED.

THE FIX (Option 1): NAT44 in VPP exists ONLY to disambiguate DUPLICATE
internal_ips across customers.  When addresses are already unique in our view
(customer's own range, or they NAT before the tunnel -- the entire fleet), VPP
NAT is a no-op identity mapping = the bug.  So do NOT run VPP for such sites:
- 'customer' mode: NO VPP VRF/tap/NAT44.  Decapsulated traffic on xfrm-{hex} is
  forwarded straight out ens5 (device->backend, after the bnat DNAT); backend->
  device is routed `dst=global_ip/32 dev xfrm-{hex}`.  SINGLE kernel pass per
  direction -> no hairpin, no tuple collision.  The 6g SNAT + backend DNAT still
  apply (now single-pass).  mark_out is OMITTED from the conn (SA selected by
  the xfrm interface's if_id alone).
- 'backend' mode (rare escape hatch, currently nobody): unchanged VPP VRF path.
NAT mode is now a per-SITE (gateway) property, not per-device.  Mixed sites are
handled by policy (allocate distinct global_ips for the colliding subset), not
per-address splitting -- that would break the per-customer xfrm/vpp model.

VALKEY SHAPE (new): nat_mode is emitted on BOTH records (spooler writes both
atomically); it DEFAULTS to 'customer' when absent, so NO mass re-spool is
needed (existing keys route the bypass immediately; the portal writes the
explicit flag on the next gateway save):
  fleetipsec:site:<ip>  { ..., nat_mode: "customer"|"backend" }  (read by credentials.rs)
  fleetipsec:nat:<ip>   { nat_mode: "customer"|"backend", device_nat[], backend_nat? }  (read by vpp.rs)

CODE CHANGES THIS SESSION (all committed, NOT in any AMI):
  fleetsuite/ipsecnode:
    - nat.rs: NatRecord.nat_mode + is_customer_mode() (Some("backend")=VPP; else bypass).
    - credentials.rs: SiteRecord.nat_mode; load_device_conn computes mark_out =
      Some(if_id) only for backend, else None.
    - vici.rs: load_conn takes explicit mark_out: Option<u32> (was always if_id).
    - vpp.rs: SiteVrfState.bypass; on_child_up branches to setup_site_bypass for
      customer mode (global_ip/32 dev xfrm-{hex} + setup_site_bnat, no alloc/VRF);
      on_child_down branches to teardown_site_bypass; added setup/teardown_site_bypass.
    - vpp.rs: REMOVED the ipsecnode_ctzone table (init_nftables_ctzone + const)
      -- obsolete and broke customer mode (see above). init() now just runs a
      one-time conntrack -F; cleanup_stale_state() deletes any stale
      ipsecnode_ctzone so an upgraded-in-place node self-heals. Single default
      conntrack zone everywhere now (backend/real-NAT never collided).
  ~/software/fleetshell (MDM + portal):
    - infrastructure/sql/migrate_gateway_nat_mode.sql (validated live, rolled back):
      gateway.nat_mode ('customer'|'backend', default customer); backfill 'backend'
      where any device was 'platform' (=> none); DROP gateway.nat_type; DROP
      device.nat_mode.  Folded into schema_global.sql.
    - src/lib/server/gateway_spool.ts: reads gateway.nat_mode; emits nat_mode into
      both site+nat records; per-device internal_ip = backend?(ip_real||global):global.
    - Gateway Edit UI: NAT mode select under Tunnel/IPsec; nat_type field removed.
    - Device Edit UI: NAT-mode field removed; gateway picker moved before the IPs;
      chips after "IP address" (INFORMATIVE=customer, TRANSLATED=backend/orange);
      global-uniqueness warning via api/devices/ip-in-use (service-level, boolean
      only, privacy-preserving).  EntityPicker gained onPick; gateways search API
      returns nat_mode; device load joins gw.nat_mode AS gateway_nat_mode.

DEPLOY ORDERING: apply migrate_gateway_nat_mode.sql TOGETHER WITH the portal
deploy (old spooler reads device.nat_mode; new spooler needs gateway.nat_mode).
Then musl rebuild + fleetnode AMI.

NEXT: musl release build (ipsecnode) + fleetnode AMI bake, cycle the VPN
concentrator, then live-test on an identity site: full HTTPS AND SSH transfer
completing BOTH directions (verify a SINGLE conntrack entry, NO source-port
remap -- not just a handshake), plus a backend-mode regression.  Leftover portal
polish: docs/valkey_spool.md still documents the old per-device nat_mode.

----- earlier (2026-08-11) -----
**Increment 6g PHASE 2** -- P2 PROVEN in
isolation (backend-initiated dynamic tunnel bring-up). Ran a two-node (N=2)
concentrator test against helena2/helena1 through the LVS. Findings and FOUR
code fixes below; code committed, NOT yet in any AMI. The LVS was patched by
hand during testing; the ipsecpulse changes bake those patches into the AMI.

P2 verdict and findings (2026-08-11):
- P2 (the customer's IKE reply returning to the INITIATING concentrator through
  the stateless LVS) WORKS. The LVS conntrack entry created by the outbound SNAT
  reverses the reply to the initiator regardless of jhash ownership, so
  jhash-ownership is NOT required for basic establishment. It IS still the right
  design for robustness: conntrack expiry (idle on-demand tunnels), LVS failover
  (the backup has no conntrack -- Decision #3), and the SNAT tuple collision
  below all break a non-owner-initiated return path but are correct when the
  initiator is the jhash owner.
- LVS DNAT hijack (FIX 1): the PREROUTING jhash DNAT was unscoped, so a
  concentrator's OWN outbound IKE (transiting the LVS) matched it and was
  DNAT'd back into the concentrator pool instead of egressing to the customer.
  helena saw nothing; the initiator got a reply from a looped-back concentrator.
  Fix: scope all three DNAT rules to `ip daddr <secondary_ip>` (customer VIP).
- jhash random per-rule seed (FIX 2, CRITICAL): nftables `jhash` with no `seed`
  picks a RANDOM seed PER RULE, so the proto-50 / UDP-500 / UDP-4500 rules hash
  the same source IP to DIFFERENT nodes at N>1. IKE_SA_INIT landed on one node,
  IKE_AUTH on another -> `IKE_SA checkout not successful` -> ALL customer tunnels
  broke at N=2. Latent until now because every prior data-plane test ran N=1
  (mod 1 -> index 0 regardless of seed). Fix: emit a FIXED shared `seed` on all
  three jhash rules (see Architecture Decision #1).
- Initiator PSK lookup (FIX 3): on outbound initiate StrongSwan looked up the
  PSK as (my_ip, %any) and found none (PSKs are owned by the customer IP). Fix:
  set the conn `remote.id = <customer public IP>` for static-IP sites so the
  lookup resolves the per-customer VICI PSK by the peer identity -- the SAME key
  store the responder path uses. No per-node secret; scales to 25k distinct
  PSKs. (A hand-typed secret keyed to the node IP appeared to work in test only
  because helena1/helena2 shared one PSK -- a dead end that cannot scale.)
- Local identity / Cisco compat (FIX 4): the concentrator presented its PRIVATE
  IP as IDi, which every standard CPE rejects -- Cisco et al. key the PSK to the
  peer's PUBLIC IP (`crypto isakmp key <psk> address <EIP>`). Confirmed on
  helena: `no shared key found for '%any' - '172.16.50.162'`. Fix: present
  `local.id = <customer-facing EIP>`, plumbed via ipsecnode.toml `[node]
  local_ike_id`. REQUIRED for compatibility with the installed base.
- SNAT tuple collision (design note, no code fix): through the single-VIP
  stateless LVS a given customer cannot have a concentrator-initiated AND a
  customer-initiated IKE flow at once -- both collapse to
  src=<customer_ip> <-> <VIP> on 500/4500 and collide in conntrack (the stale
  entry hijacks the other direction). Phase-2 on-demand MUST guarantee a single
  active initiator per customer and flush conntrack on direction changes.

The FOUR fixes (all committed this session):
  1. ipsecpulse::render_nft_nat -- scope DNAT to `ip daddr <secondary_ip>`.
  2. ipsecpulse::render_nft_nat -- fixed `seed` (JHASH_SEED) on all jhash rules.
  3. vici::load_conn -- `remote.id = device_ip` for static-IP sites.
  4. vici::load_conn -- `local.id = <EIP>` discovered via DescribeAddresses by
     the VIP EIP's Name tag (default `FleetShell-IPSec-VIP`); ipsecnode.toml
     [node] local_ike_id / vip_name_tag are optional overrides. Plumbed through
     credentials::bulk_load / pubsub_task / load_one_device.
OPERATIONAL: no new infra tag -- each region just needs its VIP EIP named
`FleetShell-IPSec-VIP`. Rebuild the fleetscale (LVS) AMI for fixes 1+2 and the
fleetnode AMI for fixes 3+4.

NEXT SESSION -- build phase-2 on-demand bring-up (mechanism b).  See the full
plan in Build Order step 6, "NEXT-SESSION PLAN" under the 6g phase 2 entry.
Two things learned/decided this session feed into it:
- INITIATE THE CHILD, NOT THE IKE: a data-driven bring-up must raise the
  CHILD_SA (VICI initiate targeting the child / a trap policy), not just the
  IKE_SA -- `--initiate --ike` fires no child-updown event, so no VPP VRF / /32
  / device route is installed and backend->device fails.  on_child_up is
  direction-agnostic, so once the child is up the data plane is identical to a
  site-initiated tunnel.
- OWNER SELECTION is the open decision: (a) any node initiates and relies on LVS
  conntrack to return the IKE reply (proven; recommended to try first) vs
  (b) initiate from the jhash owner by self-computing a kernel-bit-exact jhash
  (seed JHASH_SEED, sorted pool ring published to Valkey by ipsecscale).

----- earlier (2026-08-10) -----
**Increment 6g PHASE 1 COMPLETE** --
backend-to-device connections work end-to-end for tunnels that are ALREADY
established. Validated on two independent tunnels (helena2, koi): full TCP
handshake backend -> device, reproduced automatically by the daemon with no
manual vppctl/nft steps. Code committed (791f7ef + 62a2c97), NOT yet in any AMI.

Key facts / lessons from 6g phase 1 (all in `ipsecnode/src/vpp.rs`):
- Two per-site additions, both keyed to the customer's `access_server` role:
  1. POSTROUTING SNAT (`setup_site_bnat` / `SiteBnatState.snat_handle`):
       `oifname xfrm-{hex} ct state new snat ip to <access_server view_ip>`
     Rewrites the backend source into the tunnel's negotiated `local_ts` so the
     outbound XFRM policy matches. WITHOUT it: XfrmOutNoStates -> ICMP host
     unreachable (the source IP was not in the policy selector).
     NOTE: the correct discriminator is `oifname xfrm-{hex} ct state new`, NOT
     `iifname ens5` as the original 6g design note said -- the kernel<->VPP
     userspace hop resets the input interface to `vpp-{hex}`.
  2. Site-VRF outside return route (`setup_site_vrf` step 9b):
       `ip route add 0.0.0.0/0 table {if_id} via lookup in table 0`
     Backend-initiated NAT sessions are o2i-FIRST, so VPP re-looks-up the device
     reply's destination in the SITE VRF (fib N) after i2o SNAT. The site VRF
     only had `internal_ip/32` + the tap /30, so the reply hit `null-node`
     (dpo-drop) and was silently lost.
     CRITICAL: this route MUST be `via lookup in table 0` (a recursive lookup
     DPO). Do NOT use `via <ip> <vpp-outer>`: a cross-VRF next-hop adjacency
     (route in fib N via an interface living in fib 0) SIGSEGVs VPP 26.06 on
     adjacency creation --
       adj_nbr_add_or_lock -> adj_delegate_adj_created -> ip_pmtu_get_ip
       -> fib_table_get_table_id_for_sw_if_index  (null deref).
     A manual test of the crashing form survived only by luck (the adjacency
     already existed, so it was locked not created). The lookup DPO creates no
     adjacency, so the pmtu delegate never fires.
- VPP FIB table-ids are `u32::from(peer_ip)` and VPP `show ip fib` prints them
  as SIGNED int32, so ids > 2^31 appear negative (koi 185.17.205.91 =
  0xb911cd5b = 3104951643 displays as -1190015653). Same table; cosmetic only.
- Client-side gotcha found during koi testing: the customer gateway must have
  `net.ipv4.ip_forward=1`, else it drops the device's reply before it re-enters
  the tunnel (looks like: forward SYNs reach the device, no reply comes back).

**Next: Increment 6g PHASE 2 -- dynamic tunnel bring-up** when a backend tries
to reach a device whose tunnel is NOT currently established. See
"Increment 6g phase 2" note in the increment list and Architecture Decision #17.
Two candidate mechanisms were discussed (StrongSwan trap policies pre-provisioned
vs. ipsecnode-driven on-demand VICI initiate); leaning toward the latter, but
NOT yet decided. The hard shared sub-problem is P2: the concentrator that
initiates the outbound tunnel MUST be the LVS jhash(customer_public_ip) owner,
or the customer's IKE reply lands on the wrong node. Prove P2 in isolation first.

----- earlier (2026-08-07) -----
Increment 6f-r COMPLETE -- per-site backend DNAT working end-to-end with
overlapping RFC 1918 customer_view_ip values. T6 PASSED.

Key design decisions made during 6f-r:
- Shelved the global-map approach (increment-6f branch) because customer_view_ip
  values are not globally unique -- customers choose their own private addresses
  with no coordination between sites.
- Replaced with per-site nftables maps scoped to each `xfrm-{hex}` interface.
  Two customers using the same customer_view_ip coexist because their decapsulated
  traffic arrives on different xfrm interfaces.
- `backend_nat` Valkey schema changed from a flat array to named roles
  (access_server / sd_server / em_server). real_ip per role lives in
  `/etc/ipsecnode/ipsecnode.toml` (global infrastructure config).
- Global service routing table (`ipsecnode_svcroute`) splits port 8080 and
  ports 21/22 off the access_server to dedicated backend servers.
- `ct state new` guard on per-site PREROUTING rules prevents conflicts with
  conntrack-established replies (also required for Increment 6g SNAT).

All code committed. Musl binary rebuilt. AMI baked with ipsecnode.toml.

### What the next session should do

**Increment 6g PHASE 1 is COMPLETE** (established-tunnel backend -> device).
Code committed (791f7ef + 62a2c97). Musl binary + AMI rebuild still pending.

**Next: Increment 6g PHASE 2 -- dynamic tunnel bring-up.**

When a backend server initiates traffic to a device whose tunnel is DOWN, the
tunnel must be established on demand. Nothing is implemented yet -- this is a
design decision to make first. See the "Increment 6g phase 2" entry in the
increment list (Build Order step 6) for the two candidate mechanisms and the
shared prerequisites (P1 routing attraction, P2 jhash-owner selection, P3
local_ts scoping). Recommended first move: prove P2 in isolation (force a
concentrator to initiate outbound IKE and confirm the customer's reply returns
to the SAME node through the LVS jhash).

See Open TODOs for the aeroftp PASV reply IP question (related to 6g).

**Also needed before full production testing:**
- Hook up real backend servers (172.16.53.6/7/8/9, aeroftp VIP 172.16.48.10)
  and verify the reverse direction (backend -> device) with real traffic.
- AMI rebuild sequence: see REBUILD SEQUENCE below.

**Ongoing open topic:** AWS-initiated tunnels (backend -> device).
See Architecture Decision #17. Deferred until routing design is resolved.

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

ipsecpulse / fleetscale LVS (need rebuild -- P2, 2026-08-11):
  - render_nft_nat: PREROUTING jhash DNAT scoped to `ip daddr <secondary_ip>`
    (stops concentrator-initiated outbound IKE being hijacked back into the pool).
  - render_nft_nat: fixed `seed` (JHASH_SEED) on all three jhash rules so
    proto-50/500/4500 from one source IP hash to the SAME node at N>1 (was a
    random per-rule seed -> IKE split across nodes).

ipsecnode / fleetnode (need musl rebuild -- P2, 2026-08-11):
  - vici::load_conn: remote.id = device_ip for static-IP sites (initiator PSK
    lookup resolves the per-customer VICI PSK by peer identity).
  - vici::load_conn: local.id = <EIP> so this node presents the customer-facing
    EIP as IDi (required for Cisco/standard CPE that key their PSK to our public
    IP). Plumbed through credentials.rs. The EIP is discovered at startup via
    DescribeAddresses filtered by the VIP EIP's Name tag (default
    `FleetShell-IPSec-VIP`, aws::fetch_vip_public_ip), so a new regional
    deployment needs no file edit -- it just needs its VIP EIP named that.
    ipsecnode.toml [node] local_ike_id / vip_name_tag are optional overrides.
  - nodeconfig: new optional [node] local_ike_id + vip_name_tag.

NO new infra tag needed: ipsecnode reads the existing VIP EIP by its Name tag.

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

### Valkey seed for T6 testing (helena1 + helena2, Increment 6f-r)

helena1 and helena2 share the same `internal_ip` (proving 6e VRF isolation)
but have **different** `global_ip` values (required: each /32 is a unique BGP
route advertised to the Return GW).

```bash
VALKEY="rediss://clustercfg.dev-valkey-aeroftp.ak121m.memorydb.eu-west-2.amazonaws.com:6379"

# PSKs (unchanged from prior testing)
redis-cli -u $VALKEY SET fleetipsec:psk:62.238.96.148  helena1psk
redis-cli -u $VALKEY SET fleetipsec:psk:62.238.110.152 helena2psk

# Site records
redis-cli -u $VALKEY SET fleetipsec:site:62.238.96.148 \
  '{"customer_id":"helena1","static_ip":true}'
redis-cli -u $VALKEY SET fleetipsec:site:62.238.110.152 \
  '{"customer_id":"helena2","static_ip":true}'

# NAT records -- same internal_ip, different global_ip, same backend_nat view IPs
# (6f-r: xfrm isolation means same customer_view_ip values are fine on both sites)
redis-cli -u $VALKEY SET fleetipsec:nat:62.238.96.148 \
  '{"device_nat":[{"internal_ip":"192.168.13.133","global_ip":"198.51.100.133"}],"backend_nat":{"access_server":"194.138.39.18","sd_server":"194.138.39.21","em_server":"194.138.39.19"}}'
redis-cli -u $VALKEY SET fleetipsec:nat:62.238.110.152 \
  '{"device_nat":[{"internal_ip":"192.168.13.133","global_ip":"198.51.100.134"}],"backend_nat":{"access_server":"194.138.39.18","sd_server":"194.138.39.21","em_server":"194.138.39.19"}}'
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
  Cargo.toml                  <- Rust workspace (ipseccore, ipsecpulse, ipsecscale, ipsecnode, fleetpulse, squid-infoproxy)
  .gitmodules                 <- declares vendor/aerosuite submodule
  vendor/
    aerosuite/                <- git submodule -> git@github.com:michaelrommel/aerosuite.git
                                  aerocore and aeroplug are consumed from here via
                                  path dependencies; they are NOT workspace members
                                  (nested workspaces are not supported by Cargo)
  ipsecpulse/                 <- binary: boot-time config generator (LVS nodes) -- IMPLEMENTED
  ipsecscale/                 <- binary: ASG orchestration daemon (LVS nodes)   -- STUB
  ipsecnode/                  <- binary: per-node tunnel lifecycle (VPN nodes)   -- STUB
  squid-infoproxy/            <- binary: Squid external_acl helper (Info Proxy destination
                                  authz; Valkey-keyed on the CLIENT source IP). Moved here
                                  from fleetshell; baked into the fleetproxy AMI. Only tie to
                                  fleetshell is the Valkey key schema infoproxy:<type>:<src_ip>,
                                  written by the fleetshell portal Info Proxy spool.

  aerobake/
    fleetscale/               <- IPSec LB AMI   (Alpine) -- IMPLEMENTED, TESTED
    fleetnode/               <- VPN concentrator AMI (Debian 12 Bookworm) -- IN PROGRESS
    fleetroute/               <- Return-path GW AMI (Alpine) -- TODO
    fleetproxy/               <- Dual-homed Squid proxy AMI (Alpine) -- SCAFFOLDED
                                  eth0 (Backend subnet -> concentrator) Squid :8080; eth1
                                  (proxy-out subnet -> NAT) created+attached at boot by the
                                  proxy-net service, source-based policy routing sends Squid's
                                  OWN egress via NAT (not the tunnel). Authz via squid-infoproxy.
                                  No NLB: :8080 is ECMP-split in ipsecnode.
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
| FleetShell-proxy-out-a | `subnet-012fbf61edb76044b` | 172.16.59.0/24 | eu-west-2a | PRIVATE | proxy-out-rtb (-> NAT); tag `fleetshell-proxy-out=true` |
| FleetShell-proxy-out-b | `subnet-010bc8913fb992563` | 172.16.60.0/24 | eu-west-2b | PRIVATE | proxy-out-rtb (-> NAT); tag `fleetshell-proxy-out=true` |
| FleetShell-db-a | `subnet-0e451606d0b35d3d5` | 172.16.57.0/24 | eu-west-2a | PRIVATE | Aurora PrivateLink (vpce-09f0f22044c26be7b -> vpce-svc-...); sg `fleetshell-db-sg` (5432) |
| FleetShell-db-b | `subnet-0b79a30f1d81b9141` | 172.16.58.0/24 | eu-west-2b | PRIVATE | Aurora PrivateLink; sg `fleetshell-db-sg` (5432) |

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
| fleetshell-proxy-in | TBD (`make_proxy_service.sh` STEP 2) | fleetproxy eth0: inbound TCP 8080 from the tunnel (arbitrary device IP); egress all. |
| fleetshell-proxy-egress | TBD (`make_proxy_service.sh` STEP 2) | fleetproxy eth1: outbound 80/443 to internet + intranet peer. Discovered by Name tag by the proxy-net service. |

### Other resources

| Resource | ID | Notes |
|---|---|---|
| NAT Gateway | `nat-0fb75bf0679751582` | In LVS-a subnet |
| Backend VPC endpoints | s3(gw), ecr.api, ecr.dkr, ssm, ssmmessages, ec2messages | On rtb-backend. **Missing: `com.amazonaws.eu-west-2.ec2` (control plane)** -- required by the fleetproxy `proxy-net` service (aws-cli + aeroplug create/attach the egress ENI over eth0 before NAT exists). Added by `make_proxy_service.sh` STEP 0. |
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

IMPLEMENTATION NOTE (2026-08-11): the three jhash rules MUST carry the SAME
explicit `seed`. With no seed, nftables assigns a random seed per rule, so at
N>1 the 500/4500/ESP rules hash one source IP to DIFFERENT nodes and IKE splits
across concentrators (IKE_SA_INIT on one, IKE_AUTH on another ->
`IKE_SA checkout not successful`). ipsecpulse now emits a fixed shared seed
(JHASH_SEED) on all three rules. The DNAT rules are also scoped to
`ip daddr <secondary_ip>` so they only match customer inbound traffic and never
hijack concentrator-initiated outbound IKE (P2).

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
        "ike_identity": "10.5.0.1",     // optional; see Decision #13 and the
                                        //   "When to set ike_identity" note below
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

**When to set `ike_identity` (portal / provisioning reminder):**
`ike_identity` is the CUSTOMER device's own IKE identity (its IDi, our
`remote.id`).  It is the OPPOSITE direction from `local_ike_id` (which is OUR
identity -- the EIP -- that we present, discovered via DescribeAddresses).

Set `ike_identity` whenever the device presents an identity that is NOT its
public IP, e.g.:
  - IKEv2 or IKEv1 Aggressive Mode devices configured with an FQDN, a
    user-FQDN/email, or a key-id (Cisco `identity hostname` / `identity key-id`).
  - devices that identify by an internal/LAN IP (common behind their own NAT).
  - any CPE where the installer set a local identity that differs from the WAN IP.

Leave it unset for the common case: a static-IP device that identifies by its
public IP (IKEv1 Main Mode default; most CPE using `identity address`).  Then
`remote.id` defaults to the public IP.

Effect (with the P2 initiator fix, 2026-08-11): `remote.id = ike_identity` when
set, else the public IP for static-IP sites.  This means the P2 fix TIGHTENED
the static-IP responder from `remote.id = %any` to the public IP -- so a device
that presents a non-IP identity WITHOUT `ike_identity` set will now be rejected.
The portal `ike_identity` field is exactly that escape hatch: populate it for
such devices and both the responder and node-initiated directions work.

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

### 18. fleetproxy -- dual-homed Squid HTTP/HTTPS destination (port 8080)

**Goal:** Terminate device HTTP/HTTPS egress at the tunnel exit and authorize
destinations per-device via the `squid-infoproxy` helper (Valkey allow-lists
keyed on the device's global source IP). See `aerobake/fleetproxy/README.md` and
`infrastructure/make_proxy_service.sh`.

**The core problem (why not a plain single-homed proxy / Fargate / NLB):**
Device replies must return via the concentrator (rtb-backend default -> Return
GW), but Squid's OWN outbound requests must egress via the NAT gateway. Both
destinations are arbitrary non-backend IPs (customer address space is not a
fixed CIDR -- the backend uses an EXCLUDE list `172.16/16, 10.183/16,
169.254/16` and sends everything else to the concentrator), so the two flows
CANNOT be separated by destination. Authorization also requires the real device
IP (no SNAT). Therefore the split is by SOURCE, via two ENIs + policy routing.

**Mechanism:**
- `eth0` in a Backend subnet (rtb-backend -> concentrator): Squid `http_port
  :8080`; device replies return here.
- `eth1` in a proxy-out subnet (-> NAT): Squid `tcp_outgoing_address`. Created +
  attached AT BOOT by the `proxy-net` OpenRC service (aws-cli + `aeroplug`),
  per-instance (no slot pool -- unlike aeroftp). `ip rule from <eth1-ip> table
  200` (default -> NAT) steers every originated connection out the NAT.
- AWS cannot launch an instance with two ENIs in different subnets, hence the
  boot-attach workaround (same as the ReturnGW/fleetroute pattern).
- `proxy-net`'s EC2 API calls run over eth0 BEFORE NAT exists, so a
  `com.amazonaws.eu-west-2.ec2` interface endpoint on the Backend subnets is a
  hard prerequisite (STEP 0; `ec2messages` != `ec2`).
- Intranet vs internet is decided purely by URL (`dstdomain` fast ACL): intranet
  hosts -> a single downstream `cache_peer`; everything else direct via NAT.
- No NLB (preserving the arbitrary client IP while returning via the
  concentrator is incompatible with an NLB return path). HA/scale = ipsecnode
  VPP ECMP splitting `:8080` across the ASG's eth0 IPs (STEP 9).

**Status:** Scaffolded (AMI files + progressive infra script). NOT yet built or
deployed. Open: ipsecnode ECMP registration of the eth0 IP set; ENI-leak
sweeper/lifecycle hook; tighten the IAM ENI policy.

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

### `aerobake/fleetproxy/` -- Dual-homed Squid HTTP/HTTPS proxy (Alpine) -- SCAFFOLDED

**Status:** AMI files + progressive infra script written; NOT yet built/deployed.
See Architecture Decision #18 and `aerobake/fleetproxy/README.md`.

**NIC layout:**
- eth0: device-facing NIC (Backend subnet, rtb-backend -> concentrator). Squid
  `http_port :8080`; device replies return here.
- eth1: egress NIC (proxy-out subnet, -> NAT). Squid `tcp_outgoing_address`.
  Created + attached AT BOOT by the `proxy-net` service (per-instance, aws-cli +
  `aeroplug`); source-based `ip rule from <eth1-ip> table 200` sends Squid's own
  egress via NAT instead of the tunnel.

**Files:** `fleetproxy.pkr.hcl` (+ `infrastructure/fleetproxy.pkrvars.hcl`),
`_etc_init.d_proxy-net` (create/attach eth1 + policy routing + materialise
squid.conf), `_etc_squid_squid.conf` (helper authz + URL-based intranet
`cache_peer` split), `_etc_conf.d_proxy-net`, `_etc_conf.d_squid`,
`_etc_squid_intranet_domains.txt`. Helper binary = `squid-infoproxy` (workspace).
Infra: `infrastructure/make_proxy_service.sh` (+ `_trust.json` / `_policy.json`).

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
   - 6e: Per-customer VRF isolation -- **COMPLETE (2026-08-07)**.
     Each site gets its own VPP fib table (id = u32 from peer IPv4), XFRM
     interface (`xfrm-{hex8}`), per-site inside tap (`vpp-{hex8}`) in
     10.127.0.0/16 /30 space, forward table (10000+), return table (60000+).
     Three bugs found and fixed during testing (all committed):
     1. Return table must route `default dev xfrm-{hex}` (not `dev ens5`);
        XFRM output policy requires `if_id` on the output interface.
     2. TCP MSS clamped to 1380 via nftables FORWARD chain in `ipsecnode`
        table (AES-256-GCM + UDP-NAT-T = ~100 bytes overhead per packet).
     3. VPP `nat44 static mapping ... vrf N` does NOT auto-insert FIB entry
        for `internal_ip` in VRF N; must explicitly add
        `ip route add internal_ip/32 table N via kern_ip vpp_tap`.
     XFRM interface MTU set to 1420 at creation (`credentials.rs`).
     Confirmed: two customers with identical `internal_ip` (192.168.13.133)
     coexist on the same concentrator with full HTTP traffic.
   - 6f-r: Backend DNAT via per-site nftables xfrm-scoped maps -- **COMPLETE (T6 PASSED)**.
     Named-role Valkey schema (access_server/sd_server/em_server). real_ip and
     port-split rules in ipsecnode.toml. Global service routing table
     (ipsecnode_svcroute) on vpp-outer splits port 8080 and 21/22. Tested with
     helena1 (customer_view_ip=194.138.39.18) and helena2 (customer_view_ip=10.1.2.3
     -- RFC 1918, proving xfrm isolation). Both simultaneous, full HTTP confirmed.
     Shelved global-map approach kept in git branch `increment-6f`.
   - 6g: Backend-to-device (remote access direction).
     - PHASE 1 (established tunnel) -- **COMPLETE (2026-08-10)**, committed
       791f7ef + 62a2c97, not yet in AMI. Two per-site additions in vpp.rs,
       both keyed to the `access_server` role:
       1. POSTROUTING SNAT `oifname xfrm-{hex} ct state new snat to
          <access_server view_ip>` (`setup_site_bnat`). Puts the backend
          source into the tunnel's negotiated `local_ts` so the outbound XFRM
          policy matches (else XfrmOutNoStates -> ICMP host unreachable).
          The discriminator is `oifname xfrm-{hex} ct state new`, NOT
          `iifname ens5` -- the kernel<->VPP userspace hop resets the input
          interface to `vpp-{hex}`.
       2. Site-VRF return route `ip route add 0.0.0.0/0 table {if_id} via
          lookup in table 0` (`setup_site_vrf` step 9b). Backend-initiated NAT
          sessions are o2i-FIRST, so VPP re-looks-up the device reply's dst in
          the site VRF after i2o SNAT; without a route it hits null-node
          (dpo-drop). MUST be a recursive lookup DPO (`via lookup in table 0`)
          -- a cross-VRF next-hop adjacency (`via <ip> vpp-outer`) SIGSEGVs
          VPP 26.06 (ip_pmtu_get_ip / fib_table_get_table_id_for_sw_if_index).
       Validated on helena2 + koi (full TCP handshake, reproduced by the
       daemon with no manual steps). Client gateway needs ip_forward=1.
     - PHASE 2 (tunnel DOWN -- dynamic bring-up) -- **IN PROGRESS**. P2 PROVEN
       in isolation (2026-08-11, N=2 test vs helena1/helena2). Four blocking
       bugs found and fixed along the way (see "Next Session Starting Point"):
       (1) LVS DNAT scoped to `ip daddr <secondary_ip>`; (2) fixed jhash `seed`
       on all rules; (3) `remote.id = customer_ip` for initiator PSK lookup;
       (4) `local.id = EIP` for Cisco/standard-CPE PSK compatibility.
       When a backend initiates to a device whose tunnel is not established,
       the tunnel must come up on demand. See Architecture Decision #17.
       Two candidate mechanisms discussed (not yet decided):
         (a) StrongSwan trap policies pre-provisioned per site (xfrm-{hex} +
             local_ts=global_ip + start_action=trap installed even while down);
             a backend packet auto-initiates IKE. Cost: idle state for all
             sites; and coupling to the LVS jhash ring (must re-migrate trap
             state on scale events), which fights the stateless-LVS design.
         (b) ipsecnode-driven on-demand VICI initiate: advertise a covering
             aggregate, punt un-provisioned global_ip packets to ipsecnode
             (nfqueue), which looks up the site in Valkey and initiates.
             Zero idle state; ownership decision centralised in ipsecnode.
             Leaning toward (b).
       SHARED hard prerequisites (true for both):
         P1 -- attract the backend packet to a concentrator while the tunnel is
               down (always-advertise /32, or a covering aggregate).
         P2 -- the initiating concentrator SHOULD be jhash(customer_public_ip)%N.
               PROVEN (2026-08-11): the customer's IKE reply DOES return to the
               initiator even from a non-owner, because the LVS conntrack entry
               from the outbound SNAT reverses it. So jhash-ownership is NOT
               required for establishment -- but IS required for robustness
               (conntrack expiry on idle tunnels, LVS failover with no conntrack
               sync, and the SNAT tuple collision all break a non-owner return
               path). Mechanism (b) must still pick the jhash owner as initiator.
         P3 -- local_ts scoped to global_ip (not 0.0.0.0/0) so the trap/initiate
               targets exactly one customer.

     NEXT-SESSION PLAN (phase 2 build, mechanism (b)):
       1. TRIGGER + ATTRACTION (P1): advertise a covering aggregate (or
          always-advertise the /32) so a backend packet to an un-provisioned
          global_ip reaches SOME concentrator while the tunnel is down.  Punt
          that packet to ipsecnode via nfqueue; ipsecnode reverse-maps
          global_ip -> peer_ip (site) in Valkey and decides whether/where to
          initiate.
       2. INITIATE THE CHILD, NOT THE IKE (lesson 2026-08-11): a data-driven
          bring-up must raise the CHILD_SA, not just the IKE_SA.  `swanctl
          --initiate --ike` establishes ONLY the IKE_SA -- no child-updown event
          fires, so ipsecnode installs NO VPP VRF / /32 / device route and the
          backend cannot reach the device (this fooled us during P2 testing:
          the IKE_AUTH had no SA/TSi/TSr payloads and `ip r` showed no
          vpp-{hex} tap or global_ip route).  Use a VICI initiate that targets
          the CHILD (equivalent of `swanctl --initiate --child site-<ip>`); a
          StrongSwan trap policy does this automatically on the first data
          packet.  on_child_up is DIRECTION-AGNOSTIC (handle_child_updown keys
          off the `up` flag + remote-host only), so once the child is up the
          full data plane is installed exactly as for a site-initiated tunnel --
          no initiator-specific code is needed.
       3. OWNER SELECTION (P2) -- the open design decision:
          (a) SIMPLE / proven: any node that catches the trigger initiates; the
              customer's IKE reply returns to it via the LVS conntrack entry
              (proven 2026-08-11).  After an LVS failover or conntrack expiry the
              customer's ESP re-hashes to the jhash owner and DPD re-establishes
              there -- self-healing with a blip; no hash math in ipsecnode.
              RECOMMENDED to build and measure FIRST.
          (b) ROBUST: initiate from the jhash owner so the return path is correct
              even cold.  ipsecnode must self-compute the SAME decision nftables
              makes: owner = sorted_pool[ jhash(customer_ip, JHASH_SEED) mod N ].
              Requirements:
                - a Rust jhash BIT-EXACT with the kernel jhash nftables uses
                  (Jenkins lookup3 over the 4 IPv4 bytes in network order,
                  len 4, seed = JHASH_SEED = 0xa5a5a5a5).  Validate empirically
                  against observed mappings (helena1/helena2 -> node) before
                  trusting it; put it in ONE shared place used by BOTH the nft-map
                  builder (ipsecpulse/ipsecscale) and ipsecnode.
                - the current ring: seed (constant), the ORDERED concentrator IP
                  list (ipsecpulse's numerically-sorted vpn_ips) and N.  The LVS
                  master (ipsecscale) owns the map, so publish the ring to Valkey
                  (e.g. fleetipsec:lvsring = {seed, nodes:[...]}) on every pool
                  change; ipsecnode subscribes and recomputes.
                - if the trigger lands on a non-owner, hand off to the owner
                  (Valkey message / direct signal) so the OWNER initiates.
          Either way: the SNAT tuple collision (a concentrator-initiated and a
          customer-initiated IKE flow for the same customer collapse to one
          5-tuple at the LVS) means enforce a SINGLE active initiator per
          customer and flush the LVS conntrack on direction changes.
   - 6h: ASG lifecycle hook heartbeat
   - 6i: Valkey half-open IKE SA state
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

### T5 -- Per-customer VRF isolation (Increment 6e)

**Status: PASSED (2026-08-07).** Two customers (helena1 62.238.96.148,
helena2 62.238.110.152) both using `internal_ip=192.168.13.133` connect
simultaneously to the same concentrator. Each gets its own VPP fib table,
XFRM interface, and per-site tap. Full HTTP (curl) confirmed on both.

Bugs found during T5 (all fixed before passing):
1. **Return routing via xfrm interface**: return table must route
   `default dev xfrm-{hex}`. Routing via `dev ens5` causes the XFRM output
   policy (which has `if_id` set) to never fire because the output interface
   does not carry the required `if_id`. Diagnosis: `ip xfrm policy` showed
   `if_id 0x3eee6094` on the outbound policy; `nft monitor trace` showed
   the packet leaving via ens5 unencrypted.
2. **TCP MSS clamping**: AES-256-GCM + UDP-NAT-T adds ~100 bytes per packet.
   Backend VPC MSS=1440 still exceeded 1500 MTU after encapsulation. Fixed:
   nftables FORWARD chain clamps to MSS=1380. Confirmed via tcpdump: large
   HTTP responses now arrive; before fix only the last small segment got
   through (SACK evidence: seq 5713:6294 received, 1:5713 dropped).
3. **VPP FIB route for internal_ip**: `nat44 add static mapping local X
   external Y vrf N` does NOT auto-insert X/32 in VRF N's FIB. After DNAT
   (Y->X), VPP looked up X in VRF N, found no route, silently dropped
   (dpo-drop). Diagnosis: `vppctl show ip fib table N | grep internal_ip`
   returned nothing; ARP `who-has Y tell 10.255.0.5` on vpp-outer confirmed
   VPP was not forwarding. Fix: `install_device_nat()` now explicitly adds
   `vppctl ip route add X/32 table N via kern_ip vpp_tap`.

---

### T6 -- Per-site backend DNAT with overlapping customer_view_ip (Increment 6f-r)

**Status: PASSED.**

Test server: `172.16.53.126` (temporary, stood up for this test).
ipsecnode.toml on concentrator set `access_server.real_ip = "172.16.53.126"`
with port 8080 split to `172.16.53.6`.

**helena1 (62.238.96.148) -- customer_view_ip = 194.138.39.18 (routable range):**
```
curl -s -k http://194.138.39.18:8080   -> <h1>Skulking Klebsiella</h1>   (port 8080 split to .6)
curl -s -k https://194.138.39.18:8443  -> <h1>Obstinate Klebsiella</h1>  (stays on .126)
```

**helena2 (62.238.110.152) -- customer_view_ip = 10.1.2.3 (RFC 1918, overlapping):**
```
curl -s http://10.1.2.3:8080   -> <h1>Skulking Klebsiella</h1>   (port 8080 split to .6)
curl -s -k https://10.1.2.3:8443 -> <h1>Obstinate Klebsiella</h1>  (stays on .126)
```

Both tunnels active simultaneously. The RFC 1918 address on helena2 (`10.1.2.3`)
would have caused a key conflict in the shelved global-map approach but works
correctly with per-`xfrm-{hex}` nftables isolation.

Valkey nat record for helena2 during test:
```json
{"device_nat":[{"internal_ip":"192.168.13.133","global_ip":"198.51.100.134"}],
 "backend_nat":{"access_server":"10.1.2.3","sd_server":"194.138.39.21","em_server":"194.138.39.19"}}
```

**Remaining to test (T6 continuation):**
- Real backend hookup (172.16.53.6/7/8/9, aeroftp VIP 172.16.48.10).
- Reverse direction: backend -> device (Increment 6g) -- PHASE 1 DONE
  (established tunnel, validated helena2 + koi 2026-08-10). Phase 2 (dynamic
  bring-up when tunnel is down) still to design/test.
- FTP passive data via nf_conntrack_ftp helper.

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

## Open TODOs

### Proxy-pool conntrack flush is coarse (`conntrack -F`) (2026-08-22)

When a proxy leaves the `fleetipsec:proxy:pool`, the concentrator's
`proxy_pool_task` runs a full `conntrack -F` so device->proxy flows pinned (by
the `pool_proxy` jhash DNAT) to the departed member re-hash to a survivor. That
is correct but coarse: it momentarily drops the conntrack of EVERY flow on the
node (they re-create on the next packet, re-hashing to the same member under the
stable map, so it self-heals with a blip). IMPROVEMENT: delete only the entries
whose reply-source is a removed member, e.g. `conntrack -D --reply-src
<removed_proxy_ip>` per departed IP -- surgical, leaves unrelated flows
untouched. Same coarse-vs-surgical choice exists on the LVS (ipsecscale) for VPN
node removal. Low priority (scale-in is rare, re-create is cheap).

### FTP PASV reply IP -- aeroftp Rust code

`nf_nat_ftp` rewrites the IP embedded in PASV responses to the address the
kernel NAT layer sees as the post-SNAT source.  In our pipeline that is
`global_ip` (after VPP SNAT), not `customer_view_ip`.  A device that
strictly follows the PASV reply IP (rather than reusing the control-
connection address as most modern clients do) will therefore try to open
the FTP data connection to `global_ip:passive_port` instead of
`customer_view_ip:passive_port` -- which may be blocked by the customer
firewall.

**TODO:** Investigate whether the aeroftp load-balancer (sister project
`~/software/aerosuite`) exposes a Rust-level hook to override the IP
address written into PASV replies.  If it does, ipsecnode could supply
`customer_view_ip` (looked up from the Valkey backend_nat record for the
current site) to aeroftp so the PASV response carries the correct address
from the device's perspective, making `nf_nat_ftp` unnecessary for this
specific rewrite.

Entry point to look at: aeroftp's FTP proxy / ALG code in
`~/software/aerosuite/aeroftp/src/` -- search for PASV handling or the
place where the 227 response is constructed or forwarded.

### Passive-FTP data-port range routing + gateway reserved ports (2026-08-21)

aeroftp serves active AND passive FTP. For passive data connections the backend
reserves ports 20000-49999 (`net.ipv4.ip_local_reserved_ports = 20000-49999`),
so a device opens the PASV data channel to a port in that range. The ipsecnode
global service split currently DNATs ONLY 21/22 to the FTP VIP
(`ipsecnode_svcroute`: `iifname "vpp-outer" tcp dport { 21, 22 } dnat to <VIP>`),
so passive data connections on 20000-49999 are NOT steered to the FTP VIP and
fail. TWO coupled changes, do together:

1. **ipsecnode (fleetsuite): DONE (2026-08-21).** `SplitRule` gained
   `port_from`/`port_to`; `add_svcroute_rule`/`port_match` emit a nftables port
   RANGE (`tcp dport 20000-49999`). ipsecnode.toml routes 21/22 AND 20000-49999
   to the aeroftp VIP. (8080 was moved to the dynamic `proxy` ECMP pool in the
   same pass.) STILL to verify live: passive FTP through the 20000-49999 range.

2. **fleetshell-gateway (fleetshell):** the gateway container INITIATES
   connections TO devices; its ephemeral SOURCE-port range must AVOID
   20000-49999 so a gateway-initiated flow never collides with a passive-FTP
   data port. Apply `net.ipv4.ip_local_reserved_ports = 20000-49999` (or narrow
   `ip_local_port_range` below 20000) to the container. NOTE: a Dockerfile
   cannot set net.ipv4 sysctls at BUILD time (they are per-net-namespace runtime
   params); it must be applied at RUNTIME -- entrypoint sysctl (needs the cap) or
   the ECS task `systemControls` / K8s `securityContext.sysctls`. Record the
   chosen mechanism when implementing. See fleetshell/fleetshell-gateway/Dockerfile
   and the matching entry in fleetshell/AGENTS.md.

Cross-ref: the FTP PASV reply-IP TODO above is the related but SEPARATE issue
(PASV embedded-IP rewrite); this one is passive-port RANGE routing + gateway
reserved source ports.

### Backend membership + backend->device SNAT is static in ipsecnode.toml (2026-08-12)

Parked during a live 6g backend->device debug session (site 80.143.171.111,
Cisco FlexVPN, device 80.80.100.2/32, access_server view 194.138.39.18).
Three related gaps, to pick up in the coming days:

1. **NAT_PREFIX is not subscribed -- live nat-record edits do not apply.**
   `credentials::run_pubsub_loop` only reacts to `fleetipsec:psk:*`
   (`PSK_PREFIX`) and `fleetipsec:site:*` (`SITE_PREFIX`). A change to
   `fleetipsec:nat:*` does nothing until the CHILD_SA re-establishes, because
   the bnat map + 6g SNAT rule are built ONLY by `vpp::on_child_up` ->
   `setup_site_bnat`, which reads the nat record at child-up time. Symptom hit
   this session: `backend_nat.access_server` was added to Valkey AFTER the
   tunnel came up, so `setup_site_bnat` saw `backend_nat == None`, returned
   `SiteBnatState::empty()`, and `nft list table ip ipsecnode_bnat` stayed
   empty (no map, no PREROUTING dnat, no POSTROUTING snat).
   FIX: add a `NAT_PREFIX` handler that routes the event into the task owning
   `VrfCache` (via a channel) and rebuilds `site.bnat` there (tear down old
   handles from `SiteBnatState`, install new, update state). Note every name
   is deterministic from peer_ip (`xfrm-{if_id:08x}`, `bnat_{if_id:08x}`,
   `vpp-{if_id:08x}` where `if_id = u32::from(peer_ip)`), so the interface is
   always known from the key -- no discovery needed.

2. **backend_nat real_ip / membership is static in ipsecnode.toml and will
   drift as the ECS backend fleet scales.** The DNAT direction
   (device->backend, `customer_view_ip -> real_ip`) is fine if `real_ip` is a
   STABLE VIP -- aeroftp and fleetshell-proxy already front their fleets with
   an NLB VIP, so keep those in config/Valkey as stable per-role VIPs.
   PARTIALLY DONE (2026-08-22): the SNAT direction (backend->device) is now
   source-matched in `setup_site_bnat`/`add_bnat_snat`:
     - sd_server / em_server are SINGLE FIXED IPs (toml real_ip) -> a per-site
       map `bsnat_{hex}` `{ real_ip : customer_view }`, rule `oifname xfrm-{hex}
       ct state new snat ip to ip saddr map @bsnat_{hex}` (matched FIRST).
     - access_server is the DEFAULT catch-all (rule AFTER the map): `oifname
       xfrm-{hex} ct state new snat to <access_view>`. It is NOT source-scoped,
       because its backend may present multiple/dynamic source IPs (proxy pool,
       scaled tasks) -- anything that is not sd/em is SNAT'd to the access_view.
   REMAINING gap: this assumes sd/em are single fixed IPs. If sd/em ever scale
   to task IPs that INITIATE to devices, OR a non-access/non-sd/em backend needs
   its own view, the map needs LIVE per-role task-IP membership (the design
   below). The access catch-all already absorbs access-fleet scaling, so the
   live-membership work is now lower priority.
   APPROACH (agreed) for the live-membership case: a scaler (natural home:
   `ipsecscale`, master-only singleton) reconciles ECS membership -- trigger via
   EventBridge "ECS Task State Change" (or container self-register on startup)
   as a fast path, but the AUTHORITATIVE source is a `DescribeTasks`/Cloud Map
   query, plus a periodic full reconcile (~30-60 s) to GC ungracefully-dead
   tasks. Scaler writes `fleetipsec:backend:<role> -> [ips]` (snapshot,
   keyspace-notified); every `ipsecnode` subscribes (new `BACKEND_PREFIX`),
   keeps a `role -> set<member_ip>` index and applies incremental `nft
   add/delete element` deltas to every active site's `bsnat_{hex}` map (build
   from snapshot at site-up). Debounce/coalesce bursts; prefer element deltas
   over full rewrites (fan-out is O(sites x members)). Do it all in the
   `VrfCache`-owning task so child-updown / nat-record / membership events are
   serialized.

3. **Derive `local_ts` / `remote_ts` from the nat record instead of hand
   entry.** The portal that spools to Valkey has no `local_ts` field yet;
   without it `device_local_ts` / `device_remote_ts` default to `0.0.0.0/0`,
   which works as RESPONDER (StrongSwan narrows to the peer's proposal) but
   fails as INITIATOR against a picky CPE -> `TS_UNACCEPTABLE`, no CHILD_SA
   (confirmed this session: IKE_SA established, CHILD_SA rejected; the
   customer-initiated SA showed the Cisco ACL is exactly
   `local 194.138.39.18/32 <-> remote 80.80.100.2/32`).
   Both selectors are fully derivable from the nat record and should be, to
   avoid drift (esp. the multi-role case where `local_ts` must be the UNION of
   all present-role view IPs):
     - `remote_ts` = `device_nat[].internal_ip` (the device address the
       customer's ACL references -- internal_ip, NOT global_ip).
     - `local_ts`  = union of `backend_nat` present-role `customer_view_ip`s.
   Keep the explicit site-record `local_ts`/`remote_ts` fields as an OVERRIDE
   for genuine subnet cases (customer ACL permits a range, not a host).
   Wrinkle: `load_device_conn` in `credentials.rs` currently reads only the
   `SiteRecord`; deriving TS means also fetching the `NatRecord`
   (`fleetipsec:nat:*`) at conn-load time -- which dovetails with the
   NAT_PREFIX reload handler in (1) (a nat-record change must then also reload
   the conn's TS, not just the bnat map).

### 6g backend->device SNAT fails when internal_ip == global_ip (identity device NAT) (2026-08-12)

PROVEN root cause, same debug session (site 80.143.171.111, no device NAT so
`internal_ip == global_ip == 80.80.100.2`, access_server view 194.138.39.18).
The bnat map + POSTROUTING SNAT rule were correctly installed:
  `postrouting oifname "xfrm-508fab6f" ct state new snat to 194.138.39.18`
yet a backend SYN (172.16.54.218 -> 80.80.100.2:22) still egressed
`xfrm-508fab6f` with source 172.16.54.218 (NOT SNAT'd).

WHY: the backend->device packet hairpins through VPP and crosses the kernel
netfilter stack TWICE:
  Pass 1 (outside): arrives on ens5, kernel routes it out `dev vpp-outer`
    (the `global_ip/32 dev vpp-outer` route) into VPP. POSTROUTING runs with
    `oif=vpp-outer` -- the `oifname xfrm-{hex}` rule does NOT match.
    nf_nat sets a NULL (no-op) source-NAT binding and conntrack confirms it.
  Pass 2 (inside): VPP applies the device DNAT `80.80.100.2 -> 80.80.100.2`
    (an IDENTITY no-op), returns the packet on `vpp-{hex}`, kernel routes it
    out `xfrm-{hex}`. POSTROUTING runs with `oif=xfrm-{hex}` and the rule now
    matches -- but nf_nat sees source-NAT is already "done" for this ct entry
    and applies the stored NULL binding. The rule is never re-evaluated.
Because the device DNAT is identity, the 5-tuple is IDENTICAL on both passes,
so the kernel treats them as ONE conntrack flow and the SNAT decision is made
once -- on the pass where the rule cannot match.
Phase-1 (helena2) worked ONLY because `global_ip != internal_ip`: VPP changed
the destination inside the hop, so the two passes were different 5-tuples ->
two separate conntrack entries -> the inside entry got a fresh SNAT eval.
Proof: `conntrack -L` showed a single entry whose reply tuple was
`src=80.80.100.2 dst=172.16.54.218` (plain reverse, null binding); a working
SNAT would show the reply tuple as `... dst=194.138.39.18`.

FIX (design task -- do NOT hack live), two candidates:
  (a) CONNTRACK ZONES: assign `ct zone` by input interface in the `raw` table
      so the outside segment (ens5 / vpp-outer) and the inside segment
      (xfrm-* / vpp-*) are distinct conntrack flows. The inside flow then gets
      its own SNAT eval on xfrm egress, and the device reply (arriving on
      xfrm-{hex}, inside zone) still reverses it. Must stay consistent with the
      existing device->backend `svcroute` DNAT, which today relies on the
      5-tuple difference.
  (b) COMMIT SNAT ON THE OUTSIDE PASS: replace the rule with
      `oifname "vpp-outer" ct state new ip daddr <global_ip> snat to <access_view>`
      keyed on the device global_ip (discriminates backend->device, whose dst is
      the device, from device->backend, whose dst is the backend real_ip). The
      binding is then set on pass 1 and inherited by pass 2 -> no zones needed.
      Has its own return-path subtleties to validate; may be simpler than (a).
NOTE: there is NO clean live workaround for the identity case -- a distinct
`global_ip` (real device NAT) is what makes it "just work", but that is exactly
what the no-device-NAT requirement forbids (backends must address the device
as 80.80.100.2, so global_ip must equal internal_ip).

VALIDATED (2026-08-12): approach (a) conntrack zones works live. Put the inside
hops (xfrm-* / per-site vpp-{hex} taps) in ct zone 1 and leave the outside
(ens5 / vpp-outer) in the default zone 0, set in a raw-priority PREROUTING
chain (raw = -300, before the conntrack hook at -200). Exact validated table
(both the per-site and the wildcard form were confirmed; the wildcard form is
preferred -- it auto-covers every site with no per-site churn, and `ct zone
set` is non-terminating so the final `vpp-outer` rule pulls it back to zone 0
even though `vpp-*` matched it):
    table ip ipsecnode_ctzone {
        chain prerouting {
            type filter hook prerouting priority raw; policy accept;
            iifname "xfrm-*"    ct zone set 1
            iifname "vpp-*"     ct zone set 1
            iifname "vpp-outer" ct zone set 0
        }
    }
Then `conntrack -F` once to clear stale null-binding (zone 0) entries.
Result confirmed: backend SYN egressed xfrm-{hex} as src=194.138.39.18 and a
full TCP handshake completed to the Cisco device (SSH-2.0-Cisco-1.25). conntrack
then shows a zone=1 entry whose reply tuple is `src=80.80.100.2
dst=194.138.39.18` (SNAT bound) plus a separate zone=0 entry for the outside
hop. A single inside zone (1) is sufficient -- global_ip uniqueness (BGP /32)
guarantees inside 5-tuples never collide across sites, and ct zones are u16 so
per-site if_id (u32) would not fit anyway. Bonus: the zone split also gives the
device->backend `svcroute` port-split a fresh dst-NAT evaluation on the outside
hop, which the identity case otherwise breaks (dst-NAT already "done" on the
inside pass) -- retest that direction when wiring this in.
INSTALL POINT: this is a ONE-TIME static table, so add it in `vpp::init()`
(next to the `ipsecnode` mangle-table setup), NOT per-site in setup_site_vrf --
the `xfrm-*` / `vpp-*` wildcards cover all current and future sites. Do NOT put
it in the static AMI file `aerobake/fleetnode/_etc_nftables_fleetnode.nft`: that
file begins with `flush ruleset` and owns only the management `inet filter`
plane, so a `systemctl reload nftables` would wipe every `ipsecnode_*` data-plane
table. Keeping ctzone in `vpp::init()` gives it the same recover-on-restart
lifecycle as ipsecnode_mangle / ipsecnode_bnat / ipsecnode_svcroute.
READY CODE (parked, not yet applied): add `const NFT_CTZONE_TABLE:
&str = "ipsecnode_ctzone";`, an `init_nftables_ctzone()` fn mirroring
`init_nftables_svcroute` (emits the table above via `nft_batch`), and a single
`init_nftables_ctzone().await?;` call in `vpp::init()` right after
`init_nftables_bnat()`.

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
