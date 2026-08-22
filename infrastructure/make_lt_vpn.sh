#!/usr/bin/env bash
set -euo pipefail
#
# make_lt_vpn.sh
#
# Creates the Launch Template for the fleetipsec VPN concentrator nodes.
#
# Prerequisites (run first, in order):
#   make_iam_vpn.sh  -- instance profile fleetipsec-vpn-profile
#
# Notes:
#   AMI:           ami-01029182857b20417  -- stock Ubuntu 24.04 LTS (noble,
#                  amd64, 2026-07-14), used as a stand-in until the Packer-built
#                  fleetnode AMI is available.  After the first Packer build,
#                  update to the real fleetnode AMI ID:
#                  To update after each new AMI build:
#                    aws ec2 create-launch-template-version \
#                      --launch-template-name fleetipsec-lt-vpn \
#                      --source-version '$Latest' \
#                      --launch-template-data '{"ImageId":"ami-NEWID"}' \
#                      --region eu-west-2
#                    aws ec2 modify-launch-template \
#                      --launch-template-name fleetipsec-lt-vpn \
#                      --default-version '$Latest' \
#                      --region eu-west-2
#
#   Instance type: c6in.4xlarge (16 vCPU / 32 GiB, 50 Gbps ENA, EBS-optimised)
#                  c6in.xlarge for dev (4 vCPU / 8 GiB, lower cost)
#                  Change INSTANCE_TYPE below before running.
#
#   Subnet:        Not set in the LT -- the ASG assigns subnets (VPN-a / VPN-b).
#
#   Security group: sg-vpn (sg-04dcc0342150eb53b)
#                   Allows: proto50 + UDP 500/4500 from sg-lvs,
#                           TCP 179 (BGP) from sg-returngw,
#                           TCP 22 from CLI_RemoteAccess.
#
#   No public IP:  VPN nodes are in private subnets behind the NAT Gateway.
#                  Outbound internet (for EC2 API, SSM, package updates) goes
#                  via nat-0fb75bf0679751582 (FleetShell-IPSec-NatGW).
#
#   InstanceMetadataTags: enabled -- ipsecnode reads instance tags from IMDS
#                         (e.g. ipsec-rds-endpoint, ipsec-valkey-endpoint,
#                          ipsec-vpn-asg) without a separate ec2:DescribeTags
#                         call on every boot.
#
#   KeyName: set KEYPAIR_NAME env var or edit below.

KEYPAIR_NAME="${KEYPAIR_NAME:-rommel@md151vfc}"
INSTANCE_TYPE="${INSTANCE_TYPE:-c6in.xlarge}"   # use c6in.4xlarge for production

cat > /tmp/fleetipsec-lt-vpn.json << EOF
{
  "ImageId": "ami-01029182857b20417",
  "InstanceType": "${INSTANCE_TYPE}",
  "KeyName": "${KEYPAIR_NAME}",
  "NetworkInterfaces": [
    {
      "DeviceIndex": 0,
      "AssociatePublicIpAddress": false,
      "Groups": ["sg-04dcc0342150eb53b"]
    }
  ],
  "IamInstanceProfile": {
    "Arn": "arn:aws:iam::295934382486:instance-profile/fleetipsec-vpn-profile"
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
        {"Key": "Name",                  "Value": "fleetipsec-vpn"},
        {"Key": "ipsec-vpn-cluster",     "Value": "fleetipsec-vpn"},
        {"Key": "ipsec-vpn-asg",         "Value": "fleetipsec-vpn"},
        {"Key": "ipsec-rds-endpoint",    "Value": "fleetshell-ipsec-strongswan.cpgmocimewi5.eu-west-2.rds.amazonaws.com"},
        {"Key": "ipsec-valkey-endpoint", "Value": "clustercfg.dev-valkey-aeroftp.ak121m.memorydb.eu-west-2.amazonaws.com:6379"}
      ]
    }
  ]
}
EOF

echo "# Creating Launch Template: fleetipsec-lt-vpn"
aws ec2 create-launch-template \
  --launch-template-name fleetipsec-lt-vpn \
  --version-description "v1 - placeholder AMI; replace after first fleetnode Packer build" \
  --launch-template-data file:///tmp/fleetipsec-lt-vpn.json \
  --region eu-west-2

echo "# Verifying"
aws ec2 describe-launch-templates \
  --launch-template-names fleetipsec-lt-vpn \
  --region eu-west-2 \
  --query 'LaunchTemplates[0].{Name:LaunchTemplateName,ID:LaunchTemplateId,DefaultVersion:DefaultVersionNumber,LatestVersion:LatestVersionNumber}'

#rm -f /tmp/fleetipsec-lt-vpn.json

#RESULT

# Creating Launch Template: fleetipsec-lt-vpn
{
    "LaunchTemplate": {
        "LaunchTemplateId": "lt-02a4499a34fa61c3b",
        "LaunchTemplateName": "fleetipsec-lt-vpn",
        "CreateTime": "2026-08-03T06:56:24+00:00",
        "CreatedBy": "arn:aws:sts::295934382486:assumed-role/AWSReservedSSO_CLI-Role-PowerUserAndVPC_3a45f6c9035e1a71/michael.rommel@siemens-healthineers.com",
        "DefaultVersionNumber": 1,
        "LatestVersionNumber": 1
    }
}
# Verifying
{
    "Name": "fleetipsec-lt-vpn",
    "ID": "lt-02a4499a34fa61c3b",
    "DefaultVersion": 1,
    "LatestVersion": 1
}
