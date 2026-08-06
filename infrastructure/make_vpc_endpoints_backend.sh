#!/usr/bin/env bash
set -euo pipefail
#
# make_vpc_endpoints_backend.sh
#
# Creates VPC endpoints so backend servers (in Backend-a/b subnets) can reach
# AWS services without leaving the VPC.  This is essential for the routing
# model where 0.0.0.0/0 points to the Return GW: without these endpoints,
# ECR image pulls, SSM agent traffic, and S3 access would be routed via the
# Return GW -> NAT GW chain, which works but adds latency and loads the Return GW.
#
# With these endpoints all AWS service DNS names resolve to 172.16.x.x private
# IPs, which hit the local VPC route and never reach the Return GW.
#
# Endpoints created:
#   ecr.api    (interface) -- GetAuthorizationToken and image manifest calls
#   ecr.dkr    (interface) -- Docker image layer pulls
#   s3         (gateway)   -- ECR stores image layers in S3; also general S3
#   ssm        (interface) -- Systems Manager agent (optional, for container mgmt)
#   ec2messages (interface)-- SSM dependency
#   ssmmessages (interface)-- SSM dependency
#
# The interface endpoints are placed in both backend subnets and protected by
# sg-endpoints (created below), which allows HTTPS from the backend CIDR only.
# The S3 gateway endpoint is added directly to rtb-backend (no SG needed for
# gateway endpoints -- they are route-based).
#
# Run make_subnets_backend.sh first and substitute the subnet IDs below.

REGION="eu-west-2"
VPC_ID="vpc-0595e17ce290fb050"
RTB_BACKEND="rtb-0a446e715fc3ec757"

# Fill in after running make_subnets_backend.sh
SUBNET_BACKEND_A="subnet-01a513292ea15ae83"
SUBNET_BACKEND_B="subnet-08213d03f2940855c"

# ── Security group for VPC interface endpoints ─────────────────────────────
#
# Allows HTTPS inbound from both backend subnets.  The SG is attached to each
# interface endpoint ENI; it does not need to be attached to the backend tasks
# themselves.

# echo "# Create SG for VPC interface endpoints"
# aws ec2 create-security-group \
#   --vpc-id "${VPC_ID}" \
#   --group-name FleetShell-IPSec-sg-endpoints \
#   --description "VPC interface endpoints: HTTPS from backend subnets" \
#   --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=FleetShell-IPSec-sg-endpoints}]' \
#   --region "${REGION}"

# RESULT
# # Create SG for VPC interface endpoints
# {
#     "GroupId": "sg-0438c989d6fe0f276",
#     "Tags": [
#         {
#             "Key": "Name",
#             "Value": "FleetShell-IPSec-sg-endpoints"
#         }
#     ]
# }

# Substitute the SG ID printed above before running the authorize call.
SG_ENDPOINTS="sg-0438c989d6fe0f276"

echo "# Allow HTTPS from backend subnets"
aws ec2 authorize-security-group-ingress \
  --group-id "${SG_ENDPOINTS}" \
  --ip-permissions '[
    {"IpProtocol":"tcp","FromPort":443,"ToPort":443,
     "IpRanges":[
       {"CidrIp":"172.16.53.0/24","Description":"Backend-a"},
       {"CidrIp":"172.16.54.0/24","Description":"Backend-b"}
     ]}
  ]' \
  --region "${REGION}"

# ── S3 gateway endpoint ────────────────────────────────────────────────────
#
# Gateway endpoints are free, route-based, and require no SG.  Adding one to
# rtb-backend causes S3 DNS names to resolve to prefix-list routes inside the
# VPC, so S3 traffic (ECR layer downloads, etc.) never leaves the VPC fabric.

echo "# S3 gateway endpoint -- added to rtb-backend"
aws ec2 create-vpc-endpoint \
  --vpc-id "${VPC_ID}" \
  --service-name com.amazonaws.eu-west-2.s3 \
  --vpc-endpoint-type Gateway \
  --route-table-ids "${RTB_BACKEND}" \
  --tag-specifications 'ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=FleetShell-IPSec-ep-s3}]' \
  --region "${REGION}"

# ── ECR interface endpoints ────────────────────────────────────────────────

