#!/usr/bin/env bash
set -euo pipefail

echo "# LVS Public — AZ-a (IPSec LB primary)"
aws ec2 create-subnet \
  --vpc-id vpc-0595e17ce290fb050 \
  --cidr-block 172.16.48.0/27 \
  --availability-zone eu-west-2a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=FleetShell-IPSec-LVS-a}]'

echo "# LVS Public — AZ-b (IPSec LB standby)"
aws ec2 create-subnet \
  --vpc-id vpc-0595e17ce290fb050 \
  --cidr-block 172.16.48.32/27 \
  --availability-zone eu-west-2b \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=FleetShell-IPSec-LVS-b}]'

echo "# VPN Concentrators — AZ-a"
aws ec2 create-subnet \
  --vpc-id vpc-0595e17ce290fb050 \
  --cidr-block 172.16.49.0/24 \
  --availability-zone eu-west-2a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=FleetShell-IPSec-VPN-a}]'

echo "# VPN Concentrators — AZ-b"
aws ec2 create-subnet \
  --vpc-id vpc-0595e17ce290fb050 \
  --cidr-block 172.16.50.0/24 \
  --availability-zone eu-west-2b \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=FleetShell-IPSec-VPN-b}]'

echo "# Return Path Gateways — AZ-a"
aws ec2 create-subnet \
  --vpc-id vpc-0595e17ce290fb050 \
  --cidr-block 172.16.51.0/27 \
  --availability-zone eu-west-2a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=FleetShell-IPSec-ReturnGW-a}]'

echo "# Return Path Gateways — AZ-b"
aws ec2 create-subnet \
  --vpc-id vpc-0595e17ce290fb050 \
  --cidr-block 172.16.51.32/27 \
  --availability-zone eu-west-2b \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=FleetShell-IPSec-ReturnGW-b}]'

echo "# Management (RDS, bastion, NAT GW anchor)"
aws ec2 create-subnet \
  --vpc-id vpc-0595e17ce290fb050 \
  --cidr-block 172.16.52.0/24 \
  --availability-zone eu-west-2a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=FleetShell-IPSec-Management}]'

RESULT

