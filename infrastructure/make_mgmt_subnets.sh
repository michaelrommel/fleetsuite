#!/usr/bin/env bash
set -euo pipefail

# ── LVS management — eth1 for LVS nodes ──────────────────────────────────

echo "# AZ-a (eth1 for LVS-a node)"
aws ec2 create-subnet \
  --vpc-id vpc-0595e17ce290fb050 \
  --cidr-block 172.16.48.64/28 \
  --availability-zone eu-west-2a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=FleetShell-IPSec-LVS-mgmt-a}]'

echo "# AZ-b (eth1 for LVS-b node)"
aws ec2 create-subnet \
  --vpc-id vpc-0595e17ce290fb050 \
  --cidr-block 172.16.48.80/28 \
  --availability-zone eu-west-2b \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=FleetShell-IPSec-LVS-mgmt-b}]'

# ── Return GW management — eth1 for Return GW nodes ──────────────────────

echo "# AZ-a (eth1 for ReturnGW-a node)"
aws ec2 create-subnet \
  --vpc-id vpc-0595e17ce290fb050 \
  --cidr-block 172.16.51.64/28 \
  --availability-zone eu-west-2a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=FleetShell-IPSec-ReturnGW-mgmt-a}]'

echo "# AZ-b (eth1 for ReturnGW-b node)"
aws ec2 create-subnet \
  --vpc-id vpc-0595e17ce290fb050 \
  --cidr-block 172.16.51.96/28 \
  --availability-zone eu-west-2b \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=FleetShell-IPSec-ReturnGW-mgmt-b}]'

RESULT

# AZ-a (eth1 for LVS-a node)
{
    "Subnet": {
        "AvailabilityZone": "eu-west-2a",
        "AvailabilityZoneId": "euw2-az2",
        "AvailableIpAddressCount": 11,
        "CidrBlock": "172.16.48.64/28",
        "DefaultForAz": false,
        "MapPublicIpOnLaunch": false,
        "MapCustomerOwnedIpOnLaunch": false,
        "State": "available",
        "SubnetId": "subnet-049c91ca98e7d3637",
        "VpcId": "vpc-0595e17ce290fb050",
        "OwnerId": "295934382486",
        "AssignIpv6AddressOnCreation": false,
        "Ipv6CidrBlockAssociationSet": [],
        "Tags": [
            {
                "Key": "Name",
                "Value": "FleetShell-IPSec-LVS-mgmt-a"
            }
        ],
        "SubnetArn": "arn:aws:ec2:eu-west-2:295934382486:subnet/subnet-049c91ca98e7d3637",
        "EnableDns64": false,
        "Ipv6Native": false,
        "PrivateDnsNameOptionsOnLaunch": {
            "HostnameType": "ip-name",
            "EnableResourceNameDnsARecord": false,
            "EnableResourceNameDnsAAAARecord": false
        }
    }
}
# AZ-b (eth1 for LVS-b node)
{
    "Subnet": {
        "AvailabilityZone": "eu-west-2b",
        "AvailabilityZoneId": "euw2-az3",
        "AvailableIpAddressCount": 11,
        "CidrBlock": "172.16.48.80/28",
        "DefaultForAz": false,
        "MapPublicIpOnLaunch": false,
        "MapCustomerOwnedIpOnLaunch": false,
        "State": "available",
        "SubnetId": "subnet-07da62f2872b072b7",
        "VpcId": "vpc-0595e17ce290fb050",
        "OwnerId": "295934382486",
        "AssignIpv6AddressOnCreation": false,
        "Ipv6CidrBlockAssociationSet": [],
        "Tags": [
            {
                "Key": "Name",
                "Value": "FleetShell-IPSec-LVS-mgmt-b"
            }
        ],
        "SubnetArn": "arn:aws:ec2:eu-west-2:295934382486:subnet/subnet-07da62f2872b072b7",
        "EnableDns64": false,
        "Ipv6Native": false,
        "PrivateDnsNameOptionsOnLaunch": {
            "HostnameType": "ip-name",
            "EnableResourceNameDnsARecord": false,
            "EnableResourceNameDnsAAAARecord": false
        }
    }
}
# AZ-a (eth1 for ReturnGW-a node)
{
    "Subnet": {
        "AvailabilityZone": "eu-west-2a",
        "AvailabilityZoneId": "euw2-az2",
        "AvailableIpAddressCount": 11,
        "CidrBlock": "172.16.51.64/28",
        "DefaultForAz": false,
        "MapPublicIpOnLaunch": false,
        "MapCustomerOwnedIpOnLaunch": false,
        "State": "available",
        "SubnetId": "subnet-063a83cf5653196c7",
        "VpcId": "vpc-0595e17ce290fb050",
        "OwnerId": "295934382486",
        "AssignIpv6AddressOnCreation": false,
        "Ipv6CidrBlockAssociationSet": [],
        "Tags": [
            {
                "Key": "Name",
                "Value": "FleetShell-IPSec-ReturnGW-mgmt-a"
            }
        ],
        "SubnetArn": "arn:aws:ec2:eu-west-2:295934382486:subnet/subnet-063a83cf5653196c7",
        "EnableDns64": false,
        "Ipv6Native": false,
        "PrivateDnsNameOptionsOnLaunch": {
            "HostnameType": "ip-name",
            "EnableResourceNameDnsARecord": false,
            "EnableResourceNameDnsAAAARecord": false
        }
    }
}
# AZ-b (eth1 for ReturnGW-b node)
{
    "Subnet": {
        "AvailabilityZone": "eu-west-2b",
        "AvailabilityZoneId": "euw2-az3",
        "AvailableIpAddressCount": 11,
        "CidrBlock": "172.16.51.96/28",
        "DefaultForAz": false,
        "MapPublicIpOnLaunch": false,
        "MapCustomerOwnedIpOnLaunch": false,
        "State": "available",
        "SubnetId": "subnet-0ee35e39252ccf95a",
        "VpcId": "vpc-0595e17ce290fb050",
        "OwnerId": "295934382486",
        "AssignIpv6AddressOnCreation": false,
        "Ipv6CidrBlockAssociationSet": [],
        "Tags": [
            {
                "Key": "Name",
                "Value": "FleetShell-IPSec-ReturnGW-mgmt-b"
            }
        ],
        "SubnetArn": "arn:aws:ec2:eu-west-2:295934382486:subnet/subnet-0ee35e39252ccf95a",
        "EnableDns64": false,
        "Ipv6Native": false,
        "PrivateDnsNameOptionsOnLaunch": {
            "HostnameType": "ip-name",
            "EnableResourceNameDnsARecord": false,
            "EnableResourceNameDnsAAAARecord": false
        }
    }
}
