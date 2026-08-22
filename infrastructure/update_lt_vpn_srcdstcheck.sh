#!/usr/bin/env bash
set -euo pipefail
#
# update_lt_vpn_srcdstcheck.sh
#
# Creates Launch Template v2 for fleetipsec-lt-vpn.
# Adds user data that disables src/dest check on eth0 at first boot.
#
# Why src/dest check must be disabled on VPN nodes:
#   VPP performs 1:1 NAT using globally-routable mapped IPs that are never
#   assigned to eth0.  AWS enforces the check at the hypervisor before any
#   packet reaches the kernel, so both inbound return traffic
#   (dst=mapped_global_IP) and outbound forwarded traffic (src=mapped_global_IP)
#   are silently dropped unless the check is disabled.
#
# Why not in the LT NetworkInterfaces block:
#   SourceDestCheck is not a valid NetworkInterfaces parameter in Launch
#   Template data (AWS rejects it).  The only scalable approach for an ASG
#   is user data: each instance calls modify-network-interface-attribute on
#   its own ENI at first boot using IMDSv2 + its instance role.
#
# Dependency:
#   The user data script calls the aws CLI.  The stock Ubuntu 24.04 AMI does
#   not have it installed, so this will silently do nothing on the stand-in
#   AMI.  The Packer-built fleetnode AMI (Increment 2) will install awscli
#   as part of the base package step.  Until then, fix running instances
#   manually with the command printed at the end of this script.

USERDATA=$(base64 -w 0 << 'EOF'
#!/bin/bash
# Disable src/dest check on eth0 at first boot.
# Required for VPP 1:1 NAT forwarding -- mapped IPs are not assigned to eth0.
set -e
TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
MAC=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
  "http://169.254.169.254/latest/meta-data/mac")
ENI_ID=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
  "http://169.254.169.254/latest/meta-data/network/interfaces/macs/${MAC}/interface-id")
REGION=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
  "http://169.254.169.254/latest/meta-data/placement/region")
aws ec2 modify-network-interface-attribute \
  --network-interface-id "$ENI_ID" \
  --no-source-dest-check \
  --region "$REGION"
echo "src/dest check disabled on $ENI_ID"
EOF
)

echo "# Creating LT v2: fleetipsec-lt-vpn with user data to disable src/dest check"
aws ec2 create-launch-template-version \
  --launch-template-name fleetipsec-lt-vpn \
  --source-version '$Latest' \
  --version-description "v2 - user data disables src/dest check at boot for VPP NAT" \
  --launch-template-data "{\"UserData\":\"${USERDATA}\"}" \
  --region eu-west-2

echo "# Setting v2 as default"
aws ec2 modify-launch-template \
  --launch-template-name fleetipsec-lt-vpn \
  --default-version '$Latest' \
  --region eu-west-2

echo "# Verifying LT versions"
aws ec2 describe-launch-template-versions \
  --launch-template-name fleetipsec-lt-vpn \
  --region eu-west-2 \
  --query 'LaunchTemplateVersions[*].{Ver:VersionNumber,Default:DefaultVersion,Desc:VersionDescription}'

echo ""
echo "# Fix the already-running instance manually (stand-in AMI has no awscli):"
echo "aws ec2 modify-network-interface-attribute \\"
echo "  --network-interface-id eni-0a3b04ae06663662f \\"
echo "  --no-source-dest-check \\"
echo "  --region eu-west-2"

#RESULT

# Creating LT v2: fleetipsec-lt-vpn with user data to disable src/dest check
{
    "LaunchTemplateVersion": {
        "LaunchTemplateId": "lt-02a4499a34fa61c3b",
        "LaunchTemplateName": "fleetipsec-lt-vpn",
        "VersionNumber": 2,
        "VersionDescription": "v2 - user data disables src/dest check at boot for VPP NAT",
        "CreateTime": "2026-08-03T07:09:52+00:00",
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
# Setting v2 as default
{
    "LaunchTemplate": {
        "LaunchTemplateId": "lt-02a4499a34fa61c3b",
        "LaunchTemplateName": "fleetipsec-lt-vpn",
        "CreateTime": "1970-01-01T00:00:00+00:00",
        "CreatedBy": "arn:aws:sts::295934382486:assumed-role/AWSReservedSSO_CLI-Role-PowerUserAndVPC_3a45f6c9035e1a71/michael.rommel@siemens-healthineers.com",
        "DefaultVersionNumber": 2,
        "LatestVersionNumber": 2
    }
}
# Verifying LT versions
[
    {
        "Ver": 2,
        "Default": true,
        "Desc": "v2 - user data disables src/dest check at boot for VPP NAT"
    },
    {
        "Ver": 1,
        "Default": false,
        "Desc": "v1 - placeholder AMI; replace after first fleetnode Packer build"
    }
]
