#!/usr/bin/env bash
set -euo pipefail
#
# update_lt_vpn_remove_userdata.sh
#
# Creates Launch Template v3 for fleetipsec-lt-vpn.
# Removes the awscli-based user data added in v2.
#
# Reason: the src/dest check disable belongs in ipsecnode (Increment 6a).
# ipsecnode calls the EC2 API directly via aerocore (the same Rust AWS client
# used everywhere else in this project) -- no awscli needed in the AMI, and
# no shell user data needed in the LT.
#
# Until ipsecnode handles it, new ASG instances need the src/dest check
# disabled manually:
#   ENI_ID=$(aws ec2 describe-instances --instance-ids <ID> \
#     --query 'Reservations[0].Instances[0].NetworkInterfaces[0].NetworkInterfaceId' \
#     --output text --region eu-west-2)
#   aws ec2 modify-network-interface-attribute \
#     --network-interface-id $ENI_ID --no-source-dest-check --region eu-west-2

echo "# Creating LT v3: fleetipsec-lt-vpn -- remove user data"
aws ec2 create-launch-template-version \
  --launch-template-name fleetipsec-lt-vpn \
  --source-version '$Latest' \
  --version-description "v3 - remove awscli user data; src/dest check handled by ipsecnode at startup" \
  --launch-template-data '{"UserData":""}' \
  --region eu-west-2

echo "# Setting v3 as default"
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

# Creating LT v3: fleetipsec-lt-vpn -- remove user data
{
    "LaunchTemplateVersion": {
        "LaunchTemplateId": "lt-02a4499a34fa61c3b",
        "LaunchTemplateName": "fleetipsec-lt-vpn",
        "VersionNumber": 3,
        "VersionDescription": "v3 - remove awscli user data; src/dest check handled by ipsecnode at startup",
        "CreateTime": "2026-08-03T07:34:24+00:00",
        "CreatedBy": "arn:aws:sts::295934382486:assumed-role/AWSReservedSSO_CLI-Role-PowerUserAndVPC_3a45f6c9035e1a71/michael.rommel@siemens-healthineers.com",
        "DefaultVersion": false,
        "LaunchTemplateData": {
            "IamInstanceProfile": {
                "Arn": "arn:aws:iam::295934382486:instance-profile/fleetipsec-vpn-profile"
            },
            "NetworkInterfaces": [
                {
                    "AssociatePublicIpAddress": false,
                    "DeviceIndex": 0,
                    "Groups": [
                        "sg-04dcc0342150eb53b"
                    ]
                }
            ],
            "ImageId": "ami-01029182857b20417",
            "InstanceType": "c6in.xlarge",
            "KeyName": "rommel@md151vfc",
            "InstanceInitiatedShutdownBehavior": "terminate",
            "UserData": "IyEvYmluL2Jhc2gKIyBEaXNhYmxlIHNyYy9kZXN0IGNoZWNrIG9uIGV0aDAgYXQgZmlyc3QgYm9vdC4KIyBSZXF1aXJlZCBmb3IgVlBQIDE6MSBOQVQgZm9yd2FyZGluZyAtLSBtYXBwZWQgSVBzIGFyZSBub3QgYXNzaWduZWQgdG8gZXRoMC4Kc2V0IC1lClRPS0VOPSQoY3VybCAtc2YgLVggUFVUICJodHRwOi8vMTY5LjI1NC4xNjkuMjU0L2xhdGVzdC9hcGkvdG9rZW4iIFwKICAtSCAiWC1hd3MtZWMyLW1ldGFkYXRhLXRva2VuLXR0bC1zZWNvbmRzOiAyMTYwMCIpCk1BQz0kKGN1cmwgLXNmIC1IICJYLWF3cy1lYzItbWV0YWRhdGEtdG9rZW46ICRUT0tFTiIgXAogICJodHRwOi8vMTY5LjI1NC4xNjkuMjU0L2xhdGVzdC9tZXRhLWRhdGEvbWFjIikKRU5JX0lEPSQoY3VybCAtc2YgLUggIlgtYXdzLWVjMi1tZXRhZGF0YS10b2tlbjogJFRPS0VOIiBcCiAgImh0dHA6Ly8xNjkuMjU0LjE2OS4yNTQvbGF0ZXN0L21ldGEtZGF0YS9uZXR3b3JrL2ludGVyZmFjZXMvbWFjcy8ke01BQ30vaW50ZXJmYWNlLWlkIikKUkVHSU9OPSQoY3VybCAtc2YgLUggIlgtYXdzLWVjMi1tZXRhZGF0YS10b2tlbjogJFRPS0VOIiBcCiAgImh0dHA6Ly8xNjkuMjU0LjE2OS4yNTQvbGF0ZXN0L21ldGEtZGF0YS9wbGFjZW1lbnQvcmVnaW9uIikKYXdzIGVjMiBtb2RpZnktbmV0d29yay1pbnRlcmZhY2UtYXR0cmlidXRlIFwKICAtLW5ldHdvcmstaW50ZXJmYWNlLWlkICIkRU5JX0lEIiBcCiAgLS1uby1zb3VyY2UtZGVzdC1jaGVjayBcCiAgLS1yZWdpb24gIiRSRUdJT04iCmVjaG8gInNyYy9kZXN0IGNoZWNrIGRpc2FibGVkIG9uICRFTklfSUQiCg==",
            "TagSpecifications": [
                {
                    "ResourceType": "instance",
                    "Tags": [
                        {
                            "Key": "Name",
                            "Value": "fleetipsec-vpn"
                        },
                        {
                            "Key": "ipsec-vpn-cluster",
                            "Value": "fleetipsec-vpn"
                        },
                        {
                            "Key": "ipsec-vpn-asg",
                            "Value": "fleetipsec-vpn"
                        },
                        {
                            "Key": "ipsec-rds-endpoint",
                            "Value": "fleetshell-ipsec-strongswan.cpgmocimewi5.eu-west-2.rds.amazonaws.com"
                        },
                        {
                            "Key": "ipsec-valkey-endpoint",
                            "Value": "clustercfg.dev-valkey-aeroftp.ak121m.memorydb.eu-west-2.amazonaws.com:6379"
                        }
                    ]
                }
            ],
            "MetadataOptions": {
                "HttpTokens": "required",
                "HttpEndpoint": "enabled",
                "InstanceMetadataTags": "enabled"
            }
        }
    }
}
# Setting v3 as default
{
    "LaunchTemplate": {
        "LaunchTemplateId": "lt-02a4499a34fa61c3b",
        "LaunchTemplateName": "fleetipsec-lt-vpn",
        "CreateTime": "1970-01-01T00:00:00+00:00",
        "CreatedBy": "arn:aws:sts::295934382486:assumed-role/AWSReservedSSO_CLI-Role-PowerUserAndVPC_3a45f6c9035e1a71/michael.rommel@siemens-healthineers.com",
        "DefaultVersionNumber": 3,
        "LatestVersionNumber": 3
    }
}
# Verifying
[
    {
        "Ver": 3,
        "Default": true,
        "Desc": "v3 - remove awscli user data; src/dest check handled by ipsecnode at startup"
    },
    {
        "Ver": 2,
        "Default": false,
        "Desc": "v2 - user data disables src/dest check at boot for VPP NAT"
    },
    {
        "Ver": 1,
        "Default": false,
        "Desc": "v1 - placeholder AMI; replace after first fleetnode Packer build"
    }
]

