#!/usr/bin/env bash
set -euo pipefail
#
# make_vpn_enis_returngw.sh
#
# Creates two pre-allocated VPN-subnet ENIs for the Return GW HA pair (eth3).
# Each ENI has a fixed primary IP in its AZ's VPN concentrator subnet, giving
# the Return GW direct L2 same-subnet access to VPN concentrators in its AZ.
#
# Cross-AZ traffic is handled by an IPIP tunnel between the two Return GW nodes
# using the BGP ENI IPs (172.16.51.4 / 172.16.51.36) as endpoints.
#
# ENIs created:
#   master  172.16.49.4  VPN-a (subnet-05a86c0fe6eec7b10, 172.16.49.0/24, AZ-a)
#   backup  172.16.50.4  VPN-b (subnet-0ab2ba73e9b587e2e, 172.16.50.0/24, AZ-b)
#
# Tag: ipsec-gw-vpn=master / ipsec-gw-vpn=backup
#
# SourceDestCheck is disabled at boot by fleetpulse (not at creation time --
# AWS does not support that for custom ENIs created via create-network-interface).
#
# Security group: sg-vpn (sg-04dcc0342150eb53b) so VPN concentrators in the
# same subnet can receive traffic forwarded by this ENI.
# NOTE: sg-vpn must allow all inbound from 172.16.0.0/16 for forwarded backend
# traffic (source IP = backend server, not the Return GW) to reach VPN nodes.
# Run: aws ec2 authorize-security-group-ingress --group-id sg-04dcc0342150eb53b
#        --protocol -1 --cidr 172.16.0.0/16 --region eu-west-2
# if not already present.

echo "# Creating master VPN ENI in VPN-a (172.16.49.0/24, AZ-a)  fixed IP 172.16.49.4"
aws ec2 create-network-interface \
  --subnet-id subnet-05a86c0fe6eec7b10 \
  --private-ip-address 172.16.49.4 \
  --groups sg-04dcc0342150eb53b \
  --description "FleetIPSec Return GW master VPN ENI (eth3) -- L2 delivery to AZ-a VPN concentrators" \
  --region eu-west-2 \
  --tag-specifications 'ResourceType=network-interface,Tags=[
    {Key=Name,Value=fleetipsec-eni-returngw-vpn-master},
    {Key=ipsec-gw-vpn,Value=master}
  ]'

echo ""
echo "# Creating backup VPN ENI in VPN-b (172.16.50.0/24, AZ-b)  fixed IP 172.16.50.4"
aws ec2 create-network-interface \
  --subnet-id subnet-0ab2ba73e9b587e2e \
  --private-ip-address 172.16.50.4 \
  --groups sg-04dcc0342150eb53b \
  --description "FleetIPSec Return GW backup VPN ENI (eth3) -- L2 delivery to AZ-b VPN concentrators" \
  --region eu-west-2 \
  --tag-specifications 'ResourceType=network-interface,Tags=[
    {Key=Name,Value=fleetipsec-eni-returngw-vpn-backup},
    {Key=ipsec-gw-vpn,Value=backup}
  ]'

echo ""
echo "# Verify:"
aws ec2 describe-network-interfaces \
  --filters 'Name=tag-key,Values=ipsec-gw-vpn' \
  --query 'NetworkInterfaces[*].{Name:TagSet[?Key==`Name`]|[0].Value,ENI:NetworkInterfaceId,IP:PrivateIpAddress,Status:Status}' \
  --region eu-west-2 --output table

echo ""
echo "# Reminder: ensure sg-vpn allows all inbound from 172.16.0.0/16:"
echo "  aws ec2 describe-security-groups --group-ids sg-04dcc0342150eb53b --region eu-west-2 \\"
echo "    --query 'SecurityGroups[0].IpPermissions'"

