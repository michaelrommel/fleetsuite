#!/usr/bin/env bash
set -euo pipefail
#
# update_lt_vpn_ami.sh
#
# Creates a new Launch Template version pointing to a freshly built
# fleetnode Packer AMI.  Run this after every successful Packer build.
#
# Usage: AMI_ID=ami-xxxx bash update_lt_vpn_ami.sh

AMI_ID="${AMI_ID:?Set AMI_ID env var to the new fleetnode AMI ID}"

echo "# Creating new LT version: fleetipsec-lt-vpn -> $AMI_ID"
aws ec2 create-launch-template-version \
  --launch-template-name fleetipsec-lt-vpn \
  --source-version '$Latest' \
  --version-description "fleetnode AMI $AMI_ID" \
  --launch-template-data "{\"ImageId\":\"${AMI_ID}\"}" \
  --region eu-west-2

echo "# Setting as default"
aws ec2 modify-launch-template \
  --launch-template-name fleetipsec-lt-vpn \
  --default-version '$Latest' \
  --region eu-west-2

echo "# Verifying"
aws ec2 describe-launch-template-versions \
  --launch-template-name fleetipsec-lt-vpn \
  --region eu-west-2 \
  --query 'LaunchTemplateVersions[*].{Ver:VersionNumber,Default:DefaultVersion,Desc:VersionDescription}'

#RESULT

# Creating new LT version: fleetipsec-lt-vpn -> ami-0e4b56716bd7d28f6
# {
#     "LaunchTemplateVersion": {
#         "LaunchTemplateId": "lt-02a4499a34fa61c3b",
#         "LaunchTemplateName": "fleetipsec-lt-vpn",
#         "VersionNumber": 4,
#         "VersionDescription": "fleetnode AMI ami-0e4b56716bd7d28f6",
#         "CreateTime": "2026-08-03T07:58:12+00:00",
#         "CreatedBy": "arn:aws:sts::295934382486:assumed-role/AWSReservedSSO_CLI-Role-PowerUserAndVPC_3a45f6c9035e1a71/michael.rommel@siemens-healthineers.com",
#         "DefaultVersion": false,
#         "LaunchTemplateData": {
#             "IamInstanceProfile": {
#                 "Arn": "arn:aws:iam::295934382486:instance-profile/fleetipsec-vpn-profile"
#             },
#             "NetworkInterfaces": [
#                 {
#                     "AssociatePublicIpAddress": false,
#                     "DeviceIndex": 0,
#                     "Groups": [
#                         "sg-04dcc0342150eb53b"
#                     ]
#                 }
#             ],
#             "ImageId": "ami-0e4b56716bd7d28f6",
#             "InstanceType": "c6in.xlarge",
#             "KeyName": "rommel@md151vfc",
#             "InstanceInitiatedShutdownBehavior": "terminate",
#             "UserData": "IyEvYmluL2Jhc2gKIyBEaXNhYmxlIHNyYy9kZXN0IGNoZWNrIG9uIGV0aDAgYXQgZmlyc3QgYm9vdC4KIyBSZXF1aXJlZCBmb3IgVlBQIDE6MSBOQVQgZm9yd2FyZGluZyAtLSBtYXBwZWQgSVBzIGFyZSBub3QgYXNzaWduZWQgdG8gZXRoMC4Kc2V0IC1lClRPS0VOPSQoY3VybCAtc2YgLVggUFVUICJodHRwOi8vMTY5LjI1NC4xNjkuMjU0L2xhdGVzdC9hcGkvdG9rZW4iIFwKICAtSCAiWC1hd3MtZWMyLW1ldGFkYXRhLXRva2VuLXR0bC1zZWNvbmRzOiAyMTYwMCIpCk1BQz0kKGN1cmwgLXNmIC1IICJYLWF3cy1lYzItbWV0YWRhdGEtdG9rZW46ICRUT0tFTiIgXAogICJodHRwOi8vMTY5LjI1NC4xNjkuMjU0L2xhdGVzdC9tZXRhLWRhdGEvbWFjIikKRU5JX0lEPSQoY3VybCAtc2YgLUggIlgtYXdzLWVjMi1tZXRhZGF0YS10b2tlbjogJFRPS0VOIiBcCiAgImh0dHA6Ly8xNjkuMjU0LjE2OS4yNTQvbGF0ZXN0L21ldGEtZGF0YS9uZXR3b3JrL2ludGVyZmFjZXMvbWFjcy8ke01BQ30vaW50ZXJmYWNlLWlkIikKUkVHSU9OPSQoY3VybCAtc2YgLUggIlgtYXdzLWVjMi1tZXRhZGF0YS10b2tlbjogJFRPS0VOIiBcCiAgImh0dHA6Ly8xNjkuMjU0LjE2OS4yNTQvbGF0ZXN0L21ldGEtZGF0YS9wbGFjZW1lbnQvcmVnaW9uIikKYXdzIGVjMiBtb2RpZnktbmV0d29yay1pbnRlcmZhY2UtYXR0cmlidXRlIFwKICAtLW5ldHdvcmstaW50ZXJmYWNlLWlkICIkRU5JX0lEIiBcCiAgLS1uby1zb3VyY2UtZGVzdC1jaGVjayBcCiAgLS1yZWdpb24gIiRSRUdJT04iCmVjaG8gInNyYy9kZXN0IGNoZWNrIGRpc2FibGVkIG9uICRFTklfSUQiCg==",
#             "TagSpecifications": [
#                 {
#                     "ResourceType": "instance",
#                     "Tags": [
#                         {
#                             "Key": "Name",
#                             "Value": "fleetipsec-vpn"
#                         },
#                         {
#                             "Key": "ipsec-vpn-cluster",
#                             "Value": "fleetipsec-vpn"
#                         },
#                         {
#                             "Key": "ipsec-vpn-asg",
#                             "Value": "fleetipsec-vpn"
#                         },
#                         {
#                             "Key": "ipsec-rds-endpoint",
#                             "Value": "fleetshell-ipsec-strongswan.cpgmocimewi5.eu-west-2.rds.amazonaws.com"
#                         },
#                         {
#                             "Key": "ipsec-valkey-endpoint",
#                             "Value": "clustercfg.dev-valkey-aeroftp.ak121m.memorydb.eu-west-2.amazonaws.com:6379"
#                         }
#                     ]
#                 }
#             ],
#             "MetadataOptions": {
#                 "HttpTokens": "required",
#                 "HttpEndpoint": "enabled",
#                 "InstanceMetadataTags": "enabled"
#             }
#         }
#     }
# }
# # Setting as default
# {
#     "LaunchTemplate": {
#         "LaunchTemplateId": "lt-02a4499a34fa61c3b",
#         "LaunchTemplateName": "fleetipsec-lt-vpn",
#         "CreateTime": "1970-01-01T00:00:00+00:00",
#         "CreatedBy": "arn:aws:sts::295934382486:assumed-role/AWSReservedSSO_CLI-Role-PowerUserAndVPC_3a45f6c9035e1a71/michael.rommel@siemens-healthineers.com",
#         "DefaultVersionNumber": 4,
#         "LatestVersionNumber": 4
#     }
# }
# # Verifying
# [
#     {
#         "Ver": 4,
#         "Default": true,
#         "Desc": "fleetnode AMI ami-0e4b56716bd7d28f6"
#     },
#     {
#         "Ver": 3,
#         "Default": false,
#         "Desc": "v3 - remove awscli user data; src/dest check handled by ipsecnode at startup"
#     },
#     {
#         "Ver": 2,
#         "Default": false,
#         "Desc": "v2 - user data disables src/dest check at boot for VPP NAT"
#     },
#     {
#         "Ver": 1,
#         "Default": false,
#         "Desc": "v1 - placeholder AMI; replace after first fleetnode Packer build"
#     }
# ]

#RESULT

