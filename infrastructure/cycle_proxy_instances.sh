#!/usr/bin/env bash
set -euo pipefail
#
# cycle_proxy_instances.sh
#
# Terminates the running proxy instances so the ASG replaces them from the
# current default Launch Template version.
#
# Run this after update_lt_proxu_ami.sh has set the new AMI as default.
#
# Usage:
#   bash cycle_proxy_instances.sh                  # dry run (shows what would terminate)
#   CONFIRM=yes bash cycle_proxy_instances.sh      # actually terminates, backup then master

REGION="eu-west-2"
# Backup FIRST, master LAST, so the VIP is only ever on one healthy node.
ASGS="fleetshell-proxy-asg"
WAIT_TIMEOUT=300   # seconds to wait for a replacement to become InService+Healthy

# Print the InService instance IDs of an ASG.
inservice_ids() {
  aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$1" \
    --region "$REGION" \
    --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
    --output text
}

# Wait until the ASG has at least one InService + Healthy instance whose ID is
# NOT in the given "old" list (i.e. a replacement has come up healthy).
wait_for_replacement() {
  local asg="$1" old_ids="$2" deadline=$(( SECONDS + WAIT_TIMEOUT ))
  echo "  Waiting for $asg replacement to become InService + Healthy (timeout ${WAIT_TIMEOUT}s)..."
  while (( SECONDS < deadline )); do
    local healthy
    healthy=$(aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "$asg" \
      --region "$REGION" \
      --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService` && HealthStatus==`Healthy`].InstanceId' \
      --output text)
    for id in $healthy; do
      if [[ " $old_ids " != *" $id "* ]]; then
        echo "  Replacement $id is InService + Healthy."
        return 0
      fi
    done
    sleep 10
  done
  echo "  WARNING: timed out waiting for $asg replacement; check the console before continuing."
  return 1
}

for ASG in $ASGS; do
  echo "# Querying running instances in ASG $ASG"
  INSTANCE_IDS=$(inservice_ids "$ASG")

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

  # Block until this ASG's replacement is healthy before moving to the master.
  wait_for_replacement "$ASG" "$INSTANCE_IDS" || true
done

if [[ "${CONFIRM:-no}" != "yes" ]]; then
  echo ""
  echo "DRY RUN -- set CONFIRM=yes to terminate the above instances (backup then master)."
  exit 0
fi

echo ""
echo "Done.  Watch replacement progress and VIP ownership:"
echo "  aws autoscaling describe-auto-scaling-groups \\"
echo "    --auto-scaling-group-names fleetshell-proxy-asg \\"
echo "    --region eu-west-2 \\"
echo "    --query 'AutoScalingGroups[*].{ASG:AutoScalingGroupName,Instances:Instances[*].{ID:InstanceId,State:LifecycleState,Health:HealthStatus}}'"
