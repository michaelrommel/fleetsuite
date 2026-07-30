#!/usr/bin/env bash
set -euo pipefail
#
# make_enis_lvs.sh
#
# Creates the two pre-created management ENIs for the LVS HA pair.
# These ENIs are attached at boot by aeroplug (keepalived start_pre) using:
#   aeroplug eni --tag ipsec-lb-mgmt=master --attach --device-index 1
#   aeroplug eni --tag ipsec-lb-mgmt=backup --attach --device-index 1
#
# Each ENI has a fixed private IP so that the peer management IP tag
# (ipsec-lb-peer-mgmt-ip) can be set as a static value in each ASG.
#
# ENIs created:
#   fleetipsec-eni-lvs-mgmt-master  172.16.48.68  LVS-mgmt-a (AZ-a)  ipsec-lb-mgmt=master
#   fleetipsec-eni-lvs-mgmt-backup  172.16.48.84  LVS-mgmt-b (AZ-b)  ipsec-lb-mgmt=backup
#
# Security group: sg-lvs (sg-0406887cfe67d8f15)
#   — already allows VRRP proto 112 (self-referencing) and SSH from CLI_RemoteAccess

echo "# Master management ENI — LVS-mgmt-a (subnet-049c91ca98e7d3637, 172.16.48.64/28, AZ-a)"
echo "#   Fixed IP: 172.16.48.68  Tag: ipsec-lb-mgmt=master"
aws ec2 create-network-interface \
  --subnet-id subnet-049c91ca98e7d3637 \
  --private-ip-address 172.16.48.68 \
  --groups sg-0406887cfe67d8f15 \
  --description "FleetIPSec LVS master management ENI (eth1)" \
  --tag-specifications 'ResourceType=network-interface,Tags=[
    {Key=Name,Value=fleetipsec-eni-lvs-mgmt-master},
    {Key=ipsec-lb-mgmt,Value=master}
  ]'

echo ""
echo "# Backup management ENI — LVS-mgmt-b (subnet-07da62f2872b072b7, 172.16.48.80/28, AZ-b)"
echo "#   Fixed IP: 172.16.48.84  Tag: ipsec-lb-mgmt=backup"
aws ec2 create-network-interface \
  --subnet-id subnet-07da62f2872b072b7 \
  --private-ip-address 172.16.48.84 \
  --groups sg-0406887cfe67d8f15 \
  --description "FleetIPSec LVS backup management ENI (eth1)" \
  --tag-specifications 'ResourceType=network-interface,Tags=[
    {Key=Name,Value=fleetipsec-eni-lvs-mgmt-backup},
    {Key=ipsec-lb-mgmt,Value=backup}
  ]'

RESULT

# Master management ENI — LVS-mgmt-a (subnet-049c91ca98e7d3637, 172.16.48.64/28, AZ-a)
#   Fixed IP: 172.16.48.68  Tag: ipsec-lb-mgmt=master
{
    "NetworkInterface": {
        "AvailabilityZone": "eu-west-2a",
        "Description": "FleetIPSec LVS master management ENI (eth1)",
        "Groups": [
            {
                "GroupName": "FleetShell-IPSec-sg-lvs",
                "GroupId": "sg-0406887cfe67d8f15"
            }
        ],
        "InterfaceType": "interface",
        "Ipv6Addresses": [],
        "MacAddress": "06:b2:fb:89:f2:5f",
        "NetworkInterfaceId": "eni-0df0c11c6fbc81542",
        "OwnerId": "295934382486",
        "PrivateDnsName": "ip-172-16-48-68.eu-west-2.compute.internal",
        "PrivateIpAddress": "172.16.48.68",
        "PrivateIpAddresses": [
            {
                "Primary": true,
                "PrivateDnsName": "ip-172-16-48-68.eu-west-2.compute.internal",
                "PrivateIpAddress": "172.16.48.68"
            }
        ],
        "RequesterId": "AROAUJZYQKGLGCQENWWYT:michael.rommel@siemens-healthineers.com",
        "RequesterManaged": false,
        "SourceDestCheck": true,
        "Status": "pending",
        "SubnetId": "subnet-049c91ca98e7d3637",
        "TagSet": [
            {
                "Key": "Name",
                "Value": "fleetipsec-eni-lvs-mgmt-master"
            },
            {
                "Key": "ipsec-lb-mgmt",
                "Value": "master"
            }
        ],
        "VpcId": "vpc-0595e17ce290fb050"
    }
}

# Backup management ENI — LVS-mgmt-b (subnet-07da62f2872b072b7, 172.16.48.80/28, AZ-b)
#   Fixed IP: 172.16.48.84  Tag: ipsec-lb-mgmt=backup
{
    "NetworkInterface": {
        "AvailabilityZone": "eu-west-2b",
        "Description": "FleetIPSec LVS backup management ENI (eth1)",
        "Groups": [
            {
                "GroupName": "FleetShell-IPSec-sg-lvs",
                "GroupId": "sg-0406887cfe67d8f15"
            }
        ],
        "InterfaceType": "interface",
        "Ipv6Addresses": [],
        "MacAddress": "0a:dd:60:e8:f1:55",
        "NetworkInterfaceId": "eni-0c180dfe894914611",
        "OwnerId": "295934382486",
        "PrivateDnsName": "ip-172-16-48-84.eu-west-2.compute.internal",
        "PrivateIpAddress": "172.16.48.84",
        "PrivateIpAddresses": [
            {
                "Primary": true,
                "PrivateDnsName": "ip-172-16-48-84.eu-west-2.compute.internal",
                "PrivateIpAddress": "172.16.48.84"
            }
        ],
        "RequesterId": "AROAUJZYQKGLGCQENWWYT:michael.rommel@siemens-healthineers.com",
        "RequesterManaged": false,
        "SourceDestCheck": true,
        "Status": "pending",
        "SubnetId": "subnet-07da62f2872b072b7",
        "TagSet": [
            {
                "Key": "Name",
                "Value": "fleetipsec-eni-lvs-mgmt-backup"
            },
            {
                "Key": "ipsec-lb-mgmt",
                "Value": "backup"
            }
        ],
        "VpcId": "vpc-0595e17ce290fb050"
    }
}
