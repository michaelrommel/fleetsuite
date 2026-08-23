#!/usr/bin/env bash
set -euo pipefail
#
# update_lt_vpn_ami.sh
#
# Creates a new Launch Template version pointing to a freshly built
# fleetnode Packer AMI.  Run this after every successful Packer build.
#
# Usage: FLEETNODE_AMI_ID=ami-xxxx bash update_lt_vpn_ami.sh

FLEETNODE_AMI="${FLEETNODE_AMI:?Set FLEETNODE_AMI env var to the new fleetnode AMI ID}"

echo "# Creating new LT version: fleetipsec-lt-vpn -> $FLEETNODE_AMI"
aws ec2 create-launch-template-version \
  --launch-template-name fleetipsec-lt-vpn \
  --source-version '$Latest' \
  --version-description "fleetnode AMI $FLEETNODE_AMI" \
  --launch-template-data "{\"ImageId\":\"${FLEETNODE_AMI}\"}" \
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

