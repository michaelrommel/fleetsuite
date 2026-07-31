#!/usr/bin/env bash
set -euo pipefail
#
# make_tag_vip_inside.sh
#
# Adds the ipsec-vip-inside tag to both LVS ASGs (with PropagateAtLaunch=true)
# so every future instance launched by the ASG inherits it via IMDS.
#
# ipsec-vip-inside = the fixed secondary private IP that aeroplug assigns to
# eth0 at boot (in keepalived start_pre) and that the customer-facing EIP
# always points to on the current VRRP master.
#
# Numbering convention — same offset (+10) within each LVS /27:
#   master subnet 172.16.48.0/27  → secondary 172.16.48.10
#   backup subnet 172.16.48.32/27 → secondary 172.16.48.40
#
# No management EIPs are needed: the LT has AssociatePublicIpAddress=true,
# so each instance gets its own ephemeral public IP on the primary private IP
# at launch.  That auto-IP remains regardless of EIP movements, giving the
# former master permanent outbound internet access after failover.

echo "# Tagging ASG fleetipsec-lvs-master: ipsec-vip-inside=172.16.48.10"
aws autoscaling create-or-update-tags \
  --tags \
    "ResourceId=fleetipsec-lvs-master,ResourceType=auto-scaling-group,Key=ipsec-vip-inside,Value=172.16.48.10,PropagateAtLaunch=true" \
  --region eu-west-2

echo "# Tagging ASG fleetipsec-lvs-backup: ipsec-vip-inside=172.16.48.40"
aws autoscaling create-or-update-tags \
  --tags \
    "ResourceId=fleetipsec-lvs-backup,ResourceType=auto-scaling-group,Key=ipsec-vip-inside,Value=172.16.48.40,PropagateAtLaunch=true" \
  --region eu-west-2

echo ""
echo "# Verification — ASG tags:"
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names fleetipsec-lvs-master fleetipsec-lvs-backup \
  --query 'AutoScalingGroups[*].{Name:AutoScalingGroupName,Tags:Tags[?Key==`ipsec-vip-inside`]|[0].{Key:Key,Value:Value,Propagate:PropagateAtLaunch}}' \
  --region eu-west-2 --output json

echo ""
echo "# NOTE: Running instances do NOT need tagging — they will be terminated"
echo "# and relaunched.  The ASG propagates the tag to each new instance."
echo "# New instances will read the tag from IMDS in keepalived start_pre."

RESULT

# Tagging ASG fleetipsec-lvs-master: ipsec-vip-inside=172.16.48.10
# Tagging ASG fleetipsec-lvs-backup: ipsec-vip-inside=172.16.48.40

# Verification — ASG tags:
[
    {
        "Name": "fleetipsec-lvs-backup",
        "Tags": {
            "Key": "ipsec-vip-inside",
            "Value": "172.16.48.40",
            "Propagate": true
        }
    },
    {
        "Name": "fleetipsec-lvs-master",
        "Tags": {
            "Key": "ipsec-vip-inside",
            "Value": "172.16.48.10",
            "Propagate": true
        }
    }
]

# NOTE: Running instances do NOT need tagging — they will be terminated
# and relaunched.  The ASG propagates the tag to each new instance.
# New instances will read the tag from IMDS in keepalived start_pre.

