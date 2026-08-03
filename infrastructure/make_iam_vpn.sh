#!/usr/bin/env bash
set -euo pipefail
#
# make_iam_vpn.sh
#
# Creates the IAM role and instance profile for the fleetipsec VPN concentrator
# nodes.  Only AWS-managed policies are attached -- no inline or customer-managed
# policies, matching the same pattern as ecsInstanceRole.
#
# AWS-managed policies attached (same set as ecsInstanceRole where applicable):
#
#   AmazonEC2FullAccess
#     Full EC2 read/write -- matches ecsInstanceRole.  ipsecnode uses Describe*
#     for instance/ASG discovery; write actions reserved for future use.
#
#   AutoScalingFullAccess
#     autoscaling:CompleteLifecycleAction + RecordLifecycleActionHeartbeat --
#     ipsecnode signals the termination lifecycle hook when tunnel drain is done.
#     Same policy as ecsInstanceRole.
#
#   AmazonSSMManagedInstanceCore
#     SSM agent + ssm:GetParameter* -- allows ipsecnode to use Session Manager
#     for shell access and to fetch secrets from Parameter Store at boot.
#     Same policy as ecsInstanceRole.
#
#   AWSSecretsManagerClientReadOnlyAccess
#     secretsmanager:GetSecretValue -- allows ipsecnode to fetch the RDS
#     credentials from Secrets Manager without embedding them in the AMI.
#     Same policy as ecsInstanceRole.
#
#   CloudWatchAgentServerPolicy
#     cloudwatch:PutMetricData + logs:PutLogEvents -- used by ipsecnode metrics
#     endpoint and the CloudWatch agent.  Not in ecsInstanceRole but needed
#     for VPN node observability.
#
# Resources created:
#   fleetipsec-vpn-role      IAM role (EC2 trust)
#   fleetipsec-vpn-profile   IAM instance profile

# ── Trust policy: allow EC2 to assume this role ───────────────────────────────
cat > /tmp/fleetipsec-vpn-trust.json << 'EOF'
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

echo "# Creating IAM role: fleetipsec-vpn-role"
aws iam create-role \
  --role-name fleetipsec-vpn-role \
  --description "Role for fleetipsec VPN concentrator nodes (ipsecnode)" \
  --assume-role-policy-document file:///tmp/fleetipsec-vpn-trust.json

echo "# Attaching AWS-managed policies"
aws iam attach-role-policy \
  --role-name fleetipsec-vpn-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess

aws iam attach-role-policy \
  --role-name fleetipsec-vpn-role \
  --policy-arn arn:aws:iam::aws:policy/AutoScalingFullAccess

aws iam attach-role-policy \
  --role-name fleetipsec-vpn-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam attach-role-policy \
  --role-name fleetipsec-vpn-role \
  --policy-arn arn:aws:iam::aws:policy/AWSSecretsManagerClientReadOnlyAccess

aws iam attach-role-policy \
  --role-name fleetipsec-vpn-role \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy

echo "# Creating instance profile: fleetipsec-vpn-profile"
aws iam create-instance-profile \
  --instance-profile-name fleetipsec-vpn-profile

echo "# Adding role to instance profile"
aws iam add-role-to-instance-profile \
  --instance-profile-name fleetipsec-vpn-profile \
  --role-name fleetipsec-vpn-role

echo "# Verifying"
aws iam get-instance-profile \
  --instance-profile-name fleetipsec-vpn-profile \
  --query 'InstanceProfile.{Profile:InstanceProfileName,Arn:Arn,Roles:Roles[*].{Role:RoleName,Policies:AttachedManagedPolicies}}'

aws iam list-attached-role-policies \
  --role-name fleetipsec-vpn-role \
  --query 'AttachedPolicies[*].{Name:PolicyName,Arn:PolicyArn}'

rm -f /tmp/fleetipsec-vpn-trust.json

RESULT
