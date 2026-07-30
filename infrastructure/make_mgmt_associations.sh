#!/usr/bin/env bash
set -euo pipefail

# ── Associate all four new subnets with rtb-private ───────────────────────
# (substitute subnet IDs from the create-subnet output above)

aws ec2 associate-route-table \
  --route-table-id rtb-0540e3736995912c5 \
  --subnet-id subnet-049c91ca98e7d3637

aws ec2 associate-route-table \
  --route-table-id rtb-0540e3736995912c5 \
  --subnet-id subnet-07da62f2872b072b7

aws ec2 associate-route-table \
  --route-table-id rtb-0540e3736995912c5 \
  --subnet-id subnet-063a83cf5653196c7

aws ec2 associate-route-table \
  --route-table-id rtb-0540e3736995912c5 \
  --subnet-id subnet-0ee35e39252ccf95a

RESULT

{
    "AssociationId": "rtbassoc-0785ea0e095a19f64",
    "AssociationState": {
        "State": "associated"
    }
}
{
    "AssociationId": "rtbassoc-06474e35c6f2c8b81",
    "AssociationState": {
        "State": "associated"
    }
}
{
    "AssociationId": "rtbassoc-031992c86a65a981b",
    "AssociationState": {
        "State": "associated"
    }
}
{
    "AssociationId": "rtbassoc-0970d42aed3238dba",
    "AssociationState": {
        "State": "associated"
    }
}