# LVS Public — AZ-a (IPSec LB primary)
{
    "Subnet": {
        "AvailabilityZone": "eu-west-2a",
        "AvailabilityZoneId": "euw2-az2",
        "AvailableIpAddressCount": 27,
        "CidrBlock": "172.16.48.0/27",
        "DefaultForAz": false,
        "MapPublicIpOnLaunch": false,
        "MapCustomerOwnedIpOnLaunch": false,
        "State": "available",
        "SubnetId": "subnet-0fe6d05bc51c16ed8",
        "VpcId": "vpc-0595e17ce290fb050",
        "OwnerId": "295934382486",
        "AssignIpv6AddressOnCreation": false,
        "Ipv6CidrBlockAssociationSet": [],
        "Tags": [
            {
                "Key": "Name",
                "Value": "FleetShell-IPSec-LVS-a"
            }
        ],
        "SubnetArn": "arn:aws:ec2:eu-west-2:295934382486:subnet/subnet-0fe6d05bc51c16ed8",
        "EnableDns64": false,
        "Ipv6Native": false,
        "PrivateDnsNameOptionsOnLaunch": {
            "HostnameType": "ip-name",
            "EnableResourceNameDnsARecord": false,
            "EnableResourceNameDnsAAAARecord": false
        }
    }
}
# LVS Public — AZ-b (IPSec LB standby)
{
    "Subnet": {
        "AvailabilityZone": "eu-west-2b",
        "AvailabilityZoneId": "euw2-az3",
        "AvailableIpAddressCount": 27,
        "CidrBlock": "172.16.48.32/27",
        "DefaultForAz": false,
        "MapPublicIpOnLaunch": false,
        "MapCustomerOwnedIpOnLaunch": false,
        "State": "available",
        "SubnetId": "subnet-071e009038ce73f87",
        "VpcId": "vpc-0595e17ce290fb050",
        "OwnerId": "295934382486",
        "AssignIpv6AddressOnCreation": false,
        "Ipv6CidrBlockAssociationSet": [],
        "Tags": [
            {
                "Key": "Name",
                "Value": "FleetShell-IPSec-LVS-b"
            }
        ],
        "SubnetArn": "arn:aws:ec2:eu-west-2:295934382486:subnet/subnet-071e009038ce73f87",
        "EnableDns64": false,
        "Ipv6Native": false,
        "PrivateDnsNameOptionsOnLaunch": {
            "HostnameType": "ip-name",
            "EnableResourceNameDnsARecord": false,
            "EnableResourceNameDnsAAAARecord": false
        }
    }
}
# VPN Concentrators — AZ-a
{
    "Subnet": {
        "AvailabilityZone": "eu-west-2a",
        "AvailabilityZoneId": "euw2-az2",
        "AvailableIpAddressCount": 251,
        "CidrBlock": "172.16.49.0/24",
        "DefaultForAz": false,
        "MapPublicIpOnLaunch": false,
        "MapCustomerOwnedIpOnLaunch": false,
        "State": "available",
        "SubnetId": "subnet-05a86c0fe6eec7b10",
        "VpcId": "vpc-0595e17ce290fb050",
        "OwnerId": "295934382486",
        "AssignIpv6AddressOnCreation": false,
        "Ipv6CidrBlockAssociationSet": [],
        "Tags": [
            {
                "Key": "Name",
                "Value": "FleetShell-IPSec-VPN-a"
            }
        ],
        "SubnetArn": "arn:aws:ec2:eu-west-2:295934382486:subnet/subnet-05a86c0fe6eec7b10",
        "EnableDns64": false,
        "Ipv6Native": false,
        "PrivateDnsNameOptionsOnLaunch": {
            "HostnameType": "ip-name",
            "EnableResourceNameDnsARecord": false,
            "EnableResourceNameDnsAAAARecord": false
        }
    }
}
# VPN Concentrators — AZ-b
{
    "Subnet": {
        "AvailabilityZone": "eu-west-2b",
        "AvailabilityZoneId": "euw2-az3",
        "AvailableIpAddressCount": 251,
        "CidrBlock": "172.16.50.0/24",
        "DefaultForAz": false,
        "MapPublicIpOnLaunch": false,
        "MapCustomerOwnedIpOnLaunch": false,
        "State": "available",
        "SubnetId": "subnet-0ab2ba73e9b587e2e",
        "VpcId": "vpc-0595e17ce290fb050",
        "OwnerId": "295934382486",
        "AssignIpv6AddressOnCreation": false,
        "Ipv6CidrBlockAssociationSet": [],
        "Tags": [
            {
                "Key": "Name",
                "Value": "FleetShell-IPSec-VPN-b"
            }
        ],
        "SubnetArn": "arn:aws:ec2:eu-west-2:295934382486:subnet/subnet-0ab2ba73e9b587e2e",
        "EnableDns64": false,
        "Ipv6Native": false,
        "PrivateDnsNameOptionsOnLaunch": {
            "HostnameType": "ip-name",
            "EnableResourceNameDnsARecord": false,
            "EnableResourceNameDnsAAAARecord": false
        }
    }
}
# Return Path Gateways — AZ-a
{
    "Subnet": {
        "AvailabilityZone": "eu-west-2a",
        "AvailabilityZoneId": "euw2-az2",
        "AvailableIpAddressCount": 27,
        "CidrBlock": "172.16.51.0/27",
        "DefaultForAz": false,
        "MapPublicIpOnLaunch": false,
        "MapCustomerOwnedIpOnLaunch": false,
        "State": "available",
        "SubnetId": "subnet-017d5b3a6331e26a7",
        "VpcId": "vpc-0595e17ce290fb050",
        "OwnerId": "295934382486",
        "AssignIpv6AddressOnCreation": false,
        "Ipv6CidrBlockAssociationSet": [],
        "Tags": [
            {
                "Key": "Name",
                "Value": "FleetShell-IPSec-ReturnGW-a"
            }
        ],
        "SubnetArn": "arn:aws:ec2:eu-west-2:295934382486:subnet/subnet-017d5b3a6331e26a7",
        "EnableDns64": false,
        "Ipv6Native": false,
        "PrivateDnsNameOptionsOnLaunch": {
            "HostnameType": "ip-name",
            "EnableResourceNameDnsARecord": false,
            "EnableResourceNameDnsAAAARecord": false
        }
    }
}
# Return Path Gateways — AZ-b
{
    "Subnet": {
        "AvailabilityZone": "eu-west-2b",
        "AvailabilityZoneId": "euw2-az3",
        "AvailableIpAddressCount": 27,
        "CidrBlock": "172.16.51.32/27",
        "DefaultForAz": false,
        "MapPublicIpOnLaunch": false,
        "MapCustomerOwnedIpOnLaunch": false,
        "State": "available",
        "SubnetId": "subnet-082703ab573f0f4e9",
        "VpcId": "vpc-0595e17ce290fb050",
        "OwnerId": "295934382486",
        "AssignIpv6AddressOnCreation": false,
        "Ipv6CidrBlockAssociationSet": [],
        "Tags": [
            {
                "Key": "Name",
                "Value": "FleetShell-IPSec-ReturnGW-b"
            }
        ],
        "SubnetArn": "arn:aws:ec2:eu-west-2:295934382486:subnet/subnet-082703ab573f0f4e9",
        "EnableDns64": false,
        "Ipv6Native": false,
        "PrivateDnsNameOptionsOnLaunch": {
            "HostnameType": "ip-name",
            "EnableResourceNameDnsARecord": false,
            "EnableResourceNameDnsAAAARecord": false
        }
    }
}
# Management (RDS, bastion, NAT GW anchor)
{
    "Subnet": {
        "AvailabilityZone": "eu-west-2a",
        "AvailabilityZoneId": "euw2-az2",
        "AvailableIpAddressCount": 251,
        "CidrBlock": "172.16.52.0/24",
        "DefaultForAz": false,
        "MapPublicIpOnLaunch": false,
        "MapCustomerOwnedIpOnLaunch": false,
        "State": "available",
        "SubnetId": "subnet-02387719b5b2c3352",
        "VpcId": "vpc-0595e17ce290fb050",
        "OwnerId": "295934382486",
        "AssignIpv6AddressOnCreation": false,
        "Ipv6CidrBlockAssociationSet": [],
        "Tags": [
            {
                "Key": "Name",
                "Value": "FleetShell-IPSec-Management"
            }
        ],
        "SubnetArn": "arn:aws:ec2:eu-west-2:295934382486:subnet/subnet-02387719b5b2c3352",
        "EnableDns64": false,
        "Ipv6Native": false,
        "PrivateDnsNameOptionsOnLaunch": {
            "HostnameType": "ip-name",
            "EnableResourceNameDnsARecord": false,
            "EnableResourceNameDnsAAAARecord": false
        }
    }
}

