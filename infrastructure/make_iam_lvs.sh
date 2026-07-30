#!/usr/bin/env bash
#
# make_iam_lvs.sh  — DEFERRED, not needed for initial deployment
#
# The launch template currently uses the existing ecsInstanceRole instance
# profile (arn:aws:iam::295934382486:instance-profile/ecsInstanceRole) which
# has broad permissions suitable for development.
#
# Run this script when you are ready to create a tightly-scoped dedicated
# role for the fleetipsec LVS nodes and update the launch template to use it.
#
echo "This script is deferred — see header comment."
exit 0

# ── Original script body preserved below ──────────────────────────────────────
# set -euo pipefail
#
# make_iam_lvs.sh
#
# Creates the IAM role and instance profile used by the fleetipsec LVS nodes.
# Must be run before make_lt_lvs.sh (the launch template references the profile).
#
# Resources created:
#   fleetipsec-lvs-policy         IAM policy
#   fleetipsec-lvs-role           IAM role (EC2 trust)
#   fleetipsec-lvs-profile        IAM instance profile

# ── Permission policy ──────────────────────────────────────────────────────────
cat > /tmp/fleetipsec-lvs-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2Read",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DescribeRouteTables",
        "ec2:DescribeAddresses"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EC2ENIManagement",
      "Comment": "Used by aeroplug to attach/detach the management ENI (eth1)",
      "Effect": "Allow",
      "Action": [
        "ec2:AttachNetworkInterface",
        "ec2:DetachNetworkInterface"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EC2EIPManagement",
      "Comment": "Used by ipsecpulse notify-master to move the customer-facing EIP",
      "Effect": "Allow",
      "Action": [
        "ec2:AssociateAddress",
        "ec2:DisassociateAddress"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EC2RouteManagement",
      "Comment": "Used by ipsecpulse notify-master to update the rtb-vpn default route",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateRoute",
        "ec2:ReplaceRoute",
        "ec2:DeleteRoute"
      ],
      "Resource": "arn:aws:ec2:eu-west-2:295934382486:route-table/rtb-01c3275faa537fcc1"
    },
    {
      "Sid": "AutoScalingAccess",
      "Comment": "Used by ipsecscale to manage the VPN concentrator ASG",
      "Effect": "Allow",
      "Action": [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:SetDesiredCapacity",
        "autoscaling:TerminateInstanceInAutoScalingGroup",
        "autoscaling:CompleteLifecycleAction",
        "autoscaling:RecordLifecycleActionHeartbeat"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudWatchMetrics",
      "Comment": "Used by ipsecscale and ipsecnode to push metrics",
      "Effect": "Allow",
      "Action": [
        "cloudwatch:PutMetricData"
      ],
      "Resource": "*"
    }
  ]
}
EOF

echo "# Creating IAM policy: fleetipsec-lvs-policy"
aws iam create-policy \
  --policy-name fleetipsec-lvs-policy \
  --description "Permissions for fleetipsec IPSec LVS nodes (ipsecpulse, aeroplug, ipsecscale)" \
  --policy-document file:///tmp/fleetipsec-lvs-policy.json

# ── Trust policy (allows EC2 to assume this role) ──────────────────────────────
cat > /tmp/fleetipsec-lvs-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

echo "# Creating IAM role: fleetipsec-lvs-role"
aws iam create-role \
  --role-name fleetipsec-lvs-role \
  --description "Role for fleetipsec IPSec LVS nodes" \
  --assume-role-policy-document file:///tmp/fleetipsec-lvs-trust.json

echo "# Attaching policy to role"
aws iam attach-role-policy \
  --role-name fleetipsec-lvs-role \
  --policy-arn arn:aws:iam::295934382486:policy/fleetipsec-lvs-policy

echo "# Creating IAM instance profile: fleetipsec-lvs-profile"
aws iam create-instance-profile \
  --instance-profile-name fleetipsec-lvs-profile

echo "# Adding role to instance profile"
aws iam add-role-to-instance-profile \
  --instance-profile-name fleetipsec-lvs-profile \
  --role-name fleetipsec-lvs-role

echo "# Verifying profile"
aws iam get-instance-profile \
  --instance-profile-name fleetipsec-lvs-profile

rm -f /tmp/fleetipsec-lvs-policy.json /tmp/fleetipsec-lvs-trust.json

RESULT
