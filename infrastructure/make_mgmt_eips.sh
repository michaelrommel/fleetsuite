#!/usr/bin/env bash
set -euo pipefail
#
# make_mgmt_eips.sh
#
# Allocates two permanent management EIPs - one per LVS node - and tags
# both ASGs so each instance can read its allocation ID from IMDS at boot.
#
# These EIPs are associated to the PRIMARY private IP of eth0 early in
# keepalived start_pre (via ipsecpulse associate-mgmt-eip), before anything
# else that would remove the auto-assigned public IP.  They are NEVER
# disassociated during normal operation; when an instance is terminated the
# ENI is deleted and AWS automatically returns the EIP to the unassociated
# pool, ready for the replacement instance's start_pre to claim it.
#
# The customer-facing EIP (eipalloc-095ac59bb763cd2ce) is separately
# associated to the SECONDARY IP (.10 / .40) on VRRP master transition.
# Having the management EIP on the primary means the former master always
# has outbound internet regardless of where the customer EIP sits.

# ── Allocate master management EIP ───────────────────────────────────────────
echo "# Allocating management EIP for master node"
MASTER_EIP_JSON=$(aws ec2 allocate-address \
  --domain vpc \
  --tag-specifications 'ResourceType=elastic-ip,Tags=[
    {Key=Name,Value=FleetShell-IPSec-mgmt-master}
  ]' \
  --region eu-west-2 --output json)

MASTER_EIP_ALLOC=$(echo "$MASTER_EIP_JSON" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d['AllocationId'])")
MASTER_EIP_IP=$(echo "$MASTER_EIP_JSON" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d['PublicIp'])")
echo "  Master mgmt EIP: $MASTER_EIP_IP  ($MASTER_EIP_ALLOC)"

# ── Allocate backup management EIP ───────────────────────────────────────────
echo ""
echo "# Allocating management EIP for backup node"
BACKUP_EIP_JSON=$(aws ec2 allocate-address \
  --domain vpc \
  --tag-specifications 'ResourceType=elastic-ip,Tags=[
    {Key=Name,Value=FleetShell-IPSec-mgmt-backup}
  ]' \
  --region eu-west-2 --output json)

BACKUP_EIP_ALLOC=$(echo "$BACKUP_EIP_JSON" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d['AllocationId'])")
BACKUP_EIP_IP=$(echo "$BACKUP_EIP_JSON" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d['PublicIp'])")
echo "  Backup mgmt EIP: $BACKUP_EIP_IP  ($BACKUP_EIP_ALLOC)"

# ── Tag both ASGs ─────────────────────────────────────────────────────────────
echo ""
echo "# Tagging ASG fleetipsec-lvs-master: ipsec-mgmt-eip=$MASTER_EIP_ALLOC"
aws autoscaling create-or-update-tags \
  --tags "ResourceId=fleetipsec-lvs-master,ResourceType=auto-scaling-group,Key=ipsec-mgmt-eip,Value=${MASTER_EIP_ALLOC},PropagateAtLaunch=true" \
  --region eu-west-2

echo "# Tagging ASG fleetipsec-lvs-backup: ipsec-mgmt-eip=$BACKUP_EIP_ALLOC"
aws autoscaling create-or-update-tags \
  --tags "ResourceId=fleetipsec-lvs-backup,ResourceType=auto-scaling-group,Key=ipsec-mgmt-eip,Value=${BACKUP_EIP_ALLOC},PropagateAtLaunch=true" \
  --region eu-west-2

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
echo "# All EIPs:"
aws ec2 describe-addresses \
  --region eu-west-2 \
  --query 'Addresses[*].{Name:Tags[?Key==`Name`]|[0].Value,AllocId:AllocationId,PublicIp:PublicIp,AssocENI:NetworkInterfaceId,PrivateIp:PrivateIpAddress}' \
  --output table

echo ""
echo "# ASG ipsec-mgmt-eip tags:"
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names fleetipsec-lvs-master fleetipsec-lvs-backup \
  --query 'AutoScalingGroups[*].{ASG:AutoScalingGroupName,Tag:Tags[?Key==`ipsec-mgmt-eip`]|[0].Value}' \
  --region eu-west-2 --output table

echo ""
echo "# Next step: terminate both broken instances so the ASG relaunches"
echo "# them fresh with the new AMI + management EIP code:"
echo "#"
echo "#   aws ec2 terminate-instances \\"
echo "#     --instance-ids i-0a1f2f5d2012ede35 i-0c018df0df00a3d15 \\"
echo "#     --region eu-west-2"

RESULT

# Allocating management EIP for master node
  Master mgmt EIP: 35.176.247.157  (eipalloc-0f277e465ac3f85c7)

# Allocating management EIP for backup node
  Backup mgmt EIP: 18.134.100.197  (eipalloc-0e14279fac0ca9102)

# Tagging ASG fleetipsec-lvs-master: ipsec-mgmt-eip=eipalloc-0f277e465ac3f85c7
# Tagging ASG fleetipsec-lvs-backup: ipsec-mgmt-eip=eipalloc-0e14279fac0ca9102

# All EIPs:
----------------------------------------------------------------------------------------------------------------------------
|                                                     DescribeAddresses                                                    |
+----------------------------+------------------------+--------------------------------+----------------+------------------+
|           AllocId          |       AssocENI         |             Name               |   PrivateIp    |    PublicIp      |
+----------------------------+------------------------+--------------------------------+----------------+------------------+
|  eipalloc-0e15b056573b3e1b0|  eni-03834032bff5d560c |  None                          |  172.16.8.112  |  18.132.252.72   |
|  eipalloc-0e14279fac0ca9102|  None                  |  FleetShell-IPSec-mgmt-backup  |  None          |  18.134.100.197  |
|  eipalloc-0a7705045ddc58d70|  eni-04db39bce3b6ebb24 |  None                          |  172.16.24.145 |  18.134.28.241   |
|  eipalloc-095ac59bb763cd2ce|  None                  |  FleetShell-IPSec-VIP          |  None          |  3.11.124.22     |
|  eipalloc-0f277e465ac3f85c7|  None                  |  FleetShell-IPSec-mgmt-master  |  None          |  35.176.247.157  |
|  eipalloc-0ac2fb2dd51415b30|  eni-04a01e0dde9e8aaa4 |  FleetShell-IPSec-NatGW        |  172.16.48.24  |  35.177.240.42   |
|  eipalloc-06255c11a79ae8f3e|  eni-03f906c20dcab27ef |  None                          |  172.16.0.105  |  35.179.72.126   |
|  eipalloc-088d63738b6ce156e|  eni-0b4f80645ca3cf4b1 |  None                          |  172.16.26.245 |  51.24.47.201    |
+----------------------------+------------------------+--------------------------------+----------------+------------------+

# ASG ipsec-mgmt-eip tags:
---------------------------------------------------------
|               DescribeAutoScalingGroups               |
+------------------------+------------------------------+
|           ASG          |             Tag              |
+------------------------+------------------------------+
|  fleetipsec-lvs-backup |  eipalloc-0e14279fac0ca9102  |
|  fleetipsec-lvs-master |  eipalloc-0f277e465ac3f85c7  |
+------------------------+------------------------------+

