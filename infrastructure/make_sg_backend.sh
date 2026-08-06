#!/usr/bin/env bash
set -euo pipefail

# Security group for test/production backend servers reachable via the
# FleetShell IPSec fleet.
#
# Traffic model:
#   Inbound src is the NATted customer-device global IP (e.g. 198.51.100.x),
#   NOT the VPN concentrator's ENI IP.  VPP SNAT replaces the internal device
#   IP with the assigned global IP before the packet leaves ens5, so the
#   backend SG must allow from the global IP pool CIDR, not from sg-vpn.
#
#   Return traffic (backend -> global_ip) is handled by the Return GW
#   (BGP /32 route -> VPN concentrator -> VPP reverse-NAT -> tunnel).
#   Because AWS SGs are stateful, the return packets for established inbound
#   connections are allowed automatically without explicit egress rules.
#
# GLOBAL_IP_CIDR: replace 198.51.100.0/24 (RFC 5737 test range used in T4)
# with the actual production global IP pool CIDR before deploying to production.

GLOBAL_IP_CIDR="198.51.100.0/24"
CLI_REMOTE_ACCESS_SG="sg-011b3ebfcfbcca22d"
VPC_ID="vpc-0595e17ce290fb050"
REGION="eu-west-2"

# echo "# Create backend server security group"
# aws ec2 create-security-group \
#   --vpc-id "${VPC_ID}" \
#   --group-name FleetShell-IPSec-sg-backend \
#   --description "Backend servers: traffic from NAT44 global IP pool via VPN concentrators" \
#   --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=FleetShell-IPSec-sg-backend}]' \
#   --region "${REGION}"

# # Create backend server security group
# {
#     "GroupId": "sg-05aacef85bd425965",
#     "Tags": [
#         {
#             "Key": "Name",
#             "Value": "FleetShell-IPSec-sg-backend"
#         }
#     ]
# }

# Capture the new SG ID from the output above before running the rules below,
# or set it here manually after the create-security-group call completes.
SG_BACKEND="sg-05aacef85bd425965"

echo "# ICMP from global IP pool (ping testing through tunnel)"
aws ec2 authorize-security-group-ingress --group-id "${SG_BACKEND}" \
  --ip-permissions "[{\"IpProtocol\":\"icmp\",\"FromPort\":-1,\"ToPort\":-1,\"IpRanges\":[{\"CidrIp\":\"${GLOBAL_IP_CIDR}\",\"Description\":\"ICMP from NAT44 global IP pool\"}]}]" \
  --region "${REGION}"

echo "# TCP 8080 from global IP pool (HTTP test endpoint)"
aws ec2 authorize-security-group-ingress --group-id "${SG_BACKEND}" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":8080,\"ToPort\":8080,\"IpRanges\":[{\"CidrIp\":\"${GLOBAL_IP_CIDR}\",\"Description\":\"HTTP from NAT44 global IP pool\"}]}]" \
  --region "${REGION}"

echo "# TCP 443 from global IP pool (HTTPS test endpoint)"
aws ec2 authorize-security-group-ingress --group-id "${SG_BACKEND}" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":443,\"ToPort\":443,\"IpRanges\":[{\"CidrIp\":\"${GLOBAL_IP_CIDR}\",\"Description\":\"HTTPS from NAT44 global IP pool\"}]}]" \
  --region "${REGION}"

echo "# SSH from office (CLI_RemoteAccess) for container management"
aws ec2 authorize-security-group-ingress --group-id "${SG_BACKEND}" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":22,\"ToPort\":22,\"UserIdGroupPairs\":[{\"GroupId\":\"${CLI_REMOTE_ACCESS_SG}\"}]}]" \
  --region "${REGION}"

# ICMP from global IP pool (ping testing through tunnel)
# {
#     "Return": true,
#     "SecurityGroupRules": [
#         {
#             "SecurityGroupRuleId": "sgr-00468083cec05052c",
#             "GroupId": "sg-05aacef85bd425965",
#             "GroupOwnerId": "295934382486",
#             "IsEgress": false,
#             "IpProtocol": "icmp",
#             "FromPort": -1,
#             "ToPort": -1,
#             "CidrIpv4": "198.51.100.0/24",
#             "Description": "ICMP from NAT44 global IP pool"
#         }
#     ]
# }
# # TCP 8080 from global IP pool (HTTP test endpoint)
# {
#     "Return": true,
#     "SecurityGroupRules": [
#         {
#             "SecurityGroupRuleId": "sgr-031055405461ae2d9",
#             "GroupId": "sg-05aacef85bd425965",
#             "GroupOwnerId": "295934382486",
#             "IsEgress": false,
#             "IpProtocol": "tcp",
#             "FromPort": 8080,
#             "ToPort": 8080,
#             "CidrIpv4": "198.51.100.0/24",
#             "Description": "HTTP from NAT44 global IP pool"
#         }
#     ]
# }
# # TCP 443 from global IP pool (HTTPS test endpoint)
# {
#     "Return": true,
#     "SecurityGroupRules": [
#         {
#             "SecurityGroupRuleId": "sgr-04e3008c4c1af5982",
#             "GroupId": "sg-05aacef85bd425965",
#             "GroupOwnerId": "295934382486",
#             "IsEgress": false,
#             "IpProtocol": "tcp",
#             "FromPort": 443,
#             "ToPort": 443,
#             "CidrIpv4": "198.51.100.0/24",
#             "Description": "HTTPS from NAT44 global IP pool"
#         }
#     ]
# }
# # SSH from office (CLI_RemoteAccess) for container management
# {
#     "Return": true,
#     "SecurityGroupRules": [
#         {
#             "SecurityGroupRuleId": "sgr-07f85c7002a93df83",
#             "GroupId": "sg-05aacef85bd425965",
#             "GroupOwnerId": "295934382486",
#             "IsEgress": false,
#             "IpProtocol": "tcp",
#             "FromPort": 22,
#             "ToPort": 22,
#             "ReferencedGroupInfo": {
#                 "GroupId": "sg-011b3ebfcfbcca22d",
#                 "UserId": "295934382486"
#             }
#         }
#     ]
# }
