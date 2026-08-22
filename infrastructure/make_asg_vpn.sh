#!/usr/bin/env bash
set -euo pipefail
#
# make_asg_vpn.sh
#
# Creates the single ASG for the fleetipsec VPN concentrator nodes.
# Unlike the LVS pair, VPN nodes are stateless and span both AZs in one ASG.
#
# Prerequisites (run first, in order):
#   make_iam_vpn.sh  -- instance profile fleetipsec-vpn-profile
#   make_lt_vpn.sh   -- launch template fleetipsec-lt-vpn
#
# Subnets (both private, routed via rtb-vpn):
#   FleetShell-IPSec-VPN-a  subnet-05a86c0fe6eec7b10  172.16.49.0/24  eu-west-2a
#   FleetShell-IPSec-VPN-b  subnet-0ab2ba73e9b587e2e  172.16.50.0/24  eu-west-2b
#
# Sizing:
#   min=1 max=10 desired=1 for dev.  Adjust max before going to production
#   (25,000 tunnels at ~2,500 per c6in.4xlarge = 10 nodes).
#
# Lifecycle hook:
#   A TERMINATING hook named "fleetipsec-vpn-drain" gives ipsecnode time to:
#     1. Stop accepting new tunnels (remove node from LVS pool via ipsecscale).
#     2. Wait for existing tunnels to re-establish on surviving nodes via DPD.
#     3. Call CompleteLifecycleAction CONTINUE when drain is complete.
#   Default heartbeat timeout: 300 s.  ipsecnode extends it via
#   RecordLifecycleActionHeartbeat while draining.  The absolute maximum is
#   set to 3600 s -- raise if tunnel renegotiation proves slower in practice.
#
# Health check:
#   EC2 only (no target group -- VPN nodes are not behind an ALB/NLB).
#   Grace period 180 s: Ubuntu boot + StrongSwan startup < 90 s in practice;
#   180 s gives ipsecnode time to pass its own health check before the ASG
#   evaluates the instance.

echo "# Creating ASG: fleetipsec-vpn  (AZ-a + AZ-b, min=1 max=10)"
aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name fleetipsec-vpn \
  --launch-template "LaunchTemplateName=fleetipsec-lt-vpn,Version=\$Latest" \
  --min-size 1 \
  --max-size 10 \
  --desired-capacity 1 \
  --vpc-zone-identifier "subnet-05a86c0fe6eec7b10,subnet-0ab2ba73e9b587e2e" \
  --health-check-type EC2 \
  --health-check-grace-period 180 \
  --tags \
    "Key=Name,Value=fleetipsec-vpn,PropagateAtLaunch=true" \
    "Key=ipsec-vpn-cluster,Value=fleetipsec-vpn,PropagateAtLaunch=true"

echo "# Adding termination lifecycle hook: fleetipsec-vpn-drain"
aws autoscaling put-lifecycle-hook \
  --auto-scaling-group-name fleetipsec-vpn \
  --lifecycle-hook-name fleetipsec-vpn-drain \
  --lifecycle-transition autoscaling:EC2_INSTANCE_TERMINATING \
  --default-result ABANDON \
  --heartbeat-timeout 300 \
  --notification-metadata '{"hook":"fleetipsec-vpn-drain"}'

echo "# Verifying ASG"
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names fleetipsec-vpn \
  --region eu-west-2 \
  --query 'AutoScalingGroups[0].{Name:AutoScalingGroupName,Min:MinSize,Max:MaxSize,Desired:DesiredCapacity,Subnets:VPCZoneIdentifier,HealthCheck:HealthCheckType,Tags:Tags[*].{K:Key,V:Value}}'

echo "# Verifying lifecycle hook"
aws autoscaling describe-lifecycle-hooks \
  --auto-scaling-group-name fleetipsec-vpn \
  --region eu-west-2 \
  --query 'LifecycleHooks[*].{Hook:LifecycleHookName,Transition:LifecycleTransition,Timeout:HeartbeatTimeout,DefaultResult:DefaultResult}'

#RESULT

# Creating ASG: fleetipsec-vpn  (AZ-a + AZ-b, min=1 max=10)
# Adding termination lifecycle hook: fleetipsec-vpn-drain
# Verifying ASG
{
    "Name": "fleetipsec-vpn",
    "Min": 1,
    "Max": 10,
    "Desired": 1,
    "Subnets": "subnet-0ab2ba73e9b587e2e,subnet-05a86c0fe6eec7b10",
    "HealthCheck": "EC2",
    "Tags": [
        {
            "K": "Name",
            "V": "fleetipsec-vpn"
        },
        {
            "K": "ipsec-vpn-cluster",
            "V": "fleetipsec-vpn"
        }
    ]
}
# Verifying lifecycle hook
[
    {
        "Hook": "fleetipsec-vpn-drain",
        "Transition": "autoscaling:EC2_INSTANCE_TERMINATING",
        "Timeout": 300,
        "DefaultResult": "ABANDON"
    }
]
