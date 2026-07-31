#!/usr/bin/env bash
set -euo pipefail
#
# make_vip_reservation_enis.sh
#
# Creates two permanent "reservation" ENIs — one in each LVS public subnet —
# that hold the fixed secondary VIP addresses (.10 and .40) as secondary IPs.
# Because the IPs are allocated to these ENIs, AWS DHCP can never assign them
# as primary IPs to new instances.
#
# Boot behaviour (keepalived start_pre):
#   aeroplug ip --assign --allow-reassignment  steals the IP from the
#   reservation ENI onto the instance's eth0 atomically.
#
# Shutdown behaviour (keepalived stop_post):
#   aeroplug ip --eni <reservation-eni-id> --assign --allow-reassignment
#   moves the IP back from eth0 to the reservation ENI atomically, so there
#   is never a window where the IP is unallocated in the subnet pool.
#
# The reservation ENI IDs are added as ASG tags (ipsec-vip-reservation-eni)
# with PropagateAtLaunch=true so each instance can read them from IMDS.
#
# ENIs created (never attached to any instance):
#   fleetipsec-eni-vip-master  LVS-a (172.16.48.0/27)   secondary 172.16.48.10
#   fleetipsec-eni-vip-backup  LVS-b (172.16.48.32/27)  secondary 172.16.48.40
#
# SG: sg-lvs (sg-0406887cfe67d8f15) — required by create-network-interface.

set -euo pipefail

# ── Create master reservation ENI ────────────────────────────────────────────
echo "# Creating reservation ENI in LVS-a (172.16.48.0/27) for secondary .10"
MASTER_ENI_JSON=$(aws ec2 create-network-interface \
  --subnet-id subnet-0fe6d05bc51c16ed8 \
  --groups sg-0406887cfe67d8f15 \
  --description "FleetIPSec VIP reservation - holds 172.16.48.10 as secondary (never attached)" \
  --tag-specifications 'ResourceType=network-interface,Tags=[
    {Key=Name,Value=fleetipsec-eni-vip-master},
    {Key=ipsec-vip-reservation,Value=master}
  ]' \
  --region eu-west-2 \
  --output json)

MASTER_ENI_ID=$(echo "$MASTER_ENI_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin)['NetworkInterface']['NetworkInterfaceId'])")
echo "  Created: $MASTER_ENI_ID"

echo "# Assigning secondary IP 172.16.48.10 to $MASTER_ENI_ID"
aws ec2 assign-private-ip-addresses \
  --network-interface-id "$MASTER_ENI_ID" \
  --private-ip-addresses 172.16.48.10 \
  --region eu-west-2

# ── Create backup reservation ENI ────────────────────────────────────────────
echo ""
echo "# Creating reservation ENI in LVS-b (172.16.48.32/27) for secondary .40"
BACKUP_ENI_JSON=$(aws ec2 create-network-interface \
  --subnet-id subnet-071e009038ce73f87 \
  --groups sg-0406887cfe67d8f15 \
  --description "FleetIPSec VIP reservation - holds 172.16.48.40 as secondary (never attached)" \
  --tag-specifications 'ResourceType=network-interface,Tags=[
    {Key=Name,Value=fleetipsec-eni-vip-backup},
    {Key=ipsec-vip-reservation,Value=backup}
  ]' \
  --region eu-west-2 \
  --output json)

BACKUP_ENI_ID=$(echo "$BACKUP_ENI_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin)['NetworkInterface']['NetworkInterfaceId'])")
echo "  Created: $BACKUP_ENI_ID"

echo "# Assigning secondary IP 172.16.48.40 to $BACKUP_ENI_ID"
aws ec2 assign-private-ip-addresses \
  --network-interface-id "$BACKUP_ENI_ID" \
  --private-ip-addresses 172.16.48.40 \
  --region eu-west-2

# ── Tag both ASGs with the reservation ENI IDs ───────────────────────────────
echo ""
echo "# Tagging ASG fleetipsec-lvs-master: ipsec-vip-reservation-eni=$MASTER_ENI_ID"
aws autoscaling create-or-update-tags \
  --tags "ResourceId=fleetipsec-lvs-master,ResourceType=auto-scaling-group,Key=ipsec-vip-reservation-eni,Value=${MASTER_ENI_ID},PropagateAtLaunch=true" \
  --region eu-west-2

