#!/usr/bin/env bash
set -euo pipefail
#
# make_lt_lvs.sh
#
# Creates the Launch Template for the fleetipsec LVS nodes.
# One template is shared by both the master and backup ASGs; role-specific
# tags (ipsec-lb-role, ipsec-lb-peer-mgmt-ip) are set per-ASG in make_asg_lvs.sh.
#
# Prerequisites:
#   none — reuses the existing ecsInstanceRole instance profile
#   (arn:aws:iam::295934382486:instance-profile/ecsInstanceRole)
#   A dedicated fleetipsec-lvs-profile with tighter permissions should be
#   created and substituted here before going to production (see make_iam_lvs.sh).
#
# AMI:           ami-0cbada86feaa752f7  (fleetscale-alpine, built by Packer)
# Instance type: c6in.4xlarge
# Security group: sg-lvs (sg-0406887cfe67d8f15) — data-plane NIC (eth0)
#   Management NIC (eth1) SG is set on the pre-created ENI, not here.
#
# MetadataOptions: InstanceMetadataTags=enabled required for ipsecpulse to
#   read instance tags (ipsec-lb-role, ipsec-vip-outside, etc.) from IMDS.
#
# KeyName: set KEYPAIR_NAME env var or edit below before running.
#   The Alpine AMI uses tiny-cloud to inject the key pair's public key into
#   the alpine user's authorized_keys on first boot.

KEYPAIR_NAME="${KEYPAIR_NAME:-rommel@md151vfc}"

cat > /tmp/fleetipsec-lt-lvs.json << EOF
{
  "ImageId": "ami-0cbada86feaa752f7",
  "InstanceType": "c6in.4xlarge",
  "KeyName": "${KEYPAIR_NAME}",
  "NetworkInterfaces": [
    {
      "DeviceIndex": 0,
      "AssociatePublicIpAddress": true,
      "Groups": ["sg-0406887cfe67d8f15"]
    }
  ],
  "IamInstanceProfile": {
    "Arn": "arn:aws:iam::295934382486:instance-profile/ecsInstanceRole"
  },
  "MetadataOptions": {
    "HttpEndpoint": "enabled",
    "HttpTokens": "required",
    "InstanceMetadataTags": "enabled"
  },
  "InstanceInitiatedShutdownBehavior": "terminate",
  "TagSpecifications": [
    {
      "ResourceType": "instance",
      "Tags": [
        {"Key": "Name",              "Value": "fleetipsec-lvs"},
        {"Key": "ipsec-lb-cluster",  "Value": "fleetipsec-lb"},
        {"Key": "ipsec-vip-outside", "Value": "eipalloc-095ac59bb763cd2ce"},
        {"Key": "ipsec-vpn-asg",     "Value": "fleetipsec-vpn"},
        {"Key": "ipsec-rtb-vpn",     "Value": "rtb-01c3275faa537fcc1"}
      ]
    }
  ]
}
EOF

echo "# Creating Launch Template: fleetipsec-lt-lvs"
aws ec2 create-launch-template \
  --launch-template-name fleetipsec-lt-lvs \
  --version-description "v1 - fleetscale AMI ami-0cbada86feaa752f7" \
  --launch-template-data file:///tmp/fleetipsec-lt-lvs.json

rm -f /tmp/fleetipsec-lt-lvs.json

RESULT

# Creating Launch Template: fleetipsec-lt-lvs
{
    "LaunchTemplate": {
        "LaunchTemplateId": "lt-097024e3facf45bd3",
        "LaunchTemplateName": "fleetipsec-lt-lvs",
        "CreateTime": "2026-07-30T08:31:53+00:00",
        "CreatedBy": "arn:aws:sts::295934382486:assumed-role/AWSReservedSSO_CLI-Role-PowerUserAndVPC_3a45f6c9035e1a71/michael.rommel@siemens-healthineers.com",
        "DefaultVersionNumber": 1,
        "LatestVersionNumber": 1
    }
}