# Creating new LT version: fleetipsec-lt-vpn -> ami-0fc1555de9422edb4
# {
#     "LaunchTemplateVersion": {
#         "LaunchTemplateId": "lt-02a4499a34fa61c3b",
#         "LaunchTemplateName": "fleetipsec-lt-vpn",
#         "VersionNumber": 5,
#         "VersionDescription": "fleetnode AMI ami-0fc1555de9422edb4",
#         "CreateTime": "2026-08-03T08:52:48+00:00",
#         "CreatedBy": "arn:aws:sts::295934382486:assumed-role/AWSReservedSSO_CLI-Role-PowerUserAndVPC_3a45f6c9035e1a71/michael.rommel@siemens-healthineers.com",
#         "DefaultVersion": false,
#         "LaunchTemplateData": {
#             "IamInstanceProfile": {
#                 "Arn": "arn:aws:iam::295934382486:instance-profile/fleetipsec-vpn-profile"
#             },
#             "NetworkInterfaces": [
#                 {
#                     "AssociatePublicIpAddress": false,
#                     "DeviceIndex": 0,
#                     "Groups": [
#                         "sg-04dcc0342150eb53b"
#                     ]
#                 }
#             ],
#             "ImageId": "ami-0fc1555de9422edb4",
#             "InstanceType": "c6in.xlarge",
#             "KeyName": "rommel@md151vfc",
#             "InstanceInitiatedShutdownBehavior": "terminate",
#             "UserData": "IyEvYmluL2Jhc2gKIyBEaXNhYmxlIHNyYy9kZXN0IGNoZWNrIG9uIGV0aDAgYXQgZmlyc3QgYm9vdC4KIyBSZXF1aXJlZCBmb3IgVlBQIDE6MSBOQVQgZm9yd2FyZGluZyAtLSBtYXBwZWQgSVBzIGFyZSBub3QgYXNzaWduZWQgdG8gZXRoMC4Kc2V0IC1lClRPS0VOPSQoY3VybCAtc2YgLVggUFVUICJodHRwOi8vMTY5LjI1NC4xNjkuMjU0L2xhdGVzdC9hcGkvdG9rZW4iIFwKICAtSCAiWC1hd3MtZWMyLW1ldGFkYXRhLXRva2VuLXR0bC1zZWNvbmRzOiAyMTYwMCIpCk1BQz0kKGN1cmwgLXNmIC1IICJYLWF3cy1lYzItbWV0YWRhdGEtdG9rZW46ICRUT0tFTiIgXAogICJodHRwOi8vMTY5LjI1NC4xNjkuMjU0L2xhdGVzdC9tZXRhLWRhdGEvbWFjIikKRU5JX0lEPSQoY3VybCAtc2YgLUggIlgtYXdzLWVjMi1tZXRhZGF0YS10b2tlbjogJFRPS0VOIiBcCiAgImh0dHA6Ly8xNjkuMjU0LjE2OS4yNTQvbGF0ZXN0L21ldGEtZGF0YS9uZXR3b3JrL2ludGVyZmFjZXMvbWFjcy8ke01BQ30vaW50ZXJmYWNlLWlkIikKUkVHSU9OPSQoY3VybCAtc2YgLUggIlgtYXdzLWVjMi1tZXRhZGF0YS10b2tlbjogJFRPS0VOIiBcCiAgImh0dHA6Ly8xNjkuMjU0LjE2OS4yNTQvbGF0ZXN0L21ldGEtZGF0YS9wbGFjZW1lbnQvcmVnaW9uIikKYXdzIGVjMiBtb2RpZnktbmV0d29yay1pbnRlcmZhY2UtYXR0cmlidXRlIFwKICAtLW5ldHdvcmstaW50ZXJmYWNlLWlkICIkRU5JX0lEIiBcCiAgLS1uby1zb3VyY2UtZGVzdC1jaGVjayBcCiAgLS1yZWdpb24gIiRSRUdJT04iCmVjaG8gInNyYy9kZXN0IGNoZWNrIGRpc2FibGVkIG9uICRFTklfSUQiCg==",
#             "TagSpecifications": [
#                 {
#                     "ResourceType": "instance",
#                     "Tags": [
#                         {
#                             "Key": "Name",
#                             "Value": "fleetipsec-vpn"
#                         },
#                         {
#                             "Key": "ipsec-vpn-cluster",
#                             "Value": "fleetipsec-vpn"
#                         },
#                         {
#                             "Key": "ipsec-vpn-asg",
#                             "Value": "fleetipsec-vpn"
#                         },
#                         {
#                             "Key": "ipsec-rds-endpoint",
#                             "Value": "fleetshell-ipsec-strongswan.cpgmocimewi5.eu-west-2.rds.amazonaws.com"
#                         },
#                         {
#                             "Key": "ipsec-valkey-endpoint",
#                             "Value": "clustercfg.dev-valkey-aeroftp.ak121m.memorydb.eu-west-2.amazonaws.com:6379"
#                         }
#                     ]
#                 }
#             ],
#             "MetadataOptions": {
#                 "HttpTokens": "required",
#                 "HttpEndpoint": "enabled",
#                 "InstanceMetadataTags": "enabled"
#             }
#         }
#     }
# }
# # Setting as default
# {
#     "LaunchTemplate": {
#         "LaunchTemplateId": "lt-02a4499a34fa61c3b",
#         "LaunchTemplateName": "fleetipsec-lt-vpn",
#         "CreateTime": "1970-01-01T00:00:00+00:00",
#         "CreatedBy": "arn:aws:sts::295934382486:assumed-role/AWSReservedSSO_CLI-Role-PowerUserAndVPC_3a45f6c9035e1a71/michael.rommel@siemens-healthineers.com",
#         "DefaultVersionNumber": 5,
#         "LatestVersionNumber": 5
#     }
# }
# # Verifying
# [
#     {
#         "Ver": 5,
#         "Default": true,
#         "Desc": "fleetnode AMI ami-0fc1555de9422edb4"
#     },
#     {
#         "Ver": 4,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-0e4b56716bd7d28f6"
#     },
#     {
#         "Ver": 3,
#         "Default": false,
#         "Desc": "v3 - remove awscli user data; src/dest check handled by ipsecnode at startup"
#     },
#     {
#         "Ver": 2,
#         "Default": false,
#         "Desc": "v2 - user data disables src/dest check at boot for VPP NAT"
#     },
#     {
#         "Ver": 1,
#         "Default": false,
#         "Desc": "v1 - placeholder AMI; replace after first fleetnode Packer build"
#     }
# ]

#RESULT