echo "# ECR API endpoint (GetAuthorizationToken, DescribeRepositories, ...)"
aws ec2 create-vpc-endpoint \
  --vpc-id "${VPC_ID}" \
  --service-name com.amazonaws.eu-west-2.ecr.api \
  --vpc-endpoint-type Interface \
  --subnet-ids "${SUBNET_BACKEND_A}" "${SUBNET_BACKEND_B}" \
  --security-group-ids "${SG_ENDPOINTS}" \
  --private-dns-enabled \
  --tag-specifications 'ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=FleetShell-IPSec-ep-ecr-api}]' \
  --region "${REGION}"

echo "# ECR DKR endpoint (docker pull)"
aws ec2 create-vpc-endpoint \
  --vpc-id "${VPC_ID}" \
  --service-name com.amazonaws.eu-west-2.ecr.dkr \
  --vpc-endpoint-type Interface \
  --subnet-ids "${SUBNET_BACKEND_A}" "${SUBNET_BACKEND_B}" \
  --security-group-ids "${SG_ENDPOINTS}" \
  --private-dns-enabled \
  --tag-specifications 'ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=FleetShell-IPSec-ep-ecr-dkr}]' \
  --region "${REGION}"

# ── SSM interface endpoints (optional -- needed if using SSM for shell access) ──

echo "# SSM endpoint"
aws ec2 create-vpc-endpoint \
  --vpc-id "${VPC_ID}" \
  --service-name com.amazonaws.eu-west-2.ssm \
  --vpc-endpoint-type Interface \
  --subnet-ids "${SUBNET_BACKEND_A}" "${SUBNET_BACKEND_B}" \
  --security-group-ids "${SG_ENDPOINTS}" \
  --private-dns-enabled \
  --tag-specifications 'ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=FleetShell-IPSec-ep-ssm}]' \
  --region "${REGION}"

echo "# SSM messages endpoint"
aws ec2 create-vpc-endpoint \
  --vpc-id "${VPC_ID}" \
  --service-name com.amazonaws.eu-west-2.ssmmessages \
  --vpc-endpoint-type Interface \
  --subnet-ids "${SUBNET_BACKEND_A}" "${SUBNET_BACKEND_B}" \
  --security-group-ids "${SG_ENDPOINTS}" \
  --private-dns-enabled \
  --tag-specifications 'ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=FleetShell-IPSec-ep-ssmmessages}]' \
  --region "${REGION}"

echo "# EC2 messages endpoint (SSM dependency)"
aws ec2 create-vpc-endpoint \
  --vpc-id "${VPC_ID}" \
  --service-name com.amazonaws.eu-west-2.ec2messages \
  --vpc-endpoint-type Interface \
  --subnet-ids "${SUBNET_BACKEND_A}" "${SUBNET_BACKEND_B}" \
  --security-group-ids "${SG_ENDPOINTS}" \
  --private-dns-enabled \
  --tag-specifications 'ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=FleetShell-IPSec-ep-ec2messages}]' \
  --region "${REGION}"

# RESUlT
# # Allow HTTPS from backend subnets
# {
#     "Return": true,
#     "SecurityGroupRules": [
#         {
#             "SecurityGroupRuleId": "sgr-00066795d11e2a7a2",
#             "GroupId": "sg-0438c989d6fe0f276",
#             "GroupOwnerId": "295934382486",
#             "IsEgress": false,
#             "IpProtocol": "tcp",
#             "FromPort": 443,
#             "ToPort": 443,
#             "CidrIpv4": "172.16.53.0/24",
#             "Description": "Backend-a"
#         },
#         {
#             "SecurityGroupRuleId": "sgr-0a5cbbcdc340e3ffd",
#             "GroupId": "sg-0438c989d6fe0f276",
#             "GroupOwnerId": "295934382486",
#             "IsEgress": false,
#             "IpProtocol": "tcp",
#             "FromPort": 443,
#             "ToPort": 443,
#             "CidrIpv4": "172.16.54.0/24",
#             "Description": "Backend-b"
#         }
#     ]
# }

# # S3 gateway endpoint -- added to rtb-backend
# {
#     "VpcEndpoint": {
#         "VpcEndpointId": "vpce-0e96b7a35f98814ee",
#         "VpcEndpointType": "Gateway",
#         "VpcId": "vpc-0595e17ce290fb050",
#         "ServiceName": "com.amazonaws.eu-west-2.s3",
#         "State": "available",
#         "PolicyDocument": "{\"Version\":\"2008-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":\"*\",\"Action\":\"*\",\"Resource\":\"*\"}]}",
#         "RouteTableIds": [
#             "rtb-0a446e715fc3ec757"
#         ],
#         "SubnetIds": [],
#         "Groups": [],
#         "IpAddressType": "ipv4",
#         "DnsOptions": {
#             "DnsRecordIpType": "service-defined"
#         },
#         "PrivateDnsEnabled": false,
#         "RequesterManaged": false,
#         "NetworkInterfaceIds": [],
#         "DnsEntries": [],
#         "CreationTimestamp": "2026-08-06T10:19:56+00:00",
#         "Tags": [
#             {
#                 "Key": "Name",
#                 "Value": "FleetShell-IPSec-ep-s3"
#             }
#         ],
#         "OwnerId": "295934382486"
#     }
# }