echo "# Tagging ASG fleetipsec-lvs-backup: ipsec-vip-reservation-eni=$BACKUP_ENI_ID"
aws autoscaling create-or-update-tags \
  --tags "ResourceId=fleetipsec-lvs-backup,ResourceType=auto-scaling-group,Key=ipsec-vip-reservation-eni,Value=${BACKUP_ENI_ID},PropagateAtLaunch=true" \
  --region eu-west-2

# ── Verify ───────────────────────────────────────────────────────────────────
echo ""
echo "# Verification — reservation ENIs:"
aws ec2 describe-network-interfaces \
  --network-interface-ids "$MASTER_ENI_ID" "$BACKUP_ENI_ID" \
  --query 'NetworkInterfaces[*].{Name:TagSet[?Key==`Name`]|[0].Value,ENI:NetworkInterfaceId,Status:Status,Primary:PrivateIpAddress,Secondaries:PrivateIpAddresses[?Primary==`false`]|[*].PrivateIpAddress}' \
  --region eu-west-2 --output table

echo ""
echo "# Verification — ASG tags:"
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names fleetipsec-lvs-master fleetipsec-lvs-backup \
  --query 'AutoScalingGroups[*].{ASG:AutoScalingGroupName,Tags:Tags[?starts_with(Key,`ipsec-vip`)].{K:Key,V:Value}}' \
  --region eu-west-2 --output json

RESULT:

./make_vip_reservation_enis.sh                                                                                                          6m29s214ms  09:31:26
# Creating reservation ENI in LVS-a (172.16.48.0/27) for secondary .10
  Created: eni-09521bac16b500985
# Assigning secondary IP 172.16.48.10 to eni-09521bac16b500985
{
    "NetworkInterfaceId": "eni-09521bac16b500985",
    "AssignedPrivateIpAddresses": [
        {
            "PrivateIpAddress": "172.16.48.10"
        }
    ],
    "AssignedIpv4Prefixes": []
}

# Creating reservation ENI in LVS-b (172.16.48.32/27) for secondary .40
  Created: eni-02b0a8fcd1528ff1a
# Assigning secondary IP 172.16.48.40 to eni-02b0a8fcd1528ff1a
{
    "NetworkInterfaceId": "eni-02b0a8fcd1528ff1a",
    "AssignedPrivateIpAddresses": [
        {
            "PrivateIpAddress": "172.16.48.40"
        }
    ],
    "AssignedIpv4Prefixes": []
}

# Tagging ASG fleetipsec-lvs-master: ipsec-vip-reservation-eni=eni-09521bac16b500985
# Tagging ASG fleetipsec-lvs-backup: ipsec-vip-reservation-eni=eni-02b0a8fcd1528ff1a

# Verification — reservation ENIs:
-------------------------------------------------------------------------------------
|                             DescribeNetworkInterfaces                             |
+------------------------+-----------------------------+---------------+------------+
|           ENI          |            Name             |    Primary    |  Status    |
+------------------------+-----------------------------+---------------+------------+
|  eni-02b0a8fcd1528ff1a |  fleetipsec-eni-vip-backup  |  172.16.48.58 |  available |
+------------------------+-----------------------------+---------------+------------+
||                                   Secondaries                                   ||
|+---------------------------------------------------------------------------------+|
||  172.16.48.40                                                                   ||
|+---------------------------------------------------------------------------------+|
|                             DescribeNetworkInterfaces                             |
+------------------------+-----------------------------+---------------+------------+
|           ENI          |            Name             |    Primary    |  Status    |
+------------------------+-----------------------------+---------------+------------+
|  eni-09521bac16b500985 |  fleetipsec-eni-vip-master  |  172.16.48.8  |  available |
+------------------------+-----------------------------+---------------+------------+
||                                   Secondaries                                   ||
|+---------------------------------------------------------------------------------+|
||  172.16.48.10                                                                   ||
|+---------------------------------------------------------------------------------+|

