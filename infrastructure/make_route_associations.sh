#!/usr/bin/env bash
set -euo pipefail

# ── rtb-public (FleetShell-IPSec-rtb-public) ──────────────────────────────

echo "# Associate LVS subnets"
aws ec2 associate-route-table \
 --route-table-id rtb-0ca8eab40e09c76ae \
 --subnet-id subnet-0fe6d05bc51c16ed8

aws ec2 associate-route-table \
 --route-table-id rtb-0ca8eab40e09c76ae \
 --subnet-id subnet-071e009038ce73f87

# Default route → Internet Gateway
aws ec2 create-route \
 --route-table-id rtb-0ca8eab40e09c76ae \
 --destination-cidr-block 0.0.0.0/0 \
 --gateway-id igw-0599736bc51a9ac5c


# ── rtb-private (FleetShell-IPSec-rtb-private) ────────────────────────────

echo "# Associate ReturnGW + Management subnets"
aws ec2 associate-route-table \
 --route-table-id rtb-0540e3736995912c5 \
 --subnet-id subnet-017d5b3a6331e26a7

aws ec2 associate-route-table \
 --route-table-id rtb-0540e3736995912c5 \
 --subnet-id subnet-082703ab573f0f4e9

aws ec2 associate-route-table \
 --route-table-id rtb-0540e3736995912c5 \
 --subnet-id subnet-02387719b5b2c3352

echo "# Default route → NAT Gateway"
aws ec2 create-route \
 --route-table-id rtb-0540e3736995912c5 \
 --destination-cidr-block 0.0.0.0/0 \
 --nat-gateway-id nat-0fb75bf0679751582


# ── rtb-vpn (FleetShell-IPSec-rtb-vpn) ───────────────────────────────────

echo "# Subnet associations only — default route added by ipsecpulse notify-master.sh"
aws ec2 associate-route-table \
 --route-table-id rtb-01c3275faa537fcc1 \
 --subnet-id subnet-05a86c0fe6eec7b10

aws ec2 associate-route-table \
 --route-table-id rtb-01c3275faa537fcc1 \
 --subnet-id subnet-0ab2ba73e9b587e2e

RESULT

# Associate LVS subnets
{
    "AssociationId": "rtbassoc-0967043b9c42ed6ee",
    "AssociationState": {
        "State": "associated"
    }
}
{
    "AssociationId": "rtbassoc-0cf251ecf42f1d39f",
    "AssociationState": {
        "State": "associated"
    }
}
{
    "Return": true
}
# Associate ReturnGW + Management subnets
{
    "AssociationId": "rtbassoc-0827bcef93f1a8b91",
    "AssociationState": {
        "State": "associated"
    }
}
{
    "AssociationId": "rtbassoc-01a6a6c3198ee1442",
    "AssociationState": {
        "State": "associated"
    }
}
{
    "AssociationId": "rtbassoc-08fc3a5313f67d6d4",
    "AssociationState": {
        "State": "associated"
    }
}
# Default route → NAT Gateway
{
    "Return": true
}
# Subnet associations only — default route added by ipsecpulse notify-master.sh
{
    "AssociationId": "rtbassoc-0bc8d4a5c20873565",
    "AssociationState": {
        "State": "associated"
    }
}
{
    "AssociationId": "rtbassoc-0d11f220f1500763f",
    "AssociationState": {
        "State": "associated"
    }
}
