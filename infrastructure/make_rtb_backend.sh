#!/usr/bin/env bash
set -euo pipefail
#
# make_rtb_backend.sh
#
# Creates the route table for backend servers.
#
# The Return GW is the default gateway for backend servers.  On VRRP MASTER
# election the notify-master script calls:
#   fleetpulse notify-master
# which upserts 0.0.0.0/0 -> master-ReturnGW-eth0-ENI in this route table.
#
# The route table is created empty (no default route).  The master Return GW
# will add the default route on first MASTER election.
#
# Associate this route table with backend server subnets when they are created.
#
# Tag the ASGs for both Return GW nodes with the resulting route table ID:
#   aws autoscaling create-or-update-tags \
#     --tags ResourceId=fleetipsec-returngw-master,ResourceType=auto-scaling-group,...
#            Key=ipsec-gw-rtb,Value=<rtb-ID>,PropagateAtLaunch=true
#   (repeated for fleetipsec-returngw-backup)

echo "# Creating FleetShell-IPSec-rtb-backend (no default route -- set by notify-master)"
aws ec2 create-route-table \
  --vpc-id vpc-0595e17ce290fb050 \
  --region eu-west-2 \
  --tag-specifications 'ResourceType=route-table,Tags=[
    {Key=Name,Value=FleetShell-IPSec-rtb-backend}
  ]'

echo ""
echo "NOTE: Record the rtb-ID from the output above."
echo "      Set it as the ipsec-gw-rtb tag on both Return GW ASGs:"
echo "        make_asg_returngw.sh uses RTB_BACKEND env var -- set it before running."

# RESULT
# Creating FleetShell-IPSec-rtb-backend (no default route -- set by notify-master)
# {
#     "RouteTable": {
#         "Associations": [],
#         "PropagatingVgws": [],
#         "RouteTableId": "rtb-0a446e715fc3ec757",
#         "Routes": [
#             {
#                 "DestinationCidrBlock": "172.16.0.0/16",
#                 "GatewayId": "local",
#                 "Origin": "CreateRouteTable",
#                 "State": "active"
#             },
#             {
#                 "DestinationIpv6CidrBlock": "2a05:d01c:613:7200::/56",
#                 "GatewayId": "local",
#                 "Origin": "CreateRouteTable",
#                 "State": "active"
#             }
#         ],
#         "Tags": [
#             {
#                 "Key": "Name",
#                 "Value": "FleetShell-IPSec-rtb-backend"
#             }
#         ],
#         "VpcId": "vpc-0595e17ce290fb050",
#         "OwnerId": "295934382486"
#     },
#     "ClientToken": "d01a402f-7df5-45a8-885e-415fba172dd4"
# }

# NOTE: Record the rtb-ID from the output above.
#       Set it as the ipsec-gw-rtb tag on both Return GW ASGs:
#         make_asg_returngw.sh uses RTB_BACKEND env var -- set it before running.

