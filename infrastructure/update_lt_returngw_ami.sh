#!/usr/bin/env bash
set -euo pipefail
#
# update_lt_returngw_ami.sh
#
# Adds a new version to the fleetipsec-lt-returngw Launch Template pointing
# at a freshly built fleetroute AMI, then sets it as the default.
#
# Run this after:
#   packer build aerobake/fleetroute/fleetroute.pkr.hcl
#
# Then cycle the instances with:
#   bash cycle_returngw_instances.sh
#
# Usage:
#   FLEETROUTE_AMI=ami-XXXXXXXXXXXXXXX bash update_lt_returngw_ami.sh

REGION="eu-west-2"
LT_NAME="fleetipsec-lt-returngw"

if [[ -z "${FLEETROUTE_AMI:-}" ]]; then
  echo "ERROR: set FLEETROUTE_AMI env var to the new AMI ID from the Packer build."
  exit 1
fi

echo "# Creating new LT version: ${LT_NAME} -> ${FLEETROUTE_AMI}"
aws ec2 create-launch-template-version \
  --launch-template-name "${LT_NAME}" \
  --source-version '$Latest' \
  --launch-template-data "{\"ImageId\":\"${FLEETROUTE_AMI}\"}" \
  --version-description "fleetroute AMI ${FLEETROUTE_AMI}" \
  --region "${REGION}"

echo ""
echo "# Setting as default"
aws ec2 modify-launch-template \
  --launch-template-name "${LT_NAME}" \
  --default-version '$Latest' \
  --region "${REGION}"

echo ""
echo "# Verifying"
aws ec2 describe-launch-template-versions \
  --launch-template-name "${LT_NAME}" \
  --region "${REGION}" \
  --query 'reverse(LaunchTemplateVersions[*].{Ver:VersionNumber,Default:DefaultVersion,Desc:VersionDescription})' \
  --output json