# # ECR API endpoint (GetAuthorizationToken, DescribeRepositories, ...)
# {
#     "VpcEndpoint": {
#         "VpcEndpointId": "vpce-0ce0b1dbd9132e371",
#         "VpcEndpointType": "Interface",
#         "VpcId": "vpc-0595e17ce290fb050",
#         "ServiceName": "com.amazonaws.eu-west-2.ecr.api",
#         "State": "pending",
#         "RouteTableIds": [],
#         "SubnetIds": [
#             "subnet-01a513292ea15ae83",
#             "subnet-08213d03f2940855c"
#         ],
#         "Groups": [
#             {
#                 "GroupId": "sg-0438c989d6fe0f276",
#                 "GroupName": "FleetShell-IPSec-sg-endpoints"
#             }
#         ],
#         "IpAddressType": "ipv4",
#         "DnsOptions": {
#             "DnsRecordIpType": "ipv4"
#         },
#         "PrivateDnsEnabled": true,
#         "RequesterManaged": false,
#         "NetworkInterfaceIds": [
#             "eni-03676286ced8e4eff",
#             "eni-0917383fce7688bab"
#         ],
#         "DnsEntries": [
#             {
#                 "DnsName": "vpce-0ce0b1dbd9132e371-241a23fs.api.ecr.eu-west-2.vpce.amazonaws.com",
#                 "HostedZoneId": "Z7K1066E3PUKB"
#             },
#             {
#                 "DnsName": "vpce-0ce0b1dbd9132e371-241a23fs-eu-west-2a.api.ecr.eu-west-2.vpce.amazonaws.com",
#                 "HostedZoneId": "Z7K1066E3PUKB"
#             },
#             {
#                 "DnsName": "vpce-0ce0b1dbd9132e371-241a23fs-eu-west-2b.api.ecr.eu-west-2.vpce.amazonaws.com",
#                 "HostedZoneId": "Z7K1066E3PUKB"
#             },
#             {
#                 "DnsName": "api.ecr.eu-west-2.amazonaws.com",
#                 "HostedZoneId": "ZONEIDPENDING"
#             },
#             {
#                 "DnsName": "ecr.eu-west-2.api.aws",
#                 "HostedZoneId": "ZONEIDPENDING"
#             }
#         ],
#         "CreationTimestamp": "2026-08-06T10:19:57.903000+00:00",
#         "Tags": [
#             {
#                 "Key": "Name",
#                 "Value": "FleetShell-IPSec-ep-ecr-api"
#             }
#         ],
#         "OwnerId": "295934382486"
#     }
# }

