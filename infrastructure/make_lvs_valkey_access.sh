#!/usr/bin/env bash
set -euo pipefail
#
# make_lvs_valkey_access.sh
#
# Allow the IPSec LVS nodes to reach Valkey/MemoryDB on 6379.
#
# ipsecscale (runs on both LVS nodes) writes the fleetproxy ECMP membership
# snapshot to Valkey (fleetipsec:proxy:pool). The LVS node ENIs therefore need
# ingress on the MemoryDB cluster SG on 6379 -- mirrors the rule the proxy
# service adds for the proxy SG (see make_proxy_service.sh STEP 3).
#
# Idempotent: re-running is a no-op (the duplicate-rule error is swallowed).

export AWS_PAGER=""
REGION="eu-west-2"

# MemoryDB (Valkey) cluster security group -- holds the 6379 self/ingress rules.
VALKEY_SG="sg-0709bc00b444b3a9a"

# IPSec LVS node security group (FleetShell-IPSec-sg-lvs); attached to eth0 on
# both the master and backup LVS instances.
LVS_SG="sg-0406887cfe67d8f15"

echo "Authorizing ${LVS_SG} -> ${VALKEY_SG} on tcp/6379 ..."
if aws ec2 authorize-security-group-ingress \
     --group-id "${VALKEY_SG}" \
     --protocol tcp --port 6379 --source-group "${LVS_SG}" \
     --region "${REGION}" 2>/tmp/lvs_valkey_err; then
  echo "OK: rule added."
else
  if grep -q "InvalidPermission.Duplicate" /tmp/lvs_valkey_err; then
    echo "OK: rule already present (idempotent)."
  else
    cat /tmp/lvs_valkey_err >&2
    exit 1
  fi
fi
rm -f /tmp/lvs_valkey_err

# ---- RESULT ----------------------------------------------------------------
# Authorizing sg-0406887cfe67d8f15 -> sg-0709bc00b444b3a9a on tcp/6379 ...
# {
#     "Return": true,
#     "SecurityGroupRules": [
#         {
#             "SecurityGroupRuleId": "sgr-0c81fd31ecc5d7a52",
#             "GroupId": "sg-0709bc00b444b3a9a",
#             "GroupOwnerId": "295934382486",
#             "IsEgress": false,
#             "IpProtocol": "tcp",
#             "FromPort": 6379,
#             "ToPort": 6379,
#             "ReferencedGroupInfo": {
#                 "GroupId": "sg-0406887cfe67d8f15",
#                 "UserId": "295934382486"
#             }
#         }
#     ]
# }
# OK: rule added.