# Creating new LT version: fleetipsec-lt-vpn -> ami-05cb5d404a127a9e7
# {
#     "LaunchTemplateVersion": {
#         "LaunchTemplateId": "lt-02a4499a34fa61c3b",
#         "LaunchTemplateName": "fleetipsec-lt-vpn",
#         "VersionNumber": 6,
#         "VersionDescription": "fleetnode AMI ami-05cb5d404a127a9e7",
#         "CreateTime": "2026-08-03T15:09:03+00:00",
#         "CreatedBy": "arn:aws:sts::295934382486:assumed-role/AWSReservedSSO_CLI-Role-PowerUserAndVPC_3a45f6c9035e1a71/michael.rommel@siemens-healthineers.com",
#         "DefaultVersion": false,
#         "LaunchTemplateData": {
#             "IamInstanceProfile": {
#                 "Arn": "arn:aws:iam::295934382486:instance-profile/fleetipsec-vpn-profile"
#             },
#             "NetworkInterfaces": [
#                 {
#                     "AssociatePublicIpAddress": false,
#                     "DeviceIndex": 0,
#                     "Groups": [
#                         "sg-04dcc0342150eb53b"
#                     ]
#                 }
#             ],
#             "ImageId": "ami-05cb5d404a127a9e7",
#             "InstanceType": "c6in.xlarge",
#             "KeyName": "rommel@md151vfc",
#             "InstanceInitiatedShutdownBehavior": "terminate",
#             "UserData": "IyEvYmluL2Jhc2gKIyBEaXNhYmxlIHNyYy9kZXN0IGNoZWNrIG9uIGV0aDAgYXQgZmlyc3QgYm9vdC4KIyBSZXF1aXJlZCBmb3IgVlBQIDE6MSBOQVQgZm9yd2FyZGluZyAtLSBtYXBwZWQgSVBzIGFyZSBub3QgYXNzaWduZWQgdG8gZXRoMC4Kc2V0IC1lClRPS0VOPSQoY3VybCAtc2YgLVggUFVUICJodHRwOi8vMTY5LjI1NC4xNjkuMjU0L2xhdGVzdC9hcGkvdG9rZW4iIFwKICAtSCAiWC1hd3MtZWMyLW1ldGFkYXRhLXRva2VuLXR0bC1zZWNvbmRzOiAyMTYwMCIpCk1BQz0kKGN1cmwgLXNmIC1IICJYLWF3cy1lYzItbWV0YWRhdGEtdG9rZW46ICRUT0tFTiIgXAogICJodHRwOi8vMTY5LjI1NC4xNjkuMjU0L2xhdGVzdC9tZXRhLWRhdGEvbWFjIikKRU5JX0lEPSQoY3VybCAtc2YgLUggIlgtYXdzLWVjMi1tZXRhZGF0YS10b2tlbjogJFRPS0VOIiBcCiAgImh0dHA6Ly8xNjkuMjU0LjE2OS4yNTQvbGF0ZXN0L21ldGEtZGF0YS9uZXR3b3JrL2ludGVyZmFjZXMvbWFjcy8ke01BQ30vaW50ZXJmYWNlLWlkIikKUkVHSU9OPSQoY3VybCAtc2YgLUggIlgtYXdzLWVjMi1tZXRhZGF0YS10b2tlbjogJFRPS0VOIiBcCiAgImh0dHA6Ly8xNjkuMjU0LjE2OS4yNTQvbGF0ZXN0L21ldGEtZGF0YS9wbGFjZW1lbnQvcmVnaW9uIikKYXdzIGVjMiBtb2RpZnktbmV0d29yay1pbnRlcmZhY2UtYXR0cmlidXRlIFwKICAtLW5ldHdvcmstaW50ZXJmYWNlLWlkICIkRU5JX0lEIiBcCiAgLS1uby1zb3VyY2UtZGVzdC1jaGVjayBcCiAgLS1yZWdpb24gIiRSRUdJT04iCmVjaG8gInNyYy9kZXN0IGNoZWNrIGRpc2FibGVkIG9uICRFTklfSUQiCg==",
#             "TagSpecifications": [
#                 {
#                     "ResourceType": "instance",
#                     "Tags": [
#                         {
#                             "Key": "Name",
#                             "Value": "fleetipsec-vpn"
#                         },
#                         {
#                             "Key": "ipsec-vpn-cluster",
#                             "Value": "fleetipsec-vpn"
#                         },
#                         {
#                             "Key": "ipsec-vpn-asg",
#                             "Value": "fleetipsec-vpn"
#                         },
#                         {
#                             "Key": "ipsec-rds-endpoint",
#                             "Value": "fleetshell-ipsec-strongswan.cpgmocimewi5.eu-west-2.rds.amazonaws.com"
#                         },
#                         {
#                             "Key": "ipsec-valkey-endpoint",
#                             "Value": "clustercfg.dev-valkey-aeroftp.ak121m.memorydb.eu-west-2.amazonaws.com:6379"
#                         }
#                     ]
#                 }
#             ],
#             "MetadataOptions": {
#                 "HttpTokens": "required",
#                 "HttpEndpoint": "enabled",
#                 "InstanceMetadataTags": "enabled"
#             }
#         }
#     }
# }
# # Setting as default
# {
#     "LaunchTemplate": {
#         "LaunchTemplateId": "lt-02a4499a34fa61c3b",
#         "LaunchTemplateName": "fleetipsec-lt-vpn",
#         "CreateTime": "1970-01-01T00:00:00+00:00",
#         "CreatedBy": "arn:aws:sts::295934382486:assumed-role/AWSReservedSSO_CLI-Role-PowerUserAndVPC_3a45f6c9035e1a71/michael.rommel@siemens-healthineers.com",
#         "DefaultVersionNumber": 6,
#         "LatestVersionNumber": 6
#     }
# }
# # Verifying
# [
#     {
#         "Ver": 6,
#         "Default": true,
#         "Desc": "fleetnode AMI ami-05cb5d404a127a9e7"
#     },
#     {
#         "Ver": 5,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-0fc1555de9422edb4"
#     },
#     {
#         "Ver": 4,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-0e4b56716bd7d28f6"
#     },
#     {
#         "Ver": 3,
#         "Default": false,
#         "Desc": "v3 - remove awscli user data; src/dest check handled by ipsecnode at startup"
#     },
#     {
#         "Ver": 2,
#         "Default": false,
#         "Desc": "v2 - user data disables src/dest check at boot for VPP NAT"
#     },
#     {
#         "Ver": 1,
#         "Default": false,
#         "Desc": "v1 - placeholder AMI; replace after first fleetnode Packer build"
#     }
# ]
# RESULT
#
# Creating new LT version: fleetipsec-lt-vpn -> ami-0d3c80537d8b691f0
# {
#     "LaunchTemplateVersion": {
#         "LaunchTemplateId": "lt-02a4499a34fa61c3b",
#         "LaunchTemplateName": "fleetipsec-lt-vpn",
#         "VersionNumber": 7,
#         "VersionDescription": "fleetnode AMI ami-0d3c80537d8b691f0",
#         "CreateTime": "2026-08-03T17:34:27+00:00",
#         "CreatedBy": "arn:aws:sts::295934382486:assumed-role/AWSReservedSSO_CLI-Role-PowerUserAndVPC_3a45f6c9035e1a71/michael.rommel@siemens-healthineers.com",
#         "DefaultVersion": false,
#         "LaunchTemplateData": {
#             "IamInstanceProfile": {
#                 "Arn": "arn:aws:iam::295934382486:instance-profile/fleetipsec-vpn-profile"
#             },
#             "NetworkInterfaces": [
#                 {
#                     "AssociatePublicIpAddress": false,
#                     "DeviceIndex": 0,
#                     "Groups": [
#                         "sg-04dcc0342150eb53b"
#                     ]
#                 }
#             ],
#             "ImageId": "ami-0d3c80537d8b691f0",
#             "InstanceType": "c6in.xlarge",
#             "KeyName": "rommel@md151vfc",
#             "InstanceInitiatedShutdownBehavior": "terminate",
#             "UserData": "IyEvYmluL2Jhc2gKIyBEaXNhYmxlIHNyYy9kZXN0IGNoZWNrIG9uIGV0aDAgYXQgZmlyc3QgYm9vdC4KIyBSZXF1aXJlZCBmb3IgVlBQIDE6MSBOQVQgZm9yd2FyZGluZyAtLSBtYXBwZWQgSVBzIGFyZSBub3QgYXNzaWduZWQgdG8gZXRoMC4Kc2V0IC1lClRPS0VOPSQoY3VybCAtc2YgLVggUFVUICJodHRwOi8vMTY5LjI1NC4xNjkuMjU0L2xhdGVzdC9hcGkvdG9rZW4iIFwKICAtSCAiWC1hd3MtZWMyLW1ldGFkYXRhLXRva2VuLXR0bC1zZWNvbmRzOiAyMTYwMCIpCk1BQz0kKGN1cmwgLXNmIC1IICJYLWF3cy1lYzItbWV0YWRhdGEtdG9rZW46ICRUT0tFTiIgXAogICJodHRwOi8vMTY5LjI1NC4xNjkuMjU0L2xhdGVzdC9tZXRhLWRhdGEvbWFjIikKRU5JX0lEPSQoY3VybCAtc2YgLUggIlgtYXdzLWVjMi1tZXRhZGF0YS10b2tlbjogJFRPS0VOIiBcCiAgImh0dHA6Ly8xNjkuMjU0LjE2OS4yNTQvbGF0ZXN0L21ldGEtZGF0YS9uZXR3b3JrL2ludGVyZmFjZXMvbWFjcy8ke01BQ30vaW50ZXJmYWNlLWlkIikKUkVHSU9OPSQoY3VybCAtc2YgLUggIlgtYXdzLWVjMi1tZXRhZGF0YS10b2tlbjogJFRPS0VOIiBcCiAgImh0dHA6Ly8xNjkuMjU0LjE2OS4yNTQvbGF0ZXN0L21ldGEtZGF0YS9wbGFjZW1lbnQvcmVnaW9uIikKYXdzIGVjMiBtb2RpZnktbmV0d29yay1pbnRlcmZhY2UtYXR0cmlidXRlIFwKICAtLW5ldHdvcmstaW50ZXJmYWNlLWlkICIkRU5JX0lEIiBcCiAgLS1uby1zb3VyY2UtZGVzdC1jaGVjayBcCiAgLS1yZWdpb24gIiRSRUdJT04iCmVjaG8gInNyYy9kZXN0IGNoZWNrIGRpc2FibGVkIG9uICRFTklfSUQiCg==",
#             "TagSpecifications": [
#                 {
#                     "ResourceType": "instance",
#                     "Tags": [
#                         {
#                             "Key": "Name",
#                             "Value": "fleetipsec-vpn"
#                         },
#                         {
#                             "Key": "ipsec-vpn-cluster",
#                             "Value": "fleetipsec-vpn"                                                                      },
#                         {
#                             "Key": "ipsec-vpn-asg",
#                             "Value": "fleetipsec-vpn"
#                         },
#                         {
#                             "Key": "ipsec-rds-endpoint",
#                             "Value": "fleetshell-ipsec-strongswan.cpgmocimewi5.eu-west-2.rds.amazonaws.com"
#                         },
#                         {
#                             "Key": "ipsec-valkey-endpoint",
#                             "Value": "clustercfg.dev-valkey-aeroftp.ak121m.memorydb.eu-west-2.amazonaws.com:6379"
#                         }
#                     ]
#                 }
#             ],
#             "MetadataOptions": {
#                 "HttpTokens": "required",
#                 "HttpEndpoint": "enabled",
#                 "InstanceMetadataTags": "enabled"
#             }
#         }
#     }                                                                                              }
# # Setting as default
# {
#     "LaunchTemplate": {
#         "LaunchTemplateId": "lt-02a4499a34fa61c3b",
#         "LaunchTemplateName": "fleetipsec-lt-vpn",
#         "CreateTime": "1970-01-01T00:00:00+00:00",
#         "CreatedBy": "arn:aws:sts::295934382486:assumed-role/AWSReservedSSO_CLI-Role-PowerUserAndVPC_3a45f6c9035e1a71/michael.rommel@siemens-healthineers.com",
#         "DefaultVersionNumber": 7,
#         "LatestVersionNumber": 7
#     }
# }
# # Verifying
# [
#     {
#         "Ver": 7,
#         "Default": true,
#         "Desc": "fleetnode AMI ami-0d3c80537d8b691f0"
#     },
#     {
#         "Ver": 6,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-05cb5d404a127a9e7"
#     },
#     {
#         "Ver": 5,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-0fc1555de9422edb4"
#     },                                                                                                 {
#         "Ver": 4,                                                                                          "Default": false,                                                                                  "Desc": "fleetnode AMI ami-0e4b56716bd7d28f6"                                                  },                                                                                                 {
#         "Ver": 3,                                                                                          "Default": false,                                                                                  "Desc": "v3 - remove awscli user data; src/dest check handled by ipsecnode at startup"         },                                                                                                 {
#         "Ver": 2,                                                                                          "Default": false,                                                                                  "Desc": "v2 - user data disables src/dest check at boot for VPP NAT"                           },
#     {                                                                                                      "Ver": 1,
#         "Default": false,
#         "Desc": "v1 - placeholder AMI; replace after first fleetnode Packer build"                     }                                                                                              ]




