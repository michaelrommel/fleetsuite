#!/usr/bin/env bash
set -euo pipefail
#
# make_subnets_backend.sh
#
# Creates two backend server subnets (one per AZ) and associates them with the
# existing FleetShell-IPSec-rtb-backend route table.
#
# Routing model for backend servers:
#   172.16.0.0/16  -> local  (VPC-internal: bastion SSH, VPC endpoints, DNS at 172.16.0.2)
#   0.0.0.0/0      -> Return GW master eth0 ENI  (set by fleetpulse notify-master)
#
# Traffic to medical-device global IPs (e.g. 198.51.100.x) hits the default
# route and is forwarded by the Return GW to the correct VPN concentrator via
# BGP /32 routes.  No per-range route table entries are needed -- new global IP
# pools are handled automatically by BGP on the Return GW.
#
# Traffic to AWS services (ECR, S3, SSM, ...) is intercepted by VPC interface/
# gateway endpoints which resolve to 172.16.x.x addresses, staying on the local
# route and never touching the Return GW.  See make_vpc_endpoints_backend.sh.
#
# Any remaining internet traffic (e.g. OS package updates) goes via the Return
# GW which forwards it onward to the NAT Gateway via its own default route
# (ReturnGW subnets are in rtb-private, 0.0.0.0/0 -> nat-0fb75bf0679751582).

REGION="eu-west-2"
VPC_ID="vpc-0595e17ce290fb050"
RTB_BACKEND="rtb-0a446e715fc3ec757"

# echo "# Backend servers -- AZ-a (eu-west-2a)"
# aws ec2 create-subnet \
#   --vpc-id "${VPC_ID}" \
#   --cidr-block 172.16.53.0/24 \
#   --availability-zone eu-west-2a \
#   --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=FleetShell-IPSec-Backend-a}]' \
#   --region "${REGION}"

# echo "# Backend servers -- AZ-b (eu-west-2b)"
# aws ec2 create-subnet \
#   --vpc-id "${VPC_ID}" \
#   --cidr-block 172.16.54.0/24 \
#   --availability-zone eu-west-2b \
#   --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=FleetShell-IPSec-Backend-b}]' \
#   --region "${REGION}"

# RESULT
#
# Backend servers -- AZ-a (eu-west-2a)
# {
#     "Subnet": {
#         "AvailabilityZone": "eu-west-2a",
#         "AvailabilityZoneId": "euw2-az2",
#         "AvailableIpAddressCount": 251,
#         "CidrBlock": "172.16.53.0/24",
#         "DefaultForAz": false,
#         "MapPublicIpOnLaunch": false,
#         "MapCustomerOwnedIpOnLaunch": false,
#         "State": "available",
#         "SubnetId": "subnet-01a513292ea15ae83",
#         "VpcId": "vpc-0595e17ce290fb050",
#         "OwnerId": "295934382486",
#         "AssignIpv6AddressOnCreation": false,
#         "Ipv6CidrBlockAssociationSet": [],
#         "Tags": [
#             {
#                 "Key": "Name",
#                 "Value": "FleetShell-IPSec-Backend-a"
#             }
#         ],
#         "SubnetArn": "arn:aws:ec2:eu-west-2:295934382486:subnet/subnet-01a513292ea15ae83",
#         "EnableDns64": false,
#         "Ipv6Native": false,
#         "PrivateDnsNameOptionsOnLaunch": {
#             "HostnameType": "ip-name",
#             "EnableResourceNameDnsARecord": false,
#             "EnableResourceNameDnsAAAARecord": false
#         }
#     }
# }
# # Backend servers -- AZ-b (eu-west-2b)
# {
#     "Subnet": {
#         "AvailabilityZone": "eu-west-2b",
#         "AvailabilityZoneId": "euw2-az3",
#         "AvailableIpAddressCount": 251,
#         "CidrBlock": "172.16.54.0/24",
#         "DefaultForAz": false,
#         "MapPublicIpOnLaunch": false,
#         "MapCustomerOwnedIpOnLaunch": false,
#         "State": "available",
#         "SubnetId": "subnet-08213d03f2940855c",
#         "VpcId": "vpc-0595e17ce290fb050",
#         "OwnerId": "295934382486",
#         "AssignIpv6AddressOnCreation": false,
#         "Ipv6CidrBlockAssociationSet": [],
#         "Tags": [
#             {
#                 "Key": "Name",
#                 "Value": "FleetShell-IPSec-Backend-b"
#             }
#         ],
#         "SubnetArn": "arn:aws:ec2:eu-west-2:295934382486:subnet/subnet-08213d03f2940855c",
#         "EnableDns64": false,
#         "Ipv6Native": false,
#         "PrivateDnsNameOptionsOnLaunch": {
#             "HostnameType": "ip-name",
#             "EnableResourceNameDnsARecord": false,
#             "EnableResourceNameDnsAAAARecord": false
#         }
#     }
# }

# Capture subnet IDs from the output above, then associate with rtb-backend.
# Alternatively run this block after substituting the real IDs.
SUBNET_BACKEND_A="subnet-01a513292ea15ae83"
SUBNET_BACKEND_B="subnet-08213d03f2940855c"

echo "# Associate Backend-a with rtb-backend"
aws ec2 associate-route-table \
  --route-table-id "${RTB_BACKEND}" \
  --subnet-id "${SUBNET_BACKEND_A}" \
  --region "${REGION}"

echo "# Associate Backend-b with rtb-backend"
aws ec2 associate-route-table \
  --route-table-id "${RTB_BACKEND}" \
  --subnet-id "${SUBNET_BACKEND_B}" \
  --region "${REGION}"

# RESULT
#
# Associate Backend-a with rtb-backend
# {
#     "AssociationId": "rtbassoc-089a7aa2be89c4108",
#     "AssociationState": {
#         "State": "associated"
#     }
# }
# # Associate Backend-b with rtb-backend
# {
#     "AssociationId": "rtbassoc-096250cae8b4a2177",
#     "AssociationState": {
#         "State": "associated"
#     }
# }
