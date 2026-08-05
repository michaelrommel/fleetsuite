#!/usr/bin/env bash
set -euo pipefail
#
# cycle_returngw_instances.sh
#
# Terminates the running Return GW instances so both ASGs replace them
# from the current default Launch Template version.
#
# Run this after update_lt_returngw_ami.sh has set the new AMI as default.
#
# The BGP ENIs (eth2, fixed IPs 172.16.51.4 / 172.16.51.36) are NOT deleted
# when instances terminate (DeleteOnTermination=false).  The new instances
# will claim them via aeroplug eni --takeover at boot.
#
# Usage:
#   bash cycle_returngw_instances.sh               # dry run
#   CONFIRM=yes bash cycle_returngw_instances.sh   # actually terminates

REGION="eu-west-2"
ASGS="fleetipsec-returngw-master fleetipsec-returngw-backup"

for ASG in $ASGS; do
  echo "# Querying running instances in ASG $ASG"
  INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG" \
    --region "$REGION" \
    --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
    --output text)

  if [[ -z "$INSTANCE_IDS" ]]; then
    echo "  No InService instances in $ASG"
    continue
  fi

  echo "  InService: $INSTANCE_IDS"

  if [[ "${CONFIRM:-no}" != "yes" ]]; then
    echo "  (dry run -- would terminate above)"
    continue
  fi

  for ID in $INSTANCE_IDS; do
    echo "  Terminating $ID"
    aws autoscaling terminate-instance-in-auto-scaling-group \
      --instance-id "$ID" \
      --no-should-decrement-desired-capacity \
      --region "$REGION"
  done
done

if [[ "${CONFIRM:-no}" != "yes" ]]; then
  echo ""
  echo "DRY RUN -- set CONFIRM=yes to terminate the above instances."
  exit 0
fi

echo ""
echo "Done.  Watch replacement progress:"
echo "  aws autoscaling describe-auto-scaling-groups \\"
echo "    --auto-scaling-group-names fleetipsec-returngw-master fleetipsec-returngw-backup \\"
echo "    --region eu-west-2 \\"
echo "    --query 'AutoScalingGroups[*].{ASG:AutoScalingGroupName,Instances:Instances[*].{ID:InstanceId,State:LifecycleState}}'"