# Creating new LT version: fleetipsec-lt-vpn -> ami-02dd075664df52991                              
# {
#     "LaunchTemplateVersion": {
#         "LaunchTemplateId": "lt-02a4499a34fa61c3b",
#         "LaunchTemplateName": "fleetipsec-lt-vpn",
#         "VersionNumber": 8,
#         "VersionDescription": "fleetnode AMI ami-02dd075664df52991",
#         "CreateTime": "2026-08-03T18:46:17+00:00",
#         "CreatedBy": "arn:aws:sts::295934382486:assumed-role/AWSReservedSSO_CLI-Role-PowerUserAndVPC_3a45f6c9035e1a71/michael.rommel@siemens-healthineers.com",
#         "DefaultVersion": false,
#         "LaunchTemplateData": {
#             "IamInstanceProfile": {
#                 "Arn": "arn:aws:iam::295934382486:instance-profile/fleetipsec-vpn-profile"
#             },
#             "NetworkInterfaces": [
#                 {
#                     "AssociatePublicIpAddress": false,
#                     "DeviceIndex": 0,
#                     "Groups": [
#                         "sg-04dcc0342150eb53b"
#                     ]
#                 }
#             ],                                                                                                 "ImageId": "ami-02dd075664df52991",
#             "InstanceType": "c6in.xlarge",
#             "KeyName": "rommel@md151vfc",
#             "InstanceInitiatedShutdownBehavior": "terminate",
#             "UserData": "IyEvYmluL2Jhc2gKIyBEaXNhYmxlIHNyYy9kZXN0IGNoZWNrIG9uIGV0aDAgYXQgZmlyc3QgYm9vdC4KIyBSZXF1aXJlZCBmb3IgVlBQIDE6MSBOQVQgZm9yd2FyZGluZyAtLSBtYXBwZWQgSVBzIGFyZSBub3QgYXNzaWduZWQgdG8gZXRoMC4Kc2V0IC1lClRPS0VOPSQoY3VybCAtc2YgLVggUFVUICJodHRwOi8vMTY5LjI1NC4xNjkuMjU0L2xhdGVzdC9hcGkvdG9rZW4iIFwKICAtSCAiWC1hd3MtZWMyLW1ldGFkYXRhLXRva2VuLXR0bC1zZWNvbmRzOiAyMTYwMCIpCk1BQz0kKGN1cmwgLXNmIC1IICJYLWF3cy1lYzItbWV0YWRhdGEtdG9rZW46ICRUT0tFTiIgXAogICJodHRwOi8vMTY5LjI1NC4xNjkuMjU0L2xhdGVzdC9tZXRhLWRhdGEvbWFjIikKRU5JX0lEPSQoY3VybCAtc2YgLUggIlgtYXdzLWVjMi1tZXRhZGF0YS10b2tlbjogJFRPS0VOIiBcCiAgImh0dHA6Ly8xNjkuMjU0LjE2OS4yNTQvbGF0ZXN0L21ldGEtZGF0YS9uZXR3b3JrL2ludGVyZmFjZXMvbWFjcy8ke01BQ30vaW50ZXJmYWNlLWlkIikKUkVHSU9OPSQoY3VybCAtc2YgLUggIlgtYXdzLWVjMi1tZXRhZGF0YS10b2tlbjogJFRPS0VOIiBcCiAgImh0dHA6Ly8xNjkuMjU0LjE2OS4yNTQvbGF0ZXN0L21ldGEtZGF0YS9wbGFjZW1lbnQvcmVnaW9uIikKYXdzIGVjMiBtb2RpZnktbmV0d29yay1pbnRlcmZhY2UtYXR0cmlidXRlIFwKICAtLW5ldHdvcmstaW50ZXJmYWNlLWlkICIkRU5JX0lEIiBcCiAgLS1uby1zb3VyY2UtZGVzdC1jaGVjayBcCiAgLS1yZWdpb24gIiRSRUdJT04iCmVjaG8gInNyYy9kZXN0IGNoZWNrIGRpc2FibGVkIG9uICRFTklfSUQiCg==",
#             "TagSpecifications": [
#                 {
#                     "ResourceType": "instance",
#                     "Tags": [
#                         {
#                             "Key": "Name",
#                             "Value": "fleetipsec-vpn"
#                         },
#                         {                                                                                                      "Key": "ipsec-vpn-cluster",
#                             "Value": "fleetipsec-vpn"
#                         },
#                         {
#                             "Key": "ipsec-vpn-asg",
#                             "Value": "fleetipsec-vpn"
#                         },
#                         {
#                             "Key": "ipsec-rds-endpoint",
#                             "Value": "fleetshell-ipsec-strongswan.cpgmocimewi5.eu-west-2.rds.amazonaws.com"
#                         },
#                         {
#                             "Key": "ipsec-valkey-endpoint",
#                             "Value": "clustercfg.dev-valkey-aeroftp.ak121m.memorydb.eu-west-2.amazonaws.com:6379"
#                         }
#                     ]
#                 }
#             ],
#             "MetadataOptions": {
#                 "HttpTokens": "required",
#                 "HttpEndpoint": "enabled",
#                 "InstanceMetadataTags": "enabled"
#             }
#         }
#     }
# }
# # Setting as default
# {                                                                                                      "LaunchTemplate": {
#         "LaunchTemplateId": "lt-02a4499a34fa61c3b",                                                        "LaunchTemplateName": "fleetipsec-lt-vpn",                                                         "CreateTime": "1970-01-01T00:00:00+00:00",                                                         "CreatedBy": "arn:aws:sts::295934382486:assumed-role/AWSReservedSSO_CLI-Role-PowerUserAndVPC_3a45f6c9035e1a71/michael.rommel@siemens-healthineers.com",
#         "DefaultVersionNumber": 8,
#         "LatestVersionNumber": 8                                                                       }                                                                                              }                                                                                                  # Verifying
#                                                                                         [
#     {                                                                                                      "Ver": 8,                                                                                          "Default": true,                                                                                   "Desc": "fleetnode AMI ami-02dd075664df52991"
#     },                                                                                                 {
#         "Ver": 7,
#         "Default": false,                                                                                  "Desc": "fleetnode AMI ami-0d3c80537d8b691f0"                                                  },
#     {
#         "Ver": 6,                                                                                          "Default": false,                                                                                  "Desc": "fleetnode AMI ami-05cb5d404a127a9e7"                                                  },    {
#         "Ver": 5,                                                                                          "Default": false,
#         "Desc": "fleetnode AMI ami-0fc1555de9422edb4"                                                  },                                                                                                 {                                                                                                      "Ver": 4,                                                                                          "Default": false,
#         "Desc": "fleetnode AMI ami-0e4b56716bd7d28f6"                                                  },                                                                                                 {                                                                                                      "Ver": 3,                                                                                          "Default": false,
#         "Desc": "v3 - remove awscli user data; src/dest check handled by ipsecnode at startup"         },                                                                                                 {                                                                                                      "Ver": 2,
#         "Default": false,                                                                                  "Desc": "v2 - user data disables src/dest check at boot for VPP NAT"
#     },
#     {                                                                                                      "Ver": 1,                                                                                          "Default": false,
#         "Desc": "v1 - placeholder AMI; replace after first fleetnode Packer build"
#     }                                                                                              ]