# RESULT
#
# Creating master VPN ENI in VPN-a (172.16.49.0/24, AZ-a)  fixed IP 172.16.49.4
# {
#     "NetworkInterface": {
#         "AvailabilityZone": "eu-west-2a",
#         "Description": "FleetIPSec Return GW master VPN ENI (eth3) -- L2 delivery to AZ-a VPN concentrators",
#         "Groups": [
#             {
#                 "GroupName": "FleetShell-IPSec-sg-vpn",
#                 "GroupId": "sg-04dcc0342150eb53b"
#             }
#         ],
#         "InterfaceType": "interface",
#         "Ipv6Addresses": [],
#         "MacAddress": "06:76:63:d7:41:11",
#         "NetworkInterfaceId": "eni-0d339f89db3661a10",
#         "OwnerId": "295934382486",
#         "PrivateDnsName": "ip-172-16-49-4.eu-west-2.compute.internal",
#         "PrivateIpAddress": "172.16.49.4",
#         "PrivateIpAddresses": [
#             {
#                 "Primary": true,
#                 "PrivateDnsName": "ip-172-16-49-4.eu-west-2.compute.internal",
#                 "PrivateIpAddress": "172.16.49.4"
#             }
#         ],
#         "RequesterId": "AROAUJZYQKGLGCQENWWYT:michael.rommel@siemens-healthineers.com",
#         "RequesterManaged": false,
#         "SourceDestCheck": true,
#         "Status": "pending",
#         "SubnetId": "subnet-05a86c0fe6eec7b10",
#         "TagSet": [
#             {
#                 "Key": "Name",
#                 "Value": "fleetipsec-eni-returngw-vpn-master"
#             },
#             {
#                 "Key": "ipsec-gw-vpn",
#                 "Value": "master"
#             }
#         ],
#         "VpcId": "vpc-0595e17ce290fb050"
#     }
# }

# # Creating backup VPN ENI in VPN-b (172.16.50.0/24, AZ-b)  fixed IP 172.16.50.4
# {
#     "NetworkInterface": {
#         "AvailabilityZone": "eu-west-2b",
#         "Description": "FleetIPSec Return GW backup VPN ENI (eth3) -- L2 delivery to AZ-b VPN concentrators",
#         "Groups": [
#             {
#                 "GroupName": "FleetShell-IPSec-sg-vpn",
#                 "GroupId": "sg-04dcc0342150eb53b"
#             }
#         ],
#         "InterfaceType": "interface",
#         "Ipv6Addresses": [],
#         "MacAddress": "0a:3a:16:a4:a9:1f",
#         "NetworkInterfaceId": "eni-0318236dd70cd8aef",
#         "OwnerId": "295934382486",
#         "PrivateDnsName": "ip-172-16-50-4.eu-west-2.compute.internal",
#         "PrivateIpAddress": "172.16.50.4",
#         "PrivateIpAddresses": [
#             {
#                 "Primary": true,
#                 "PrivateDnsName": "ip-172-16-50-4.eu-west-2.compute.internal",
#                 "PrivateIpAddress": "172.16.50.4"
#             }
#         ],
#         "RequesterId": "AROAUJZYQKGLGCQENWWYT:michael.rommel@siemens-healthineers.com",
#         "RequesterManaged": false,
#         "SourceDestCheck": true,
#         "Status": "pending",
#         "SubnetId": "subnet-0ab2ba73e9b587e2e",
#         "TagSet": [
#             {
#                 "Key": "Name",
#                 "Value": "fleetipsec-eni-returngw-vpn-backup"
#             },
#             {
#                 "Key": "ipsec-gw-vpn",
#                 "Value": "backup"
#             }
#         ],
#         "VpcId": "vpc-0595e17ce290fb050"
#     }
# }

# # Verify:
# ---------------------------------------------------------------------------------------------
# |                                 DescribeNetworkInterfaces                                 |
# +------------------------+--------------+--------------------------------------+------------+
# |           ENI          |     IP       |                Name                  |  Status    |
# +------------------------+--------------+--------------------------------------+------------+
# |  eni-0318236dd70cd8aef |  172.16.50.4 |  fleetipsec-eni-returngw-vpn-backup  |  available |
# |  eni-0d339f89db3661a10 |  172.16.49.4 |  fleetipsec-eni-returngw-vpn-master  |  available |
# +------------------------+--------------+--------------------------------------+------------+

# # Reminder: ensure sg-vpn allows all inbound from 172.16.0.0/16:
#   aws ec2 describe-security-groups --group-ids sg-04dcc0342150eb53b --region eu-west-2 \
#     --query 'SecurityGroups[0].IpPermissions'
