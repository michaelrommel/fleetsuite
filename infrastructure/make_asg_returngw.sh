#!/usr/bin/env bash
set -euo pipefail
#
# make_asg_returngw.sh
#
# Creates two Auto Scaling Groups for the Return GW HA pair.
# Each ASG has min=max=desired=1 so exactly one instance is maintained.
#
# At boot the instance:
#   1. Reads role from IMDS tag (ipsec-gw-role)
#   2. Claims the management ENI (tag ipsec-gw-mgmt=$ROLE) via aeroplug eni --attach
#   3. Claims the BGP ENI (tag ipsec-gw-bgp=$ROLE) via aeroplug eni --takeover
#      --takeover force-detaches from the old instance if it is still attached.
#
# Prerequisites (run first, in order):
#   make_enis_returngw.sh     -- management ENIs (eth1)
#   make_bgp_enis_returngw.sh -- BGP ENIs (eth2, fixed IPs)
#   make_rtb_backend.sh       -- rtb-backend (set RTB_BACKEND below)
#   make_lt_returngw.sh       -- single LT fleetipsec-lt-returngw

RTB_BACKEND="${RTB_BACKEND:-rtb-SETME}"

if [ "$RTB_BACKEND" = "rtb-SETME" ]; then
  echo "ERROR: set RTB_BACKEND env var to the route table ID from make_rtb_backend.sh"
  exit 1
fi

echo "# Creating ASG fleetipsec-returngw-master"
echo "#   Subnet: ReturnGW-a (subnet-017d5b3a6331e26a7, 172.16.51.0/27, AZ-a)"
echo "#   BGP ENI: ipsec-gw-bgp=master  fixed IP 172.16.51.4 (claimed via --takeover)"
echo "#   Mgmt ENI: ipsec-gw-mgmt=master  fixed IP 172.16.51.68"

aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name fleetipsec-returngw-master \
  --launch-template "LaunchTemplateName=fleetipsec-lt-returngw,Version=\$Latest" \
  --min-size 1 --max-size 1 --desired-capacity 1 \
  --vpc-zone-identifier "subnet-017d5b3a6331e26a7" \
  --health-check-type EC2 \
  --health-check-grace-period 120 \
  --tags \
    "ResourceId=fleetipsec-returngw-master,ResourceType=auto-scaling-group,Key=Name,Value=fleetipsec-returngw-master,PropagateAtLaunch=true" \
    "ResourceId=fleetipsec-returngw-master,ResourceType=auto-scaling-group,Key=ipsec-gw-cluster,Value=fleetipsec-returngw,PropagateAtLaunch=true" \
    "ResourceId=fleetipsec-returngw-master,ResourceType=auto-scaling-group,Key=ipsec-gw-role,Value=master,PropagateAtLaunch=true" \
    "ResourceId=fleetipsec-returngw-master,ResourceType=auto-scaling-group,Key=ipsec-gw-peer-mgmt-ip,Value=172.16.51.100,PropagateAtLaunch=true" \
    "ResourceId=fleetipsec-returngw-master,ResourceType=auto-scaling-group,Key=ipsec-gw-rtb,Value=${RTB_BACKEND},PropagateAtLaunch=true" \
  --region eu-west-2

echo ""
echo "# Creating ASG fleetipsec-returngw-backup"
echo "#   Subnet: ReturnGW-b (subnet-082703ab573f0f4e9, 172.16.51.32/27, AZ-b)"
echo "#   BGP ENI: ipsec-gw-bgp=backup  fixed IP 172.16.51.36 (claimed via --takeover)"
echo "#   Mgmt ENI: ipsec-gw-mgmt=backup  fixed IP 172.16.51.100"

aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name fleetipsec-returngw-backup \
  --launch-template "LaunchTemplateName=fleetipsec-lt-returngw,Version=\$Latest" \
  --min-size 1 --max-size 1 --desired-capacity 1 \
  --vpc-zone-identifier "subnet-082703ab573f0f4e9" \
  --health-check-type EC2 \
  --health-check-grace-period 120 \
  --tags \
    "ResourceId=fleetipsec-returngw-backup,ResourceType=auto-scaling-group,Key=Name,Value=fleetipsec-returngw-backup,PropagateAtLaunch=true" \
    "ResourceId=fleetipsec-returngw-backup,ResourceType=auto-scaling-group,Key=ipsec-gw-cluster,Value=fleetipsec-returngw,PropagateAtLaunch=true" \
    "ResourceId=fleetipsec-returngw-backup,ResourceType=auto-scaling-group,Key=ipsec-gw-role,Value=backup,PropagateAtLaunch=true" \
    "ResourceId=fleetipsec-returngw-backup,ResourceType=auto-scaling-group,Key=ipsec-gw-peer-mgmt-ip,Value=172.16.51.68,PropagateAtLaunch=true" \
    "ResourceId=fleetipsec-returngw-backup,ResourceType=auto-scaling-group,Key=ipsec-gw-rtb,Value=${RTB_BACKEND},PropagateAtLaunch=true" \
  --region eu-west-2

echo ""
echo "Return GW ASGs created."
echo "Next steps:"
echo "  1. Verify instances launch and pass health checks:"
echo "     aws ec2 describe-instances --filters 'Name=tag:ipsec-gw-cluster,Values=fleetipsec-returngw' --region eu-west-2"
echo "  2. Enable FRR on the running VPN concentrator:"
echo "     sudo systemctl enable --now frr"
echo "  3. Verify BGP sessions (T3 test):"
echo "     On Return GW: sudo vtysh -c 'show bgp summary'"
echo "     On VPN node:  sudo vtysh -c 'show bgp summary'"

# Creating ASG fleetipsec-returngw-master
#   Subnet: ReturnGW-a (subnet-017d5b3a6331e26a7, 172.16.51.0/27, AZ-a)
#   BGP ENI: ipsec-gw-bgp=master  fixed IP 172.16.51.4 (claimed via --takeover)
#   Mgmt ENI: ipsec-gw-mgmt=master  fixed IP 172.16.51.68

# Creating ASG fleetipsec-returngw-backup
#   Subnet: ReturnGW-b (subnet-082703ab573f0f4e9, 172.16.51.32/27, AZ-b)
#   BGP ENI: ipsec-gw-bgp=backup  fixed IP 172.16.51.36 (claimed via --takeover)
#   Mgmt ENI: ipsec-gw-mgmt=backup  fixed IP 172.16.51.100

# Return GW ASGs created.
# Next steps:
#   1. Verify instances launch and pass health checks:
#      aws ec2 describe-instances --filters 'Name=tag:ipsec-gw-cluster,Values=fleetipsec-returngw' --region eu-west-2
#   2. Enable FRR on the running VPN concentrator:
#      sudo systemctl enable --now frr
#   3. Verify BGP sessions (T3 test):
#      On Return GW: sudo vtysh -c 'show bgp summary'
#      On VPN node:  sudo vtysh -c 'show bgp summary'

