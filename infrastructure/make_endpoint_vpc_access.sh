#!/usr/bin/env bash
set -euo pipefail
#
# make_endpoint_vpc_access.sh
#
# Interface VPC endpoints created with PrivateDnsEnabled=true override DNS for
# the AWS service name (e.g. ec2.eu-west-2.amazonaws.com) across the ENTIRE VPC.
# Every instance -- including the LVS nodes in the PUBLIC subnets -- then resolves
# that API to the endpoint's private ENI and must be able to reach it on 443.
#
# The endpoint SG (FleetShell-IPSec-sg-endpoints) originally allowed 443 only
# from the backend subnets (172.16.53/54.0/24), so the LVS (172.16.48.x) timed
# out on every EC2 API call -> ipsecpulse associate-mgmt-eip failed -> keepalived
# failed to start. Since private DNS is VPC-wide, the endpoint SG must accept
# 443 from the whole VPC.
#
# Idempotent: re-running is a no-op.

export AWS_PAGER=""
REGION="eu-west-2"
VPC_CIDR="172.16.0.0/16"

# Endpoint security group shared by the backend interface endpoints
# (ec2, ecr.api, ecr.dkr, ssm, ssmmessages, ec2messages, ...).
ENDPOINTS_SG="sg-0438c989d6fe0f276"

echo "Authorizing ${VPC_CIDR} -> ${ENDPOINTS_SG} on tcp/443 ..."
if aws ec2 authorize-security-group-ingress \
     --group-id "${ENDPOINTS_SG}" \
     --protocol tcp --port 443 --cidr "${VPC_CIDR}" \
     --region "${REGION}" 2>/tmp/ep_err; then
  echo "OK: rule added."
else
  if grep -q "InvalidPermission.Duplicate" /tmp/ep_err; then
    echo "OK: rule already present (idempotent)."
  else
    cat /tmp/ep_err >&2
    exit 1
  fi
fi
rm -f /tmp/ep_err

# If more interface endpoints exist on OTHER security groups, they need the same
# rule. List every private-DNS interface endpoint and its SGs:
#   aws ec2 describe-vpc-endpoints --region "${REGION}" \
#     --filters Name=vpc-id,Values=vpc-0595e17ce290fb050 \
#               Name=vpc-endpoint-type,Values=Interface \
#     --query 'VpcEndpoints[?PrivateDnsEnabled==`true`].{Id:VpcEndpointId,Svc:ServiceName,SGs:Groups[].GroupId}' \
#     --output table

# ---- RESULT ----------------------------------------------------------------
#
