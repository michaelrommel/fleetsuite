#!/usr/bin/env bash
set -euo pipefail
#
# update_lt_proxy_ami.sh
#
# Adds a new version to the fleetshell-proxy-lt Launch Template pointing
# at a freshly built fleetproxy AMI, then sets it as the default.
#
# Run this after:
#   packer build -var-file=../../infrastructure/fleetproxy.pkrvars.hcl \
#     aerobake/fleetproxy/fleetproxy.pkr.hcl
#
# Then cycle the instances with:
#   bash cycle_prosy_instances.sh
#
# Usage:
#   FLEETPROXY_AMI=ami-XXXXXXXXXXXXXXX bash update_lt_lvs_ami.sh

REGION="eu-west-2"
LT_NAME="fleetshell-proxy-lt"

if [[ -z "${FLEETPROXY_AMI:-}" ]]; then
  echo "ERROR: set FLEETPROXY_AMI env var to the new AMI ID from the Packer build."
  exit 1
fi

echo "# Creating new LT version: ${LT_NAME} -> ${FLEETPROXY_AMI}"
aws ec2 create-launch-template-version \
  --launch-template-name "${LT_NAME}" \
  --source-version '$Latest' \
  --launch-template-data "{\"ImageId\":\"${FLEETPROXY_AMI}\"}" \
  --version-description "fleetscale AMI ${FLEETPROXY_AMI}" \
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
