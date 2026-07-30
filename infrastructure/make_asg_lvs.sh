#!/usr/bin/env bash
set -euo pipefail
#
# make_asg_lvs.sh
#
# Creates the two LVS Autoscaling Groups — one per HA node (master / backup).
# Each ASG is single-AZ (single-subnet) so replacement instances always land
# in the same AZ and can attach the correct pre-created management ENI.
#
# Prerequisites (must be run first, in order):
#   make_iam_lvs.sh   — instance profile fleetipsec-lvs-profile
#   make_enis_lvs.sh  — management ENIs with ipsec-lb-mgmt tags
#   make_lt_lvs.sh    — launch template fleetipsec-lt-lvs
#
# ASGs created:
#
#   fleetipsec-lvs-master  min=1 max=2  subnet LVS-a (AZ-a)
#     ipsec-lb-role         = master
#     ipsec-lb-peer-mgmt-ip = 172.16.48.84  (backup's eth1 fixed IP)
#
#   fleetipsec-lvs-backup   min=1 max=2  subnet LVS-b (AZ-b)
#     ipsec-lb-role         = backup
#     ipsec-lb-peer-mgmt-ip = 172.16.48.68  (master's eth1 fixed IP)
#
# Health check: EC2 only (no target group), grace period 300 s to allow
# ipsecpulse + keepalived to complete startup before health is evaluated.

# ── Master ASG (AZ-a, subnet LVS-a) ──────────────────────────────────────────
echo "# Creating ASG: fleetipsec-lvs-master  (AZ-a, min=1 max=2)"
aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name fleetipsec-lvs-master \
  --launch-template "LaunchTemplateName=fleetipsec-lt-lvs,Version=\$Latest" \
  --min-size 1 \
  --max-size 2 \
  --desired-capacity 1 \
  --vpc-zone-identifier "subnet-0fe6d05bc51c16ed8" \
  --health-check-type EC2 \
  --health-check-grace-period 300 \
  --tags \
    "Key=Name,Value=fleetipsec-lvs-master,PropagateAtLaunch=true" \
    "Key=ipsec-lb-role,Value=master,PropagateAtLaunch=true" \
    "Key=ipsec-lb-peer-mgmt-ip,Value=172.16.48.84,PropagateAtLaunch=true"

echo "# Verifying: fleetipsec-lvs-master"
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names fleetipsec-lvs-master \
  --query 'AutoScalingGroups[0].{Name:AutoScalingGroupName,Min:MinSize,Max:MaxSize,Desired:DesiredCapacity,Subnet:VPCZoneIdentifier,Tags:Tags[*].{K:Key,V:Value}}'

echo ""

# ── Backup ASG (AZ-b, subnet LVS-b) ──────────────────────────────────────────
echo "# Creating ASG: fleetipsec-lvs-backup  (AZ-b, min=1 max=2)"
aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name fleetipsec-lvs-backup \
  --launch-template "LaunchTemplateName=fleetipsec-lt-lvs,Version=\$Latest" \
  --min-size 1 \
  --max-size 2 \
  --desired-capacity 1 \
  --vpc-zone-identifier "subnet-071e009038ce73f87" \
  --health-check-type EC2 \
  --health-check-grace-period 300 \
  --tags \
    "Key=Name,Value=fleetipsec-lvs-backup,PropagateAtLaunch=true" \
    "Key=ipsec-lb-role,Value=backup,PropagateAtLaunch=true" \
    "Key=ipsec-lb-peer-mgmt-ip,Value=172.16.48.68,PropagateAtLaunch=true"

echo "# Verifying: fleetipsec-lvs-backup"
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names fleetipsec-lvs-backup \
  --query 'AutoScalingGroups[0].{Name:AutoScalingGroupName,Min:MinSize,Max:MaxSize,Desired:DesiredCapacity,Subnet:VPCZoneIdentifier,Tags:Tags[*].{K:Key,V:Value}}'

RESULT

# Creating ASG: fleetipsec-lvs-master  (AZ-a, min=1 max=2)
# Verifying: fleetipsec-lvs-master
{
    "Name": "fleetipsec-lvs-master",
    "Min": 1,
    "Max": 2,
    "Desired": 1,
    "Subnet": "subnet-0fe6d05bc51c16ed8",
    "Tags": [
        {
            "K": "Name",
            "V": "fleetipsec-lvs-master"
        },
        {
            "K": "ipsec-lb-peer-mgmt-ip",
            "V": "172.16.48.84"
        },
        {
            "K": "ipsec-lb-role",
            "V": "master"
        }
    ]
}

# Creating ASG: fleetipsec-lvs-backup  (AZ-b, min=1 max=2)
# Verifying: fleetipsec-lvs-backup
{
    "Name": "fleetipsec-lvs-backup",
    "Min": 1,
    "Max": 2,
    "Desired": 1,
    "Subnet": "subnet-071e009038ce73f87",
    "Tags": [
        {
            "K": "Name",
            "V": "fleetipsec-lvs-backup"
        },
        {
            "K": "ipsec-lb-peer-mgmt-ip",
            "V": "172.16.48.68"
        },
        {
            "K": "ipsec-lb-role",
            "V": "backup"
        }
    ]
}

