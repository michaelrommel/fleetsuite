#!/usr/bin/env bash
set -euo pipefail

echo "# Customer-facing floating VIP"
aws ec2 allocate-address --domain vpc \
  --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=FleetShell-IPSec-VIP}]'

echo "# NAT Gateway outbounda"
aws ec2 allocate-address --domain vpc \
  --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=FleetShell-IPSec-NatGW}]'

echo "# Public RT for LVS nodes"
aws ec2 create-route-table \
  --vpc-id vpc-0595e17ce290fb050 \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=FleetShell-IPSec-rtb-public}]'

echo "# Private RT for VPN concentrators"
# (default route → LVS floating secondary IP, added after first LVS node boots)
aws ec2 create-route-table \
  --vpc-id vpc-0595e17ce290fb050 \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=FleetShell-IPSec-rtb-vpn}]'

echo "# Private RT for ReturnGW + Management"
# (default route → NAT GW, added after NAT GW created)
aws ec2 create-route-table \
  --vpc-id vpc-0595e17ce290fb050 \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=FleetShell-IPSec-rtb-private}]'

RESULT

# Customer-facing floating VIP
{
    "PublicIp": "3.11.124.22",
    "AllocationId": "eipalloc-095ac59bb763cd2ce",
    "PublicIpv4Pool": "amazon",
    "NetworkBorderGroup": "eu-west-2",
    "Domain": "vpc"
}
# NAT Gateway outbounda
{
    "PublicIp": "35.177.240.42",
    "AllocationId": "eipalloc-0ac2fb2dd51415b30",
    "PublicIpv4Pool": "amazon",
    "NetworkBorderGroup": "eu-west-2",
    "Domain": "vpc"
}
# Public RT for LVS nodes
{
    "RouteTable": {
        "Associations": [],
        "PropagatingVgws": [],
        "RouteTableId": "rtb-0ca8eab40e09c76ae",
        "Routes": [
            {
                "DestinationCidrBlock": "172.16.0.0/16",
                "GatewayId": "local",
                "Origin": "CreateRouteTable",
                "State": "active"
            },
            {
                "DestinationIpv6CidrBlock": "2a05:d01c:613:7200::/56",
                "GatewayId": "local",
                "Origin": "CreateRouteTable",
                "State": "active"
            }
        ],
        "Tags": [
            {
                "Key": "Name",
                "Value": "FleetShell-IPSec-rtb-public"
            }
        ],
        "VpcId": "vpc-0595e17ce290fb050",
        "OwnerId": "295934382486"
    },
    "ClientToken": "d203a85e-fd55-4635-b0bf-05b273d9cb91"
}
# Private RT for VPN concentrators
{
    "RouteTable": {
        "Associations": [],
        "PropagatingVgws": [],
        "RouteTableId": "rtb-01c3275faa537fcc1",
        "Routes": [
            {
                "DestinationCidrBlock": "172.16.0.0/16",
                "GatewayId": "local",
                "Origin": "CreateRouteTable",
                "State": "active"
            },
            {
                "DestinationIpv6CidrBlock": "2a05:d01c:613:7200::/56",
                "GatewayId": "local",
                "Origin": "CreateRouteTable",
                "State": "active"
            }
        ],
        "Tags": [
            {
                "Key": "Name",
                "Value": "FleetShell-IPSec-rtb-vpn"
            }
        ],
        "VpcId": "vpc-0595e17ce290fb050",
        "OwnerId": "295934382486"
    },
    "ClientToken": "2609064a-1c1d-4346-92c6-fdf2b6bae308"
}
# Private RT for ReturnGW + Management
{
    "RouteTable": {
        "Associations": [],
        "PropagatingVgws": [],
        "RouteTableId": "rtb-0540e3736995912c5",
        "Routes": [
            {
                "DestinationCidrBlock": "172.16.0.0/16",
                "GatewayId": "local",
                "Origin": "CreateRouteTable",
                "State": "active"
            },
            {
                "DestinationIpv6CidrBlock": "2a05:d01c:613:7200::/56",
                "GatewayId": "local",
                "Origin": "CreateRouteTable",
                "State": "active"
            }
        ],
        "Tags": [
            {
                "Key": "Name",
                "Value": "FleetShell-IPSec-rtb-private"
            }
        ],
        "VpcId": "vpc-0595e17ce290fb050",
        "OwnerId": "295934382486"
    },
    "ClientToken": "53bce349-3755-48bb-bab1-81b49150e6ac"
}