#RESULT

# Creating new LT version: fleetipsec-lt-vpn -> ami-0f15bdcd057ab75c5
# {
#     "LaunchTemplateVersion": {
#         "LaunchTemplateId": "lt-02a4499a34fa61c3b",
#         "LaunchTemplateName": "fleetipsec-lt-vpn",
#         "VersionNumber": 9,
#         "VersionDescription": "fleetnode AMI ami-0f15bdcd057ab75c5",
#         "CreateTime": "2026-08-04T06:06:17+00:00",
#         "CreatedBy": "arn:aws:sts::295934382486:assumed-role/AWSReservedSSO_CLI-Role-PowerUserAndVPC_3a45f6c9035e1a71/michael.rommel@siemens-healthineers.com",
#         "DefaultVersion": false,
#         "LaunchTemplateData": {
#             "IamInstanceProfile": {
#                 "Arn": "arn:aws:iam::295934382486:instance-profile/fleetipsec-vpn-profile"
#             },
#             "NetworkInterfaces": [
#                 {
#                     "AssociatePublicIpAddress": false,
#                     "DeviceIndex": 0,
#                     "Groups": [
#                         "sg-04dcc0342150eb53b"
#                     ]
#                 }
#             ],
#             "ImageId": "ami-0f15bdcd057ab75c5",
#             "InstanceType": "c6in.xlarge",
#             "KeyName": "rommel@md151vfc",
#             "InstanceInitiatedShutdownBehavior": "terminate",
#             "UserData": "IyEvYmluL2Jhc2gKIyBEaXNhYmxlIHNyYy9kZXN0IGNoZWNrIG9uIGV0aDAgYXQgZmlyc3QgYm9vdC4KIyBSZXF1aXJlZCBmb3IgVlBQIDE6MSBOQVQgZm9yd2FyZGluZyAtLSBtYXBwZWQgSVBzIGFyZSBub3QgYXNzaWduZWQgdG8gZXRoMC4Kc2V0IC1lClRPS0VOPSQoY3VybCAtc2YgLVggUFVUICJodHRwOi8vMTY5LjI1NC4xNjkuMjU0L2xhdGVzdC9hcGkvdG9rZW4iIFwKICAtSCAiWC1hd3MtZWMyLW1ldGFkYXRhLXRva2VuLXR0bC1zZWNvbmRzOiAyMTYwMCIpCk1BQz0kKGN1cmwgLXNmIC1IICJYLWF3cy1lYzItbWV0YWRhdGEtdG9rZW46ICRUT0tFTiIgXAogICJodHRwOi8vMTY5LjI1NC4xNjkuMjU0L2xhdGVzdC9tZXRhLWRhdGEvbWFjIikKRU5JX0lEPSQoY3VybCAtc2YgLUggIlgtYXdzLWVjMi1tZXRhZGF0YS10b2tlbjogJFRPS0VOIiBcCiAgImh0dHA6Ly8xNjkuMjU0LjE2OS4yNTQvbGF0ZXN0L21ldGEtZGF0YS9uZXR3b3JrL2ludGVyZmFjZXMvbWFjcy8ke01BQ30vaW50ZXJmYWNlLWlkIikKUkVHSU9OPSQoY3VybCAtc2YgLUggIlgtYXdzLWVjMi1tZXRhZGF0YS10b2tlbjogJFRPS0VOIiBcCiAgImh0dHA6Ly8xNjkuMjU0LjE2OS4yNTQvbGF0ZXN0L21ldGEtZGF0YS9wbGFjZW1lbnQvcmVnaW9uIikKYXdzIGVjMiBtb2RpZnktbmV0d29yay1pbnRlcmZhY2UtYXR0cmlidXRlIFwKICAtLW5ldHdvcmstaW50ZXJmYWNlLWlkICIkRU5JX0lEIiBcCiAgLS1uby1zb3VyY2UtZGVzdC1jaGVjayBcCiAgLS1yZWdpb24gIiRSRUdJT04iCmVjaG8gInNyYy9kZXN0IGNoZWNrIGRpc2FibGVkIG9uICRFTklfSUQiCg==",
#             "TagSpecifications": [
#                 {
#                     "ResourceType": "instance",
#                     "Tags": [
#                         {
#                             "Key": "Name",
#                             "Value": "fleetipsec-vpn"
#                         },
#                         {
#                             "Key": "ipsec-vpn-cluster",
#                             "Value": "fleetipsec-vpn"
#                         },
#                         {
#                             "Key": "ipsec-vpn-asg",
#                             "Value": "fleetipsec-vpn"
#                         },
#                         {
#                             "Key": "ipsec-rds-endpoint",
#                             "Value": "fleetshell-ipsec-strongswan.cpgmocimewi5.eu-west-2.rds.amazonaws.com"
#                         },
#                         {
#                             "Key": "ipsec-valkey-endpoint",
#                             "Value": "clustercfg.dev-valkey-aeroftp.ak121m.memorydb.eu-west-2.amazonaws.com:6379"
#                         }
#                     ]
#                 }
#             ],
#             "MetadataOptions": {
#                 "HttpTokens": "required",
#                 "HttpEndpoint": "enabled",
#                 "InstanceMetadataTags": "enabled"
#             }
#         }
#     }
# }
# # Setting as default
# {
#     "LaunchTemplate": {
#         "LaunchTemplateId": "lt-02a4499a34fa61c3b",
#         "LaunchTemplateName": "fleetipsec-lt-vpn",
#         "CreateTime": "1970-01-01T00:00:00+00:00",
#         "CreatedBy": "arn:aws:sts::295934382486:assumed-role/AWSReservedSSO_CLI-Role-PowerUserAndVPC_3a45f6c9035e1a71/michael.rommel@siemens-healthineers.com",
#         "DefaultVersionNumber": 9,
#         "LatestVersionNumber": 9
#     }
# }
# # Verifying
# [
#     {
#         "Ver": 9,
#         "Default": true,
#         "Desc": "fleetnode AMI ami-0f15bdcd057ab75c5"
#     },
#     {
#         "Ver": 8,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-02dd075664df52991"
#     },
#     {
#         "Ver": 7,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-0d3c80537d8b691f0"
#     },
#     {
#         "Ver": 6,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-05cb5d404a127a9e7"
#     },
#     {
#         "Ver": 5,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-0fc1555de9422edb4"
#     },
#     {
#         "Ver": 4,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-0e4b56716bd7d28f6"
#     },
#     {
#         "Ver": 3,
#         "Default": false,
#         "Desc": "v3 - remove awscli user data; src/dest check handled by ipsecnode at startup"
#     },
#     {
#         "Ver": 2,
#         "Default": false,
#         "Desc": "v2 - user data disables src/dest check at boot for VPP NAT"
#     },
#     {
#         "Ver": 1,
#         "Default": false,
#         "Desc": "v1 - placeholder AMI; replace after first fleetnode Packer build"
#     }
# ]

