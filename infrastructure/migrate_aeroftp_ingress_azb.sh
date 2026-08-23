#!/usr/bin/env bash
set -euo pipefail
#
# migrate_aeroftp_ingress_azb.sh
#
# Move the aeroftp LVS INGRESS (the outside / client-facing VIP plane, eth0)
# out of the old public "AeroFTP-public2" subnet (172.16.16.0/20 -> IGW) and
# into the IPSec Backend-b subnet (172.16.54.0/24, AZ-b) so that:
#
#   * the VPN concentrators can reach the aeroftp VIP directly over VPC-local
#     routing (dst 172.16.54.10 from rtb-vpn is delivered in-VPC), and
#   * aeroftp's replies to a device's non-VPC global_ip follow Backend-b's
#     route table rtb-backend (default -> Return GW master eth0), i.e. back
#     down the tunnel via the Return GW -- exactly like the other IPSec
#     backends (172.16.53.6/8/9 in Backend-a).
#
# The concentrator path REPLACES the old internet-facing outside VIP
# (172.16.29.100) entirely. The new outside VIP is 172.16.54.10.
#
# The inside / backend-data-plane (eth1) and HA-sync (eth2) NICs are NOT
# touched by this migration -- they stay in the AeroFTP-backend subnet
# (172.16.32.64/26, AZ-b). Only the ingress (eth0) moves.
#
# Both aeroftp load balancers are ASG-managed (aeroftp-loadbalancer-primary
# and -backup, each min0/desired1/max2) launched from the shared launch
# template lt-07d1af574cc3973af ("aeroscale"). The relaunch is therefore a
# launch-template + ASG subnet change followed by an instance cycle.
#
# eth0 on the aeroscale (LB) AMI is plain DHCP (no baked gateway), so moving it
# into Backend-b picks up the 172.16.54.1 router automatically. eth1 (inside)
# and eth2 (HA sync) are boot-attached from the 172.16.32.64/26 pool via
# aeroplug and are UNAFFECTED by this migration.
#
# =====================================================================
# >>> AMI-SIDE PREREQUISITE (aerosuite_main -- do this FIRST) <<<
# =====================================================================
# The aeroscale LB AMI bakes the OLD outside VIP as the LVS return-path SNAT
# source in aerobake/aeroscale/_etc_nftables_aeroscaler.nft:
#
#       chain do_snat { snat to 172.16.29.100 }
#
# Return traffic from the backend FTP servers (eth1) is SNAT'd to this address
# so the client (here: the concentrator, on behalf of the device global_ip)
# sees replies from the VIP. With the VIP now 172.16.54.10, a stale SNAT to
# 172.16.29.100 makes every reply unroutable. Before cycling the instances you
# MUST update that rule to `snat to 172.16.54.10` (better: render it from the
# aeroftp-vip-outside tag at boot) and rebuild the aeroscale AMI, then point
# the launch template at it via NEW_AMI in STEP 2. This is the "stable setup"
# rework you flagged; it lives in aerosuite_main and is NOT done by this script.
# =====================================================================
#
# Idempotent where AWS allows; the disruptive instance cycle in STEP 4 is
# guarded by CONFIRM=yes.

export AWS_PAGER=""
REGION="eu-west-2"

# ---- Targets -------------------------------------------------------------
BACKEND_B_SUBNET="subnet-08213d03f2940855c"   # FleetShell-IPSec-Backend-b, 172.16.54.0/24, AZ-b, rtb-backend
NEW_VIP_OUTSIDE="172.16.54.10"                # new aeroftp ingress VIP (was 172.16.29.100)

AEROFTP_LT_ID="lt-07d1af574cc3973af"          # shared LT "aeroscale"
AEROFTP_SG="sg-06d737ea5595c275d"             # aeroftp-FTPAccess (eth0 ingress SG)

ASG_PRIMARY="aeroftp-loadbalancer-primary"
ASG_BACKUP="aeroftp-loadbalancer-backup"

# Optionally repoint the LT at a rebuilt AMI (see AMI-SIDE PREREQUISITE).
# Leave empty to keep the LT's current AMI.
NEW_AMI="ami-0f41adefe5a5c4124"

# Device global_ip source range that reaches the aeroftp VIP AFTER VPP SNAT on
# the concentrator (src = device global identity). Field devices now cover
# almost the entire IPv4 space -- the routing model excludes only the internal
# supernets (10.183.0.0/16, 172.16.0.0/16, ...) and sends everything else to
# the Return GWs / devices. The ingress SG must therefore be practically open,
# so this defaults to 0.0.0.0/0. Override with GLOBAL_IP_CIDR=... to narrow it.
GLOBAL_IP_CIDR="${GLOBAL_IP_CIDR:-0.0.0.0/0}"

