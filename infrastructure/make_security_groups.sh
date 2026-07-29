#!/usr/bin/env bash
set -euo pipefail

echo "# LVS nodes — internet-facing, proto 50 + IKE"
aws ec2 create-security-group \
  --vpc-id vpc-0595e17ce290fb050 \
  --group-name FleetShell-IPSec-sg-lvs \
  --description "IPSec LB: proto50 ESP + IKE from internet, mgmt from CLI_RemoteAccess" \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=FleetShell-IPSec-sg-lvs}]'

echo "# VPN concentrators — receive from LVS, BGP to ReturnGW"
aws ec2 create-security-group \
  --vpc-id vpc-0595e17ce290fb050 \
  --group-name FleetShell-IPSec-sg-vpn \
  --description "VPN concentrators: IPSec from LVS, BGP to ReturnGW, Valkey, RDS" \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=FleetShell-IPSec-sg-vpn}]'

echo "# Return GW — BGP from VPN concentrators, default GW for backends"
aws ec2 create-security-group \
  --vpc-id vpc-0595e17ce290fb050 \
  --group-name FleetShell-IPSec-sg-returngw \
  --description "Return GW: BGP from VPN concentrators, forwarding to internet for backends" \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=FleetShell-IPSec-sg-returngw}]'

echo "# Management — RDS PostgreSQL, bastion"
aws ec2 create-security-group \
  --vpc-id vpc-0595e17ce290fb050 \
  --group-name FleetShell-IPSec-sg-management \
  --description "Management: RDS access from VPN nodes, SSH from CLI_RemoteAccess" \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=FleetShell-IPSec-sg-management}]' 

RESULT

# LVS nodes — internet-facing, proto 50 + IKE
{
    "GroupId": "sg-0406887cfe67d8f15",
    "Tags": [
        {
            "Key": "Name",
            "Value": "FleetShell-IPSec-sg-lvs"
        }
    ]
}
# VPN concentrators — receive from LVS, BGP to ReturnGW
{
    "GroupId": "sg-04dcc0342150eb53b",
    "Tags": [
        {
            "Key": "Name",
            "Value": "FleetShell-IPSec-sg-vpn"
        }
    ]
}
# Return GW — BGP from VPN concentrators, default GW for backends
{
    "GroupId": "sg-0516f1d2561c7754d",
    "Tags": [
        {
            "Key": "Name",
            "Value": "FleetShell-IPSec-sg-returngw"
        }
    ]
}
# Management — RDS PostgreSQL, bastion
{
    "GroupId": "sg-053524ea7dcdb64f1",
    "Tags": [
        {
            "Key": "Name",
            "Value": "FleetShell-IPSec-sg-management"
        }
    ]
}