# # ECR DKR endpoint (docker pull)
# {
#     "VpcEndpoint": {
#         "VpcEndpointId": "vpce-07e51ffc9257f76e2",
#         "VpcEndpointType": "Interface",
#         "VpcId": "vpc-0595e17ce290fb050",
#         "ServiceName": "com.amazonaws.eu-west-2.ecr.dkr",
#         "State": "pending",
#         "RouteTableIds": [],
#         "SubnetIds": [
#             "subnet-01a513292ea15ae83",
#             "subnet-08213d03f2940855c"
#         ],
#         "Groups": [
#             {
#                 "GroupId": "sg-0438c989d6fe0f276",
#                 "GroupName": "FleetShell-IPSec-sg-endpoints"
#             }
#         ],
#         "IpAddressType": "ipv4",
#         "DnsOptions": {
#             "DnsRecordIpType": "ipv4"
#         },
#         "PrivateDnsEnabled": true,
#         "RequesterManaged": false,
#         "NetworkInterfaceIds": [
#             "eni-053aa6ef1e910c230",
#             "eni-06612a4007ecb8456"
#         ],
#         "DnsEntries": [
#             {
#                 "DnsName": "vpce-07e51ffc9257f76e2-uz5j3lr2.dkr.ecr.eu-west-2.vpce.amazonaws.com",
#                 "HostedZoneId": "Z7K1066E3PUKB"
#             },
#             {
#                 "DnsName": "vpce-07e51ffc9257f76e2-uz5j3lr2-eu-west-2b.dkr.ecr.eu-west-2.vpce.amazonaws.com",
#                 "HostedZoneId": "Z7K1066E3PUKB"
#             },
#             {
#                 "DnsName": "vpce-07e51ffc9257f76e2-uz5j3lr2-eu-west-2a.dkr.ecr.eu-west-2.vpce.amazonaws.com",
#                 "HostedZoneId": "Z7K1066E3PUKB"
#             },
#             {
#                 "DnsName": "dkr.ecr.eu-west-2.amazonaws.com",
#                 "HostedZoneId": "ZONEIDPENDING"
#             },
#             {
#                 "DnsName": "*.dkr.ecr.eu-west-2.amazonaws.com",
#                 "HostedZoneId": "ZONEIDPENDING"
#             },
#             {
#                 "DnsName": "dkr-ecr.eu-west-2.on.aws",
#                 "HostedZoneId": "ZONEIDPENDING"
#             },
#             {
#                 "DnsName": "*.dkr-ecr.eu-west-2.on.aws",
#                 "HostedZoneId": "ZONEIDPENDING"
#             }
#         ],
#         "CreationTimestamp": "2026-08-06T10:20:08.980000+00:00",
#         "Tags": [
#             {
#                 "Key": "Name",
#                 "Value": "FleetShell-IPSec-ep-ecr-dkr"
#             }
#         ],
#         "OwnerId": "295934382486"
#     }
# }

# # SSM endpoint
# {
#     "VpcEndpoint": {
#         "VpcEndpointId": "vpce-007ba3bbe76f41014",
#         "VpcEndpointType": "Interface",
#         "VpcId": "vpc-0595e17ce290fb050",
#         "ServiceName": "com.amazonaws.eu-west-2.ssm",
#         "State": "pending",
#         "RouteTableIds": [],
#         "SubnetIds": [
#             "subnet-01a513292ea15ae83",
#             "subnet-08213d03f2940855c"
#         ],
#         "Groups": [
#             {
#                 "GroupId": "sg-0438c989d6fe0f276",
#                 "GroupName": "FleetShell-IPSec-sg-endpoints"
#             }
#         ],
#         "IpAddressType": "ipv4",
#         "DnsOptions": {
#             "DnsRecordIpType": "ipv4"
#         },
#         "PrivateDnsEnabled": true,
#         "RequesterManaged": false,
#         "NetworkInterfaceIds": [
#             "eni-063eeea689d03a2e2",
#             "eni-04b3131305e96e124"
#         ],
#         "DnsEntries": [
#             {
#                 "DnsName": "vpce-007ba3bbe76f41014-p72zx6n1.ssm.eu-west-2.vpce.amazonaws.com",
#                 "HostedZoneId": "Z7K1066E3PUKB"
#             },
#             {
#                 "DnsName": "vpce-007ba3bbe76f41014-p72zx6n1-eu-west-2b.ssm.eu-west-2.vpce.amazonaws.com",
#                 "HostedZoneId": "Z7K1066E3PUKB"
#             },
#             {
#                 "DnsName": "vpce-007ba3bbe76f41014-p72zx6n1-eu-west-2a.ssm.eu-west-2.vpce.amazonaws.com",
#                 "HostedZoneId": "Z7K1066E3PUKB"
#             },
#             {
#                 "DnsName": "ssm.eu-west-2.amazonaws.com",
#                 "HostedZoneId": "ZONEIDPENDING"
#             },
#             {
#                 "DnsName": "ssm.eu-west-2.api.aws",
#                 "HostedZoneId": "ZONEIDPENDING"
#             }
#         ],
#         "CreationTimestamp": "2026-08-06T10:20:13.487000+00:00",
#         "Tags": [
#             {
#                 "Key": "Name",
#                 "Value": "FleetShell-IPSec-ep-ssm"
#             }
#         ],
#         "OwnerId": "295934382486"
#     }
# }

