#!/usr/bin/env bash
set -euo pipefail
#
# make_bgp_enis_returngw.sh
#
# Creates two pre-allocated BGP ENIs for the Return GW HA pair.
# Each ENI has a FIXED PRIMARY IP that is the stable BGP peer address the
# VPN concentrators connect to.  The ENI lives in the same ReturnGW data
# subnet as the instance's eth0 but is attached as eth2 (device index 2)
# at boot.
#
# At boot the keepalived init.d script runs:
#   aeroplug eni --tag ipsec-gw-bgp=$ROLE --takeover --device-index 2
# which handles all cases:
#   - ENI available (normal boot or first boot): direct attach
#   - ENI in-use on old instance (ASG replacement): force-detach, wait, attach
#
# Fixed IPs:
#   172.16.51.4   master  ReturnGW-a (subnet-017d5b3a6331e26a7, 172.16.51.0/27)
#   172.16.51.36  backup  ReturnGW-b (subnet-082703ab573f0f4e9, 172.16.51.32/27)
#
# These must match the neighbor IPs in aerobake/fleetnode/_etc_frr_frr.conf.
# Security group: sg-returngw (sg-0516f1d2561c7754d)

echo "# Creating master BGP ENI in ReturnGW-a (172.16.51.0/27)  fixed IP 172.16.51.4"
aws ec2 create-network-interface \
  --subnet-id subnet-017d5b3a6331e26a7 \
  --private-ip-address 172.16.51.4 \
  --groups sg-0516f1d2561c7754d \
  --description "FleetIPSec Return GW master BGP ENI (eth2) -- fixed BGP peer address" \
  --region eu-west-2 \
  --tag-specifications 'ResourceType=network-interface,Tags=[
    {Key=Name,Value=fleetipsec-eni-returngw-bgp-master},
    {Key=ipsec-gw-bgp,Value=master}
  ]'

echo ""
echo "# Creating backup BGP ENI in ReturnGW-b (172.16.51.32/27)  fixed IP 172.16.51.36"
aws ec2 create-network-interface \
  --subnet-id subnet-082703ab573f0f4e9 \
  --private-ip-address 172.16.51.36 \
  --groups sg-0516f1d2561c7754d \
  --description "FleetIPSec Return GW backup BGP ENI (eth2) -- fixed BGP peer address" \
  --region eu-west-2 \
  --tag-specifications 'ResourceType=network-interface,Tags=[
    {Key=Name,Value=fleetipsec-eni-returngw-bgp-backup},
    {Key=ipsec-gw-bgp,Value=backup}
  ]'

echo ""
echo "# Verify:"
aws ec2 describe-network-interfaces \
  --filters 'Name=tag-key,Values=ipsec-gw-bgp' \
  --query 'NetworkInterfaces[*].{Name:TagSet[?Key==`Name`]|[0].Value,ENI:NetworkInterfaceId,IP:PrivateIpAddress,Status:Status}' \
  --region eu-west-2 --output table

#RESULT
# Creating master BGP ENI in ReturnGW-a (172.16.51.0/27)  fixed IP 172.16.51.4
# {
#     "NetworkInterface": {
#         "AvailabilityZone": "eu-west-2a",
#         "Description": "FleetIPSec Return GW master BGP ENI (eth2) -- fixed BGP peer address",
#         "Groups": [
#             {
#                 "GroupName": "FleetShell-IPSec-sg-returngw",
#                 "GroupId": "sg-0516f1d2561c7754d"
#             }
#         ],
#         "InterfaceType": "interface",
#         "Ipv6Addresses": [],
#         "MacAddress": "06:8a:b8:a3:d2:5d",
#         "NetworkInterfaceId": "eni-0d8caf4980a473e27",
#         "OwnerId": "295934382486",
#         "PrivateDnsName": "ip-172-16-51-4.eu-west-2.compute.internal",
#         "PrivateIpAddress": "172.16.51.4",
#         "PrivateIpAddresses": [
#             {
#                 "Primary": true,
#                 "PrivateDnsName": "ip-172-16-51-4.eu-west-2.compute.internal",
#                 "PrivateIpAddress": "172.16.51.4"
#             }
#         ],
#         "RequesterId": "AROAUJZYQKGLGCQENWWYT:michael.rommel@siemens-healthineers.com",
#         "RequesterManaged": false,
#         "SourceDestCheck": true,
#         "Status": "pending",
#         "SubnetId": "subnet-017d5b3a6331e26a7",
#         "TagSet": [
#             {
#                 "Key": "Name",
#                 "Value": "fleetipsec-eni-returngw-bgp-master"
#             },
#             {
#                 "Key": "ipsec-gw-bgp",
#                 "Value": "master"
#             }
#         ],
#         "VpcId": "vpc-0595e17ce290fb050"
#     }
# }

# # Creating backup BGP ENI in ReturnGW-b (172.16.51.32/27)  fixed IP 172.16.51.36
# {
#     "NetworkInterface": {
#         "AvailabilityZone": "eu-west-2b",
#         "Description": "FleetIPSec Return GW backup BGP ENI (eth2) -- fixed BGP peer address",
#         "Groups": [
#             {
#                 "GroupName": "FleetShell-IPSec-sg-returngw",
#                 "GroupId": "sg-0516f1d2561c7754d"
#             }
#         ],
#         "InterfaceType": "interface",
#         "Ipv6Addresses": [],
#         "MacAddress": "0a:3e:2b:3d:4a:51",
#         "NetworkInterfaceId": "eni-087ad9b8871763c8f",
#         "OwnerId": "295934382486",
#         "PrivateDnsName": "ip-172-16-51-36.eu-west-2.compute.internal",
#         "PrivateIpAddress": "172.16.51.36",
#         "PrivateIpAddresses": [
#             {
#                 "Primary": true,
#                 "PrivateDnsName": "ip-172-16-51-36.eu-west-2.compute.internal",
#                 "PrivateIpAddress": "172.16.51.36"
#             }
#         ],
#         "RequesterId": "AROAUJZYQKGLGCQENWWYT:michael.rommel@siemens-healthineers.com",
#         "RequesterManaged": false,
#         "SourceDestCheck": true,
#         "Status": "pending",
#         "SubnetId": "subnet-082703ab573f0f4e9",
#         "TagSet": [
#             {
#                 "Key": "Name",
#                 "Value": "fleetipsec-eni-returngw-bgp-backup"
#             },
#             {
#                 "Key": "ipsec-gw-bgp",
#                 "Value": "backup"
#             }
#         ],
#         "VpcId": "vpc-0595e17ce290fb050"
#     }
# }

# # Verify:
# ----------------------------------------------------------------------------------------------
# |                                  DescribeNetworkInterfaces                                 |
# +------------------------+---------------+--------------------------------------+------------+
# |           ENI          |      IP       |                Name                  |  Status    |
# +------------------------+---------------+--------------------------------------+------------+
# |  eni-087ad9b8871763c8f |  172.16.51.36 |  fleetipsec-eni-returngw-bgp-backup  |  available |
# |  eni-0d8caf4980a473e27 |  172.16.51.4  |  fleetipsec-eni-returngw-bgp-master  |  available |
# +------------------------+---------------+--------------------------------------+------------+
