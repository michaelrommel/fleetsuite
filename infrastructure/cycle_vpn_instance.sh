#!/usr/bin/env bash
set -euo pipefail
#
# cycle_vpn_instance.sh
#
# Terminates the running VPN concentrator instance(s) so the ASG replaces
# them from the current default Launch Template version.
#
# Run this after update_lt_vpn_ami.sh has set the new AMI as default.
#
# In dev the ASG runs desired=1, so this terminates one instance and the
# ASG immediately launches a replacement from the updated LT.
#
# In production (desired > 1) the ASG launches a replacement before
# terminating the next, keeping the pool at minimum capacity throughout.
# Use --instance-warmup and --min-healthy-percentage flags on
# start-instance-refresh for a controlled rolling replace instead.
#
# Usage:
#   bash cycle_vpn_instance.sh                  # dry run (shows what would terminate)
#   CONFIRM=yes bash cycle_vpn_instance.sh       # actually terminates

ASG="fleetipsec-vpn"
REGION="eu-west-2"

echo "# Querying running instances in ASG $ASG"
INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG" \
  --region "$REGION" \
  --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
  --output text)

if [[ -z "$INSTANCE_IDS" ]]; then
  echo "No InService instances found in $ASG"
  exit 0
fi

echo "# InService instances: $INSTANCE_IDS"

if [[ "${CONFIRM:-no}" != "yes" ]]; then
  echo ""
  echo "DRY RUN -- set CONFIRM=yes to terminate the above instance(s)."
  echo "The ASG will launch replacements from the current default LT version."
  exit 0
fi

echo "# Terminating instances (ASG will replace from current default LT)..."
for ID in $INSTANCE_IDS; do
  echo "  Terminating $ID"
  aws autoscaling terminate-instance-in-auto-scaling-group \
    --instance-id "$ID" \
    --no-should-decrement-desired-capacity \
    --region "$REGION"
done

echo "# Done.  Watch replacement progress with:"
echo "  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $ASG --region $REGION --query 'AutoScalingGroups[0].Instances[*].{ID:InstanceId,State:LifecycleState,Health:HealthStatus}'"

#RESULT
