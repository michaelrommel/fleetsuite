#!/usr/bin/env bash
set -euo pipefail
#
# make_enis_returngw.sh
#
# Creates the two pre-created management ENIs for the Return GW HA pair.
# These ENIs are attached at boot by aeroplug (keepalived start_pre) using:
#   aeroplug eni --tag ipsec-gw-mgmt=master --attach --device-index 1
#   aeroplug eni --tag ipsec-gw-mgmt=backup --attach --device-index 1
#
# Each ENI has a fixed private IP so the peer management IP tag
# (ipsec-gw-peer-mgmt-ip) can be set as a static value in each ASG.
#
# ENIs created:
#   fleetipsec-eni-returngw-mgmt-master  172.16.51.68   ReturnGW-mgmt-a  ipsec-gw-mgmt=master
#   fleetipsec-eni-returngw-mgmt-backup  172.16.51.100  ReturnGW-mgmt-b  ipsec-gw-mgmt=backup
#
# Security group: sg-returngw (sg-0516f1d2561c7754d)

echo "# Master management ENI -- ReturnGW-mgmt-a (subnet-063a83cf5653196c7, 172.16.51.64/28, AZ-a)"
echo "#   Fixed IP: 172.16.51.68  Tag: ipsec-gw-mgmt=master"
aws ec2 create-network-interface \
  --subnet-id subnet-063a83cf5653196c7 \
  --private-ip-address 172.16.51.68 \
  --groups sg-0516f1d2561c7754d \
  --description "FleetIPSec Return GW master management ENI (eth1)" \
  --region eu-west-2 \
  --tag-specifications 'ResourceType=network-interface,Tags=[
    {Key=Name,Value=fleetipsec-eni-returngw-mgmt-master},
    {Key=ipsec-gw-mgmt,Value=master}
  ]'

echo ""
echo "# Backup management ENI -- ReturnGW-mgmt-b (subnet-0ee35e39252ccf95a, 172.16.51.96/28, AZ-b)"
echo "#   Fixed IP: 172.16.51.100  Tag: ipsec-gw-mgmt=backup"
aws ec2 create-network-interface \
  --subnet-id subnet-0ee35e39252ccf95a \
  --private-ip-address 172.16.51.100 \
  --groups sg-0516f1d2561c7754d \
  --description "FleetIPSec Return GW backup management ENI (eth1)" \
  --region eu-west-2 \
  --tag-specifications 'ResourceType=network-interface,Tags=[
    {Key=Name,Value=fleetipsec-eni-returngw-mgmt-backup},
    {Key=ipsec-gw-mgmt,Value=backup}
  ]'

#RESULT
# {
#             "AvailabilityZone": "eu-west-2a",
#             "Description": "FleetIPSec Return GW master management ENI (eth1)",
#             "Groups": [
#                 {
#                     "GroupName": "FleetShell-IPSec-sg-returngw",
#                     "GroupId": "sg-0516f1d2561c7754d"
#                 }
#             ],
#             "InterfaceType": "interface",
#             "Ipv6Addresses": [],
#             "MacAddress": "06:e9:18:52:52:6b",
#             "NetworkInterfaceId": "eni-075391a4b4b30c165",
#             "OwnerId": "295934382486",
#             "PrivateDnsName": "ip-172-16-51-68.eu-west-2.compute.internal",
#             "PrivateIpAddress": "172.16.51.68",
#             "PrivateIpAddresses": [
#                 {
#                     "Primary": true,
#                     "PrivateDnsName": "ip-172-16-51-68.eu-west-2.compute.internal",
#                     "PrivateIpAddress": "172.16.51.68"
#                 }
#             ],
#             "RequesterId": "AROAUJZYQKGLGCQENWWYT:michael.rommel@siemens-healthineers.com",
#             "RequesterManaged": false,
#             "SourceDestCheck": true,
#             "Status": "available",
#             "SubnetId": "subnet-063a83cf5653196c7",
#             "TagSet": [
#                 {
#                     "Key": "Name",
#                     "Value": "fleetipsec-eni-returngw-mgmt-master"
#                 },
#                 {
#                     "Key": "ipsec-gw-mgmt",
#                     "Value": "master"
#                 }
#             ],
#             "VpcId": "vpc-0595e17ce290fb050"
#         }

# # Backup management ENI -- ReturnGW-mgmt-b (subnet-0ee35e39252ccf95a, 172.16.51.96/28, AZ-b)
# #   Fixed IP: 172.16.51.100  Tag: ipsec-gw-mgmt=backup
# {
#     "NetworkInterface": {
#         "AvailabilityZone": "eu-west-2b",
#         "Description": "FleetIPSec Return GW backup management ENI (eth1)",
#         "Groups": [
#             {
#                 "GroupName": "FleetShell-IPSec-sg-returngw",
#                 "GroupId": "sg-0516f1d2561c7754d"
#             }
#         ],
#         "InterfaceType": "interface",
#         "Ipv6Addresses": [],
#         "MacAddress": "0a:88:3a:a0:f0:51",
#         "NetworkInterfaceId": "eni-028af2519b34260a4",
#         "OwnerId": "295934382486",
#         "PrivateDnsName": "ip-172-16-51-100.eu-west-2.compute.internal",
#         "PrivateIpAddress": "172.16.51.100",
#         "PrivateIpAddresses": [
#             {
#                 "Primary": true,
#                 "PrivateDnsName": "ip-172-16-51-100.eu-west-2.compute.internal",
#                 "PrivateIpAddress": "172.16.51.100"
#             }
#         ],
#         "RequesterId": "AROAUJZYQKGLGCQENWWYT:michael.rommel@siemens-healthineers.com",
#         "RequesterManaged": false,
#         "SourceDestCheck": true,
#         "Status": "pending",
#         "SubnetId": "subnet-0ee35e39252ccf95a",
#         "TagSet": [
#             {
#                 "Key": "Name",
#                 "Value": "fleetipsec-eni-returngw-mgmt-backup"
#             },
#             {
#                 "Key": "ipsec-gw-mgmt",
#                 "Value": "backup"
#             }
#         ],
#         "VpcId": "vpc-0595e17ce290fb050"
#     }
# }