#RESULT

# Creating new LT version: fleetipsec-lt-vpn -> ami-0f15bdcd057ab75c5
# {
#     "LaunchTemplateVersion": {
#         "LaunchTemplateId": "lt-02a4499a34fa61c3b",
#         "LaunchTemplateName": "fleetipsec-lt-vpn",
#         "VersionNumber": 10,
#         "VersionDescription": "fleetnode AMI ami-0f15bdcd057ab75c5",
#         "CreateTime": "2026-08-04T08:02:23+00:00",
#         "CreatedBy": "arn:aws:sts::295934382486:assumed-role/AWSReservedSSO_CLI-Role-PowerUserAndVPC_3a45f6c9035e1a71/michael.rommel@siemens-healthineers.com",
#         "DefaultVersion": false,
#         "LaunchTemplateData": {
#             "IamInstanceProfile": {
#                 "Arn": "arn:aws:iam::295934382486:instance-profile/fleetipsec-vpn-profile"
#             },
#             "NetworkInterfaces": [
#                 {
#                     "AssociatePublicIpAddress": false,
#                     "DeviceIndex": 0,
#                     "Groups": [
#                         "sg-04dcc0342150eb53b"
#                     ]
#                 }
#             ],
#             "ImageId": "ami-0f15bdcd057ab75c5",
#             "InstanceType": "c6in.xlarge",
#             "KeyName": "rommel@md151vfc",
#             "InstanceInitiatedShutdownBehavior": "terminate",
#             "UserData": "IyEvYmluL2Jhc2gKIyBEaXNhYmxlIHNyYy9kZXN0IGNoZWNrIG9uIGV0aDAgYXQgZmlyc3QgYm9vdC4KIyBSZXF1aXJlZCBmb3IgVlBQIDE6MSBOQVQgZm9yd2FyZGluZyAtLSBtYXBwZWQgSVBzIGFyZSBub3QgYXNzaWduZWQgdG8gZXRoMC4Kc2V0IC1lClRPS0VOPSQoY3VybCAtc2YgLVggUFVUICJodHRwOi8vMTY5LjI1NC4xNjkuMjU0L2xhdGVzdC9hcGkvdG9rZW4iIFwKICAtSCAiWC1hd3MtZWMyLW1ldGFkYXRhLXRva2VuLXR0bC1zZWNvbmRzOiAyMTYwMCIpCk1BQz0kKGN1cmwgLXNmIC1IICJYLWF3cy1lYzItbWV0YWRhdGEtdG9rZW46ICRUT0tFTiIgXAogICJodHRwOi8vMTY5LjI1NC4xNjkuMjU0L2xhdGVzdC9tZXRhLWRhdGEvbWFjIikKRU5JX0lEPSQoY3VybCAtc2YgLUggIlgtYXdzLWVjMi1tZXRhZGF0YS10b2tlbjogJFRPS0VOIiBcCiAgImh0dHA6Ly8xNjkuMjU0LjE2OS4yNTQvbGF0ZXN0L21ldGEtZGF0YS9uZXR3b3JrL2ludGVyZmFjZXMvbWFjcy8ke01BQ30vaW50ZXJmYWNlLWlkIikKUkVHSU9OPSQoY3VybCAtc2YgLUggIlgtYXdzLWVjMi1tZXRhZGF0YS10b2tlbjogJFRPS0VOIiBcCiAgImh0dHA6Ly8xNjkuMjU0LjE2OS4yNTQvbGF0ZXN0L21ldGEtZGF0YS9wbGFjZW1lbnQvcmVnaW9uIikKYXdzIGVjMiBtb2RpZnktbmV0d29yay1pbnRlcmZhY2UtYXR0cmlidXRlIFwKICAtLW5ldHdvcmstaW50ZXJmYWNlLWlkICIkRU5JX0lEIiBcCiAgLS1uby1zb3VyY2UtZGVzdC1jaGVjayBcCiAgLS1yZWdpb24gIiRSRUdJT04iCmVjaG8gInNyYy9kZXN0IGNoZWNrIGRpc2FibGVkIG9uICRFTklfSUQiCg==",
#             "TagSpecifications": [
#                 {
#                     "ResourceType": "instance",
#                     "Tags": [
#                         {
#                             "Key": "Name",
#                             "Value": "fleetipsec-vpn"
#                         },
#                         {
#                             "Key": "ipsec-vpn-cluster",
#                             "Value": "fleetipsec-vpn"
#                         },
#                         {
#                             "Key": "ipsec-vpn-asg",
#                             "Value": "fleetipsec-vpn"
#                         },
#                         {
#                             "Key": "ipsec-rds-endpoint",
#                             "Value": "fleetshell-ipsec-strongswan.cpgmocimewi5.eu-west-2.rds.amazonaws.com"
#                         },
#                         {
#                             "Key": "ipsec-valkey-endpoint",
#                             "Value": "clustercfg.dev-valkey-aeroftp.ak121m.memorydb.eu-west-2.amazonaws.com:6379"
#                         }
#                     ]
#                 }
#             ],
#             "MetadataOptions": {
#                 "HttpTokens": "required",
#                 "HttpEndpoint": "enabled",
#                 "InstanceMetadataTags": "enabled"
#             }
#         }
#     }
# }
# # Setting as default
# {
#     "LaunchTemplate": {
#         "LaunchTemplateId": "lt-02a4499a34fa61c3b",
#         "LaunchTemplateName": "fleetipsec-lt-vpn",
#         "CreateTime": "1970-01-01T00:00:00+00:00",
#         "CreatedBy": "arn:aws:sts::295934382486:assumed-role/AWSReservedSSO_CLI-Role-PowerUserAndVPC_3a45f6c9035e1a71/michael.rommel@siemens-healthineers.com",
#         "DefaultVersionNumber": 10,
#         "LatestVersionNumber": 10
#     }
# }
# # Verifying
# [
#     {
#         "Ver": 10,
#         "Default": true,
#         "Desc": "fleetnode AMI ami-0f15bdcd057ab75c5"
#     },
#     {
#         "Ver": 9,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-0f15bdcd057ab75c5"
#     },
#     {
#         "Ver": 8,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-02dd075664df52991"
#     },
#     {
#         "Ver": 7,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-0d3c80537d8b691f0"
#     },
#     {
#         "Ver": 6,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-05cb5d404a127a9e7"
#     },
#     {
#         "Ver": 5,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-0fc1555de9422edb4"
#     },
#     {
#         "Ver": 4,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-0e4b56716bd7d28f6"
#     },
#     {
#         "Ver": 3,
#         "Default": false,
#         "Desc": "v3 - remove awscli user data; src/dest check handled by ipsecnode at startup"
#     },
#     {
#         "Ver": 2,
#         "Default": false,
#         "Desc": "v2 - user data disables src/dest check at boot for VPP NAT"
#     },
#     {
#         "Ver": 1,
#         "Default": false,
#         "Desc": "v1 - placeholder AMI; replace after first fleetnode Packer build"
#     }
# ]
#
#RESULT
# Creating new LT version: fleetipsec-lt-vpn -> ami-020c1ddbdd1b8c77d
# {
#     "LaunchTemplateVersion": {
#         "LaunchTemplateId": "lt-02a4499a34fa61c3b",
#         "LaunchTemplateName": "fleetipsec-lt-vpn",
#         "VersionNumber": 11,
#         "VersionDescription": "fleetnode AMI ami-020c1ddbdd1b8c77d",
#         "CreateTime": "2026-08-04T16:09:55+00:00",
#         "CreatedBy": "arn:aws:sts::295934382486:assumed-role/AWSReservedSSO_CLI-Role-PowerUserAndVPC_3a45f6c9035e1a71/michael.rommel@siemens-healthineers.com",
#         "DefaultVersion": false,
#         "LaunchTemplateData": {
#             "IamInstanceProfile": {
#                 "Arn": "arn:aws:iam::295934382486:instance-profile/fleetipsec-vpn-profile"
#             },
#             "NetworkInterfaces": [
#                 {
#                     "AssociatePublicIpAddress": false,
#                     "DeviceIndex": 0,
#                     "Groups": [
#                         "sg-04dcc0342150eb53b"
#                     ]
#                 }
#             ],
#             "ImageId": "ami-020c1ddbdd1b8c77d",
#             "InstanceType": "c6in.xlarge",
#             "KeyName": "rommel@md151vfc",
#             "InstanceInitiatedShutdownBehavior": "terminate",
#             "UserData": "IyEvYmluL2Jhc2gKIyBEaXNhYmxlIHNyYy9kZXN0IGNoZWNrIG9uIGV0aDAgYXQgZmlyc3QgYm9vdC4KIyBSZXF1aXJlZCBmb3IgVlBQIDE6MSBOQVQgZm9yd2FyZGluZyAtLSBtYXBwZWQgSVBzIGFyZSBub3QgYXNzaWduZWQgdG8gZXRoMC4Kc2V0IC1lClRPS0VOPSQoY3VybCAtc2YgLVggUFVUICJodHRwOi8vMTY5LjI1NC4xNjkuMjU0L2xhdGVzdC9hcGkvdG9rZW4iIFwKICAtSCAiWC1hd3MtZWMyLW1ldGFkYXRhLXRva2VuLXR0bC1zZWNvbmRzOiAyMTYwMCIpCk1BQz0kKGN1cmwgLXNmIC1IICJYLWF3cy1lYzItbWV0YWRhdGEtdG9rZW46ICRUT0tFTiIgXAogICJodHRwOi8vMTY5LjI1NC4xNjkuMjU0L2xhdGVzdC9tZXRhLWRhdGEvbWFjIikKRU5JX0lEPSQoY3VybCAtc2YgLUggIlgtYXdzLWVjMi1tZXRhZGF0YS10b2tlbjogJFRPS0VOIiBcCiAgImh0dHA6Ly8xNjkuMjU0LjE2OS4yNTQvbGF0ZXN0L21ldGEtZGF0YS9uZXR3b3JrL2ludGVyZmFjZXMvbWFjcy8ke01BQ30vaW50ZXJmYWNlLWlkIikKUkVHSU9OPSQoY3VybCAtc2YgLUggIlgtYXdzLWVjMi1tZXRhZGF0YS10b2tlbjogJFRPS0VOIiBcCiAgImh0dHA6Ly8xNjkuMjU0LjE2OS4yNTQvbGF0ZXN0L21ldGEtZGF0YS9wbGFjZW1lbnQvcmVnaW9uIikKYXdzIGVjMiBtb2RpZnktbmV0d29yay1pbnRlcmZhY2UtYXR0cmlidXRlIFwKICAtLW5ldHdvcmstaW50ZXJmYWNlLWlkICIkRU5JX0lEIiBcCiAgLS1uby1zb3VyY2UtZGVzdC1jaGVjayBcCiAgLS1yZWdpb24gIiRSRUdJT04iCmVjaG8gInNyYy9kZXN0IGNoZWNrIGRpc2FibGVkIG9uICRFTklfSUQiCg==",
#             "TagSpecifications": [
#                 {
#                     "ResourceType": "instance",
#                     "Tags": [
#                         {
#                             "Key": "Name",
#                             "Value": "fleetipsec-vpn"
#                         },
#                         {
#                             "Key": "ipsec-vpn-cluster",
#                             "Value": "fleetipsec-vpn"
#                         },
#                         {
#                             "Key": "ipsec-vpn-asg",
#                             "Value": "fleetipsec-vpn"
#                         },
#                         {
#                             "Key": "ipsec-rds-endpoint",
#                             "Value": "fleetshell-ipsec-strongswan.cpgmocimewi5.eu-west-2.rds.amazonaws.com"
#                         },
#                         {
#                             "Key": "ipsec-valkey-endpoint",
#                             "Value": "clustercfg.dev-valkey-aeroftp.ak121m.memorydb.eu-west-2.amazonaws.com:6379"
#                         }
#                     ]
#                 }
#             ],
#             "MetadataOptions": {
#                 "HttpTokens": "required",
#                 "HttpEndpoint": "enabled",
#                 "InstanceMetadataTags": "enabled"
#             }
#         }
#     }
# }
# # Setting as default
# {
#     "LaunchTemplate": {
#         "LaunchTemplateId": "lt-02a4499a34fa61c3b",
#         "LaunchTemplateName": "fleetipsec-lt-vpn",
#         "CreateTime": "1970-01-01T00:00:00+00:00",
#         "CreatedBy": "arn:aws:sts::295934382486:assumed-role/AWSReservedSSO_CLI-Role-PowerUserAndVPC_3a45f6c9035e1a71/michael.rommel@siemens-healthineers.com",
#         "DefaultVersionNumber": 11,
#         "LatestVersionNumber": 11
#     }
# }
# # Verifying
# [
#     {
#         "Ver": 11,
#         "Default": true,
#         "Desc": "fleetnode AMI ami-020c1ddbdd1b8c77d"
#     },
#     {
#         "Ver": 10,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-0f15bdcd057ab75c5"
#     },
#     {
#         "Ver": 9,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-0f15bdcd057ab75c5"
#     },
#     {
#         "Ver": 8,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-02dd075664df52991"
#     },
#     {
#         "Ver": 7,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-0d3c80537d8b691f0"
#     },
#     {
#         "Ver": 6,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-05cb5d404a127a9e7"
#     },
#     {
#         "Ver": 5,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-0fc1555de9422edb4"
#     },
#     {
#         "Ver": 4,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-0e4b56716bd7d28f6"
#     },
#     {
#         "Ver": 3,
#         "Default": false,
#         "Desc": "v3 - remove awscli user data; src/dest check handled by ipsecnode at startup"
#     },
#     {
#         "Ver": 2,
#         "Default": false,
#         "Desc": "v2 - user data disables src/dest check at boot for VPP NAT"
#     },
#     {
#         "Ver": 1,
#         "Default": false,
#         "Desc": "v1 - placeholder AMI; replace after first fleetnode Packer build"
#     }
# ]