# # SSM messages endpoint
# {
#     "VpcEndpoint": {
#         "VpcEndpointId": "vpce-0e76ffe5b3bfa9533",
#         "VpcEndpointType": "Interface",
#         "VpcId": "vpc-0595e17ce290fb050",
#         "ServiceName": "com.amazonaws.eu-west-2.ssmmessages",
#         "State": "pending",
#         "RouteTableIds": [],
#         "SubnetIds": [
#             "subnet-01a513292ea15ae83",
#             "subnet-08213d03f2940855c"
#         ],
#         "Groups": [
#             {
#                 "GroupId": "sg-0438c989d6fe0f276",
#                 "GroupName": "FleetShell-IPSec-sg-endpoints"
#             }
#         ],
#         "IpAddressType": "ipv4",
#         "DnsOptions": {
#             "DnsRecordIpType": "ipv4"
#         },
#         "PrivateDnsEnabled": true,
#         "RequesterManaged": false,
#         "NetworkInterfaceIds": [
#             "eni-0d7decb4252c876e7",
#             "eni-04a4c12947a52030f"
#         ],
#         "DnsEntries": [
#             {
#                 "DnsName": "vpce-0e76ffe5b3bfa9533-5vsor52i.ssmmessages.eu-west-2.vpce.amazonaws.com",
#                 "HostedZoneId": "Z7K1066E3PUKB"
#             },
#             {
#                 "DnsName": "vpce-0e76ffe5b3bfa9533-5vsor52i-eu-west-2b.ssmmessages.eu-west-2.vpce.amazonaws.com",
#                 "HostedZoneId": "Z7K1066E3PUKB"
#             },
#             {
#                 "DnsName": "vpce-0e76ffe5b3bfa9533-5vsor52i-eu-west-2a.ssmmessages.eu-west-2.vpce.amazonaws.com",
#                 "HostedZoneId": "Z7K1066E3PUKB"
#             },
#             {
#                 "DnsName": "ssmmessages.eu-west-2.amazonaws.com",
#                 "HostedZoneId": "ZONEIDPENDING"
#             },
#             {
#                 "DnsName": "ssmmessages.eu-west-2.api.aws",
#                 "HostedZoneId": "ZONEIDPENDING"
#             }
#         ],
#         "CreationTimestamp": "2026-08-06T10:20:17.870000+00:00",
#         "Tags": [
#             {
#                 "Key": "Name",
#                 "Value": "FleetShell-IPSec-ep-ssmmessages"
#             }
#         ],
#         "OwnerId": "295934382486"
#     }
# }

# # EC2 messages endpoint (SSM dependency)
# {
#     "VpcEndpoint": {
#         "VpcEndpointId": "vpce-0d3947acf8d9bf3e5",
#         "VpcEndpointType": "Interface",
#         "VpcId": "vpc-0595e17ce290fb050",
#         "ServiceName": "com.amazonaws.eu-west-2.ec2messages",
#         "State": "pending",
#         "RouteTableIds": [],
#         "SubnetIds": [
#             "subnet-01a513292ea15ae83",
#             "subnet-08213d03f2940855c"
#         ],
#         "Groups": [
#             {
#                 "GroupId": "sg-0438c989d6fe0f276",
#                 "GroupName": "FleetShell-IPSec-sg-endpoints"
#             }
#         ],
#         "IpAddressType": "ipv4",
#         "DnsOptions": {
#             "DnsRecordIpType": "ipv4"
#         },
#         "PrivateDnsEnabled": true,
#         "RequesterManaged": false,
#         "NetworkInterfaceIds": [
#             "eni-051a1fc93d7084e28",
#             "eni-00427bf5566931c14"
#         ],
#         "DnsEntries": [
#             {
#                 "DnsName": "vpce-0d3947acf8d9bf3e5-vyzjlhvt.ec2messages.eu-west-2.vpce.amazonaws.com",
#                 "HostedZoneId": "Z7K1066E3PUKB"
#             },
#             {
#                 "DnsName": "vpce-0d3947acf8d9bf3e5-vyzjlhvt-eu-west-2b.ec2messages.eu-west-2.vpce.amazonaws.com",
#                 "HostedZoneId": "Z7K1066E3PUKB"
#             },
#             {
#                 "DnsName": "vpce-0d3947acf8d9bf3e5-vyzjlhvt-eu-west-2a.ec2messages.eu-west-2.vpce.amazonaws.com",
#                 "HostedZoneId": "Z7K1066E3PUKB"
#             },
#             {
#                 "DnsName": "ec2messages.eu-west-2.amazonaws.com",
#                 "HostedZoneId": "ZONEIDPENDING"
#             }
#         ],
#         "CreationTimestamp": "2026-08-06T10:20:21.384000+00:00",
#         "Tags": [
#             {
#                 "Key": "Name",
#                 "Value": "FleetShell-IPSec-ep-ec2messages"
#             }
#         ],
#         "OwnerId": "295934382486"
#     }
# }



