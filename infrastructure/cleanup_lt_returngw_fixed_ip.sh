#!/usr/bin/env bash
set -euo pipefail
#
# cleanup_lt_returngw_fixed_ip.sh
#
# Deletes the two launch templates that were created with fixed primary IPs
# before discovering that AWS ASG does not support fixed private IP addresses
# in launch templates (InvalidQueryParameter: Auto Scaling does not support
# Private IP addresses).
#
# Superseded by the single fleetipsec-lt-returngw (no fixed IP; the fixed
# BGP address is carried by the standalone BGP ENI claimed at boot via
# aeroplug eni --takeover).

echo "# Deleting fleetipsec-lt-returngw-master"
aws ec2 delete-launch-template \
  --launch-template-name fleetipsec-lt-returngw-master \
  --region eu-west-2

echo "# Deleting fleetipsec-lt-returngw-backup"
aws ec2 delete-launch-template \
  --launch-template-name fleetipsec-lt-returngw-backup \
  --region eu-west-2

echo "Done."