#RESULT

# Creating new LT version: fleetipsec-lt-vpn -> ami-0bf6746419874c971
# {
#     "LaunchTemplateVersion": {
#         "LaunchTemplateId": "lt-02a4499a34fa61c3b",
#         "LaunchTemplateName": "fleetipsec-lt-vpn",
#         "VersionNumber": 12,
#         "VersionDescription": "fleetnode AMI ami-0bf6746419874c971",
#         "CreateTime": "2026-08-04T19:31:44+00:00",
#         "CreatedBy": "arn:aws:sts::295934382486:assumed-role/AWSReservedSSO_CLI-Role-PowerUserAndVPC_3a45f6c9035e1a71/michael.rommel@siemens-healthineers.com",
#         "DefaultVersion": false,
#         "LaunchTemplateData": {
#             "IamInstanceProfile": {
#                 "Arn": "arn:aws:iam::295934382486:instance-profile/fleetipsec-vpn-profile"
#             },
#             "NetworkInterfaces": [
#                 {
#                     "AssociatePublicIpAddress": false,
#                     "DeviceIndex": 0,
#                     "Groups": [
#                         "sg-04dcc0342150eb53b"
#                     ]
#                 }
#             ],
#             "ImageId": "ami-0bf6746419874c971",
#             "InstanceType": "c6in.xlarge",
#             "KeyName": "rommel@md151vfc",
#             "InstanceInitiatedShutdownBehavior": "terminate",
#             "UserData": "IyEvYmluL2Jhc2gKIyBEaXNhYmxlIHNyYy9kZXN0IGNoZWNrIG9uIGV0aDAgYXQgZmlyc3QgYm9vdC4KIyBSZXF1aXJlZCBmb3IgVlBQIDE6MSBOQVQgZm9yd2FyZGluZyAtLSBtYXBwZWQgSVBzIGFyZSBub3QgYXNzaWduZWQgdG8gZXRoMC4Kc2V0IC1lClRPS0VOPSQoY3VybCAtc2YgLVggUFVUICJodHRwOi8vMTY5LjI1NC4xNjkuMjU0L2xhdGVzdC9hcGkvdG9rZW4iIFwKICAtSCAiWC1hd3MtZWMyLW1ldGFkYXRhLXRva2VuLXR0bC1zZWNvbmRzOiAyMTYwMCIpCk1BQz0kKGN1cmwgLXNmIC1IICJYLWF3cy1lYzItbWV0YWRhdGEtdG9rZW46ICRUT0tFTiIgXAogICJodHRwOi8vMTY5LjI1NC4xNjkuMjU0L2xhdGVzdC9tZXRhLWRhdGEvbWFjIikKRU5JX0lEPSQoY3VybCAtc2YgLUggIlgtYXdzLWVjMi1tZXRhZGF0YS10b2tlbjogJFRPS0VOIiBcCiAgImh0dHA6Ly8xNjkuMjU0LjE2OS4yNTQvbGF0ZXN0L21ldGEtZGF0YS9uZXR3b3JrL2ludGVyZmFjZXMvbWFjcy8ke01BQ30vaW50ZXJmYWNlLWlkIikKUkVHSU9OPSQoY3VybCAtc2YgLUggIlgtYXdzLWVjMi1tZXRhZGF0YS10b2tlbjogJFRPS0VOIiBcCiAgImh0dHA6Ly8xNjkuMjU0LjE2OS4yNTQvbGF0ZXN0L21ldGEtZGF0YS9wbGFjZW1lbnQvcmVnaW9uIikKYXdzIGVjMiBtb2RpZnktbmV0d29yay1pbnRlcmZhY2UtYXR0cmlidXRlIFwKICAtLW5ldHdvcmstaW50ZXJmYWNlLWlkICIkRU5JX0lEIiBcCiAgLS1uby1zb3VyY2UtZGVzdC1jaGVjayBcCiAgLS1yZWdpb24gIiRSRUdJT04iCmVjaG8gInNyYy9kZXN0IGNoZWNrIGRpc2FibGVkIG9uICRFTklfSUQiCg==",
#             "TagSpecifications": [
#                 {
#                     "ResourceType": "instance",
#                     "Tags": [
#                         {
#                             "Key": "Name",
#                             "Value": "fleetipsec-vpn"
#                         },
#                         {
#                             "Key": "ipsec-vpn-cluster",
#                             "Value": "fleetipsec-vpn"
#                         },
#                         {
#                             "Key": "ipsec-vpn-asg",
#                             "Value": "fleetipsec-vpn"
#                         },
#                         {
#                             "Key": "ipsec-rds-endpoint",
#                             "Value": "fleetshell-ipsec-strongswan.cpgmocimewi5.eu-west-2.rds.amazonaws.com"
#                         },
#                         {
#                             "Key": "ipsec-valkey-endpoint",
#                             "Value": "clustercfg.dev-valkey-aeroftp.ak121m.memorydb.eu-west-2.amazonaws.com:6379"
#                         }
#                     ]
#                 }
#             ],
#             "MetadataOptions": {
#                 "HttpTokens": "required",
#                 "HttpEndpoint": "enabled",
#                 "InstanceMetadataTags": "enabled"
#             }
#         }
#     }
# }
# # Setting as default
# {
#     "LaunchTemplate": {
#         "LaunchTemplateId": "lt-02a4499a34fa61c3b",
#         "LaunchTemplateName": "fleetipsec-lt-vpn",
#         "CreateTime": "1970-01-01T00:00:00+00:00",
#         "CreatedBy": "arn:aws:sts::295934382486:assumed-role/AWSReservedSSO_CLI-Role-PowerUserAndVPC_3a45f6c9035e1a71/michael.rommel@siemens-healthineers.com",
#         "DefaultVersionNumber": 12,
#         "LatestVersionNumber": 12
#     }
# }
# # Verifying
# [
#     {
#         "Ver": 12,
#         "Default": true,
#         "Desc": "fleetnode AMI ami-0bf6746419874c971"
#     },
#     {
#         "Ver": 11,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-020c1ddbdd1b8c77d"
#     },
#     {
#         "Ver": 10,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-0f15bdcd057ab75c5"
#     },
#     {
#         "Ver": 9,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-0f15bdcd057ab75c5"
#     },
#     {
#         "Ver": 8,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-02dd075664df52991"
#     },
#     {
#         "Ver": 7,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-0d3c80537d8b691f0"
#     },
#     {
#         "Ver": 6,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-05cb5d404a127a9e7"
#     },
#     {
#         "Ver": 5,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-0fc1555de9422edb4"
#     },
#     {
#         "Ver": 4,
#         "Default": false,
#         "Desc": "fleetnode AMI ami-0e4b56716bd7d28f6"
#     },
#     {
#         "Ver": 3,
#         "Default": false,
#         "Desc": "v3 - remove awscli user data; src/dest check handled by ipsecnode at startup"
#     },
#     {
#         "Ver": 2,
#         "Default": false,
#         "Desc": "v2 - user data disables src/dest check at boot for VPP NAT"
#     },
#     {
#         "Ver": 1,
#         "Default": false,
#         "Desc": "v1 - placeholder AMI; replace after first fleetnode Packer build"
#     }
# ]