# ==========================================================================
# STEP 1 -- open the aeroftp ingress SG for FTP from the device global range
# --------------------------------------------------------------------------
# The concentrator forwards decapsulated device traffic with src = global_ip
# (after VPP SNAT) to the VIP. Because field devices span almost the whole
# IPv4 space, GLOBAL_IP_CIDR is 0.0.0.0/0 by default. The aeroftp SG today
# only permits FTP from its own SG / a mgmt /32, so the concentrator path is
# blocked without these rules:
#   * 21           FTP control
#   * 22           SFTP
#   * 20000-49999  passive-FTP data range (aeroftp ip_local_reserved_ports)
# ==========================================================================
echo "STEP 1: authorizing FTP ingress on ${AEROFTP_SG} from ${GLOBAL_IP_CIDR} ..."
add_rule() {
  local proto="$1" from="$2" to="$3"
  if aws ec2 authorize-security-group-ingress \
       --group-id "${AEROFTP_SG}" \
       --ip-permissions "IpProtocol=${proto},FromPort=${from},ToPort=${to},IpRanges=[{CidrIp=${GLOBAL_IP_CIDR},Description=ipsec-concentrator-ftp}]" \
       --region "${REGION}" 2>/tmp/aeroftp_sg_err; then
    echo "  OK: ${proto}/${from}-${to} from ${GLOBAL_IP_CIDR} added."
  elif grep -q "InvalidPermission.Duplicate" /tmp/aeroftp_sg_err; then
    echo "  OK: ${proto}/${from}-${to} already present (idempotent)."
  else
    cat /tmp/aeroftp_sg_err >&2; exit 1
  fi
}
add_rule tcp 21 21
add_rule tcp 22 22
add_rule tcp 20000 49999
rm -f /tmp/aeroftp_sg_err

# ==========================================================================
# STEP 2 -- new launch-template version: eth0 in Backend-b + new VIP tag
# --------------------------------------------------------------------------
# The LT declares only eth0 (DeviceIndex 0); eth1/eth2 are boot-attached and
# are unaffected. We change NetworkInterfaces[0].SubnetId to Backend-b and the
# aeroftp-vip-outside instance tag to the new VIP. If NEW_AMI is set, the AMI
# is repointed too (AMI-SIDE PREREQUISITE).
# ==========================================================================
echo "STEP 2: creating new LT version (${AEROFTP_LT_ID}) for Backend-b + VIP ${NEW_VIP_OUTSIDE} ..."

LT_DATA=$(cat <<JSON
{
  "NetworkInterfaces": [
    {
      "DeviceIndex": 0,
      "Description": "Outside Interface",
      "Groups": ["${AEROFTP_SG}", "sg-011b3ebfcfbcca22d"],
      "SubnetId": "${BACKEND_B_SUBNET}"
    }
  ],
  "TagSpecifications": [
    {
      "ResourceType": "instance",
      "Tags": [
        {"Key": "aeroftp-vip-outside", "Value": "${NEW_VIP_OUTSIDE}"},
        {"Key": "aeroftp-vip-inside",  "Value": "172.16.32.10"},
        {"Key": "aeroftp-slot-offset", "Value": "20"},
        {"Key": "aeroftp-slot-count",  "Value": "20"}
      ]
    }
  ]$( [ -n "${NEW_AMI}" ] && printf ',\n  "ImageId": "%s"' "${NEW_AMI}" )
}
JSON
)

NEW_VER=$(aws ec2 create-launch-template-version \
  --launch-template-id "${AEROFTP_LT_ID}" \
  --source-version '$Latest' \
  --launch-template-data "${LT_DATA}" \
  --region "${REGION}" \
  --query 'LaunchTemplateVersion.VersionNumber' --output text)
echo "  created LT version ${NEW_VER}"

aws ec2 modify-launch-template \
  --launch-template-id "${AEROFTP_LT_ID}" \
  --default-version "${NEW_VER}" \
  --region "${REGION}" >/dev/null
echo "  set LT default version -> ${NEW_VER}"

# ==========================================================================
# STEP 3 -- repoint both ASGs' subnet (VPCZoneIdentifier) to Backend-b
# ==========================================================================
echo "STEP 3: moving ASG subnets to Backend-b ..."
for asg in "${ASG_PRIMARY}" "${ASG_BACKUP}"; do
  aws autoscaling update-auto-scaling-group \
    --auto-scaling-group-name "${asg}" \
    --vpc-zone-identifier "${BACKEND_B_SUBNET}" \
    --region "${REGION}"
  echo "  ${asg} -> ${BACKEND_B_SUBNET}"
done

# ==========================================================================
# STEP 4 -- cycle the instances so they relaunch in Backend-b (DISRUPTIVE)
# --------------------------------------------------------------------------
# Guarded: re-run with CONFIRM=yes to actually terminate the running LBs.
# The ASG (desired=1) replaces each terminated instance from the new LT.
# ==========================================================================
if [ "${CONFIRM:-no}" != "yes" ]; then
  cat <<EOF

STEP 4 (instance cycle) SKIPPED -- this is the disruptive step.
Confirm the AMI-SIDE PREREQUISITE is done, then re-run with:

    CONFIRM=yes bash infrastructure/migrate_aeroftp_ingress_azb.sh

EOF
  exit 0
fi

echo "STEP 4: cycling aeroftp LB instances (CONFIRM=yes) ..."
for asg in "${ASG_PRIMARY}" "${ASG_BACKUP}"; do
  iid=$(aws autoscaling describe-auto-scaling-groups \
          --auto-scaling-group-names "${asg}" \
          --region "${REGION}" \
          --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
  if [ "${iid}" != "None" ] && [ -n "${iid}" ]; then
    echo "  terminating ${iid} in ${asg} (ASG will relaunch in Backend-b) ..."
    aws autoscaling terminate-instance-in-auto-scaling-group \
      --instance-id "${iid}" \
      --no-should-decrement-desired-capacity \
      --region "${REGION}" >/dev/null
  else
    echo "  ${asg}: no running instance to terminate (ASG will launch fresh)."
  fi
done

echo
echo "Done. Watch the new instances come up in ${BACKEND_B_SUBNET} and verify"
echo "the outside VIP ${NEW_VIP_OUTSIDE} is assigned (aws ec2 describe-network-interfaces"
echo "--filters Name=addresses.private-ip-address,Values=${NEW_VIP_OUTSIDE})."
