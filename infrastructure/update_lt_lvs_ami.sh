#!/usr/bin/env bash
set -euo pipefail
#
# update_lt_lvs_ami.sh
#
# Adds a new version to the fleetipsec-lt-lvs Launch Template pointing
# at a freshly built fleetscale (IPSec LVS load balancer) AMI, then sets
# it as the default.
#
# Run this after:
#   packer build aerobake/fleetscale/fleetscale.pkr.hcl
#
# Then cycle the instances with:
#   bash cycle_lvs_instances.sh
#
# Both LVS ASGs (fleetipsec-lvs-master and fleetipsec-lvs-backup) share this
# single Launch Template, so one update covers both nodes.
#
# Usage:
#   FLEETSCALE_AMI=ami-XXXXXXXXXXXXXXX bash update_lt_lvs_ami.sh

REGION="eu-west-2"
LT_NAME="fleetipsec-lt-lvs"

if [[ -z "${FLEETSCALE_AMI:-}" ]]; then
  echo "ERROR: set FLEETSCALE_AMI env var to the new AMI ID from the Packer build."
  exit 1
fi

echo "# Creating new LT version: ${LT_NAME} -> ${FLEETSCALE_AMI}"
aws ec2 create-launch-template-version \
  --launch-template-name "${LT_NAME}" \
  --source-version '$Latest' \
  --launch-template-data "{\"ImageId\":\"${FLEETSCALE_AMI}\"}" \
  --version-description "fleetscale AMI ${FLEETSCALE_AMI}" \
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
