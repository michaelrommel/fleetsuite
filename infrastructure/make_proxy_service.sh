#!/usr/bin/env bash
set -euo pipefail
#
# make_proxy_service.sh
#
# Stand up the FleetShell dual-homed Squid proxy fleet (fleetproxy): an EC2 ASG
# of Alpine instances (AMI baked by aerobake/fleetproxy/fleetproxy.pkr.hcl) that
# terminate device HTTP/HTTPS egress at the tunnel exit (fixed port 8080) and
# authorize destinations via the squid-infoproxy helper against Valkey.
#
# WHY DUAL-HOMED (see aerobake/fleetproxy/README.md)
# --------------------------------------------------
# Device replies must return via the concentrator (backend subnet default route
# -> Return GW), but Squid's OWN outbound requests must NOT follow that default
# into the tunnel -- they must egress via the NAT gateway. Both destinations are
# non-backend IPs, so they cannot be separated by destination; they are
# separated by SOURCE via a second ENI + policy routing:
#   eth0  in a Backend subnet  (rtb-backend default -> concentrator)  Squid :8080
#   eth1  in a proxy-out subnet (rtb default -> NAT gateway)          created +
#         attached at boot by the proxy-net service; Squid tcp_outgoing_address
#         is bound to eth1 and `ip rule from <eth1-ip>` routes it out the NAT.
#
# No NLB: load-balancing/HA is ipsecnode VPP ECMP across the ASG's eth0 IPs.
#
# HOW TO USE: run each STEP, paste output into the RESULT block, fill the
# variables the next STEP needs, commit. Mirrors the other infrastructure/*.sh.
#
# DISCOVERED / REUSED FACTS
# -------------------------
#   account          295934382486     region eu-west-2     vpc vpc-0595e17ce290fb050
#   Backend subnets  subnet-01a513292ea15ae83  Backend-a  172.16.53.0/24  eu-west-2a  (eth0)
#                    subnet-08213d03f2940855c  Backend-b  172.16.54.0/24  eu-west-2b  (eth0)
#                    rtb-backend rtb-0a446e715fc3ec757  0.0.0.0/0 -> Return GW master eth0
#   NAT gateway      nat-0fb75bf0679751582   (rtb-private rtb-0540e3736995912c5 already defaults here)
#   Endpoint SG      sg-0438c989d6fe0f276  FleetShell-IPSec-sg-endpoints (443 from backend CIDRs)
#   Existing backend VPC endpoints: s3(gw), ecr.api, ecr.dkr, ssm, ssmmessages, ec2messages
#     -- NOTE: com.amazonaws.eu-west-2.EC2 (control plane) is MISSING; STEP 0 adds it,
#        required by proxy-net (aws-cli + aeroplug create/attach the egress ENI).
#   Valkey/MemoryDB  SG sg-0709bc00b444b3a9a  (holds the 6379 self rule)
#   ECS was NOT used -- this is an EC2 ASG.

export AWS_PAGER=""
REGION="eu-west-2"
VPC_ID="vpc-0595e17ce290fb050"

SUBNET_BACKEND_A="subnet-01a513292ea15ae83"   # eth0 AZ-a  172.16.53.0/24
SUBNET_BACKEND_B="subnet-08213d03f2940855c"   # eth0 AZ-b  172.16.54.0/24
BACKEND_CIDR_A="172.16.53.0/24"
BACKEND_CIDR_B="172.16.54.0/24"

NAT_GW="nat-0fb75bf0679751582"
ENDPOINTS_SG="sg-0438c989d6fe0f276"            # reuse for the EC2 interface endpoint
VALKEY_SG="sg-0709bc00b444b3a9a"

# New proxy-out (egress) CIDRs -- verify unused before creating:
PROXY_OUT_CIDR_A="172.16.59.0/24"              # eu-west-2a
PROXY_OUT_CIDR_B="172.16.60.0/24"              # eu-west-2b

# Filled in progressively:
SUBNET_OUT_A="subnet-012fbf61edb76044b"       # STEP 1
SUBNET_OUT_B="subnet-010bc8913fb992563"       # STEP 1
RTB_PROXY_OUT="rtb-033b357ed1246ce13"      # STEP 1 -- egress route table
PROXY_IN_SG="sg-0f3b27776bb263093"        # STEP 2 -- eth0 device-facing SG
PROXY_EGRESS_SG="sg-0d0e892da978e299b"    # STEP 2 -- eth1 egress SG (Name tag = fleetshell-proxy-egress)
PROXY_ROLE_ARN=arn:aws:iam::295934382486:role/fleetshell-proxy-role	# STEP 4
PROXY_INSTANCE_PROFILE="fleetshell-proxy-profile"  # STEP 4
AMI_ID="ami-0ca0597fa4d4ca38c"             # baked by packer
LT_ID=lt-0fb19c41a6b427063                 # STEP 6

for v in RTB_PROXY_OUT SUBNET_OUT_A SUBNET_OUT_B PROXY_IN_SG PROXY_EGRESS_SG PROXY_ROLE_ARN AMI_ID LT_ID; do
  printf -v "$v" '%s' "$(echo -n "${!v}" | tr -d '[:space:]')"
done


# ===========================================================================
# STEP 0 -- EC2 control-plane interface endpoint on the Backend subnets
# ===========================================================================
# proxy-net (aws-cli + aeroplug) creates/attaches the egress ENI BEFORE eth1/NAT
# exists, so its EC2 API calls must resolve to a LOCAL endpoint over eth0. The
# backend subnets have ecr/ssm/ec2messages but NOT the plain `ec2` endpoint.
# PrivateDnsEnabled makes ec2.eu-west-2.amazonaws.com resolve to the endpoint.
#
# CAUTION: PrivateDnsEnabled is VPC-WIDE, not per-subnet. After this, EVERY
# instance in the VPC (incl. the LVS nodes in the PUBLIC subnets, which reach
# AWS via the IGW) resolves the EC2 API to this endpoint's private ENI and must
# be able to reach it on 443. The endpoint SG therefore MUST allow 443 from the
# whole VPC (172.16.0.0/16), not just the backend CIDRs -- otherwise every
# non-backend consumer (e.g. LVS ipsecpulse) times out on the EC2 API and
# keepalived fails to start. Run infrastructure/make_endpoint_vpc_access.sh.

# aws ec2 create-vpc-endpoint \
#   --vpc-id "${VPC_ID}" \
#   --vpc-endpoint-type Interface \
#   --service-name com.amazonaws.eu-west-2.ec2 \
#   --subnet-ids "${SUBNET_BACKEND_A}" "${SUBNET_BACKEND_B}" \
#   --security-group-ids "${ENDPOINTS_SG}" \
#   --private-dns-enabled \
#   --tag-specifications 'ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=FleetShell-IPSec-vpce-ec2}]' \
#   --region "${REGION}" --query 'VpcEndpoint.VpcEndpointId' --output text

# ---- RESULT ----------------------------------------------------------------
# vpce-059491282e9c06d3c


# ===========================================================================
# STEP 1 -- proxy-out (egress) subnets + route table -> NAT gateway
# ===========================================================================
# One subnet per AZ, tagged fleetshell-proxy-out=true so proxy-net can find the
# AZ-matching one. Route table default -> NAT (so eth1 egresses to the internet).

# echo "# egress subnet AZ-a"
# aws ec2 create-subnet --vpc-id "${VPC_ID}" --cidr-block "${PROXY_OUT_CIDR_A}" \
#   --availability-zone eu-west-2a \
#   --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=FleetShell-proxy-out-a},{Key=fleetshell-proxy-out,Value=true}]' \
#   --region "${REGION}" --query 'Subnet.SubnetId' --output text
# echo "# egress subnet AZ-b"
# aws ec2 create-subnet --vpc-id "${VPC_ID}" --cidr-block "${PROXY_OUT_CIDR_B}" \
#   --availability-zone eu-west-2b \
#   --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=FleetShell-proxy-out-b},{Key=fleetshell-proxy-out,Value=true}]' \
#   --region "${REGION}" --query 'Subnet.SubnetId' --output text

# ---- RESULT (set SUBNET_OUT_A / SUBNET_OUT_B) ------------------------------
# SUBNET_OUT_A=subnet-010bc8913fb992563
# SUBNET_OUT_B=subnet-010bc8913fb992563

# echo "# egress route table -> NAT"
# aws ec2 create-route-table --vpc-id "${VPC_ID}" \
#   --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=FleetShell-proxy-out-rtb}]' \
#   --region "${REGION}" --query 'RouteTable.RouteTableId' --output text
# ---- RESULT (set RTB_PROXY_OUT) --------------------------------------------
# RTB_PROXY_OUT=rtb-033b357ed1246ce13

#aws ec2 create-route --route-table-id "${RTB_PROXY_OUT}" \
#   --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "${NAT_GW}" --region "${REGION}"
# aws ec2 associate-route-table --route-table-id "${RTB_PROXY_OUT}" --subnet-id "${SUBNET_OUT_A}" --region "${REGION}"
# aws ec2 associate-route-table --route-table-id "${RTB_PROXY_OUT}" --subnet-id "${SUBNET_OUT_B}" --region "${REGION}"

# ---- RESULT ----------------------------------------------------------------
# {
#     "Return": true
# }
# {
#     "AssociationId": "rtbassoc-0bb40f3f6b40a3de6",
#     "AssociationState": {
#         "State": "associated"
#     }
# }
# {
#     "AssociationId": "rtbassoc-04d988751a186ddf8",
#     "AssociationState": {
#         "State": "associated"
#     }
# }


# ===========================================================================
# STEP 2 -- Security groups (eth0 device-facing + eth1 egress)
# ===========================================================================
# eth0 (proxy-in): inbound 8080 from the tunnel. Client IP is the arbitrary
# device global IP (no fixed CIDR), and the ENI is internal (backend subnet,
# not internet-reachable), so 8080 is opened broadly; the squid-infoproxy helper
# is the real gate. Egress all (needs 443 to the EC2/ECR endpoints + 6379 Valkey
# via local routes, plus device replies to the concentrator).

# aws ec2 create-security-group --group-name fleetshell-proxy-in \
#   --description "fleetproxy eth0: Squid :8080 from tunnel; egress to concentrator + endpoints + Valkey" \
#   --vpc-id "${VPC_ID}" \
#   --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=fleetshell-proxy-in}]' \
#   --region "${REGION}" --query 'GroupId' --output text
# ---- RESULT (set PROXY_IN_SG) ----------------------------------------------
# PROXY_IN_SG=sg-0f3b27776bb263093
# aws ec2 authorize-security-group-ingress --group-id "${PROXY_IN_SG}" \
#   --protocol tcp --port 8080 --cidr 0.0.0.0/0 --region "${REGION}"

# RESULT
# {
#     "Return": true,
#     "SecurityGroupRules": [
#         {
#             "SecurityGroupRuleId": "sgr-0e374b3f3b108ba21",
#             "GroupId": "sg-0f3b27776bb263093",
#             "GroupOwnerId": "295934382486",
#             "IsEgress": false,
#             "IpProtocol": "tcp",
#             "FromPort": 8080,
#             "ToPort": 8080,
#             "CidrIpv4": "0.0.0.0/0"
#         }
#     ]
# }


# eth1 (egress): no inbound (NAT is stateful). Egress 80/443 to the internet
# and to the downstream intranet proxy. Name tag MUST be fleetshell-proxy-egress
# (proxy-net discovers the SG by this Name to attach to the created ENI).
# aws ec2 create-security-group --group-name fleetshell-proxy-egress \
#   --description "fleetproxy eth1: outbound 80/443 to internet + intranet peer" \
#   --vpc-id "${VPC_ID}" \
#   --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=fleetshell-proxy-egress}]' \
#   --region "${REGION}" --query 'GroupId' --output text
# ---- RESULT (set PROXY_EGRESS_SG) ------------------------------------------
# PROXY_EGRESS_SG=sg-0d0e892da978e299b
# (default egress = allow all; tighten to 80/443 + the intranet proxy IP if desired)


# ===========================================================================
# STEP 3 -- Allow the proxy (eth0) to reach Valkey/MemoryDB on 6379
# ===========================================================================
# The squid-infoproxy helper connects to MemoryDB from each host. Valkey lives in
# the backend range (a LOCAL route), so the helper's socket is sourced from eth0;
# add the eth0 SG to the MemoryDB SG's 6379 rule.
# aws ec2 authorize-security-group-ingress --group-id "${VALKEY_SG}" \
#   --protocol tcp --port 6379 --source-group "${PROXY_IN_SG}" --region "${REGION}"

# ---- RESULT ----------------------------------------------------------------
# {
#     "Return": true,
#     "SecurityGroupRules": [
#         {
#             "SecurityGroupRuleId": "sgr-0ea8a71111f88ced5",
#             "GroupId": "sg-0709bc00b444b3a9a",
#             "GroupOwnerId": "295934382486",
#             "IsEgress": false,
#             "IpProtocol": "tcp",
#             "FromPort": 6379,
#             "ToPort": 6379,
#             "ReferencedGroupInfo": {
#                 "GroupId": "sg-0f3b27776bb263093",
#                 "UserId": "295934382486"
#             }
#         }
#     ]
# }



# ===========================================================================
# STEP 4 -- IAM role + instance profile (ENI lifecycle + SSM)
# ===========================================================================
# proxy-net needs to create/attach/delete its own egress ENI and describe
# subnets/SGs/instances. The tightly-scoped permission set is captured in
#   make_proxy_service_policy.json  (ec2 Describe* + ENI Create/Attach/Detach/
#                                    Delete + CreateTags)
# but we currently lack the rights to create inline/customer-managed policies,
# so the role is composed from AWS-MANAGED policies instead. This grants MORE
# than strictly needed; re-scope to the JSON above (as a customer-managed policy)
# once inline/managed-policy creation rights are available.
#
#   AmazonEC2FullAccess          -- covers ec2:Describe* + all ENI ops + CreateTags
#                                   (same managed policy fleetipsec-vpn-role uses)
#   AmazonSSMManagedInstanceCore -- Session Manager for debugging
#
# Trust policy is the committed JSON (ec2.amazonaws.com assume-role):
#   make_proxy_service_trust.json

# aws iam create-role --role-name fleetshell-proxy-role \
#   --assume-role-policy-document file://make_proxy_service_trust.json \
#   --region "${REGION}" --query 'Role.Arn' --output text
# ---- RESULT (set PROXY_ROLE_ARN) -------------------------------------------
# PROXY_ROLE_ARN=arn:aws:iam::295934382486:role/fleetshell-proxy-role


# Compose AWS-managed policies (no inline policy -- see note above):
# aws iam attach-role-policy --role-name fleetshell-proxy-role \
#   --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess
# aws iam attach-role-policy --role-name fleetshell-proxy-role \
#   --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
# aws iam create-instance-profile --instance-profile-name "${PROXY_INSTANCE_PROFILE}"
# aws iam add-role-to-instance-profile --instance-profile-name "${PROXY_INSTANCE_PROFILE}" \
#   --role-name fleetshell-proxy-role
#
# LATER (when customer-managed/inline policy rights exist), replace
# AmazonEC2FullAccess with the scoped policy:
#   aws iam create-policy --policy-name fleetproxy-eni \
#     --policy-document file://make_proxy_service_policy.json
#   aws iam attach-role-policy --role-name fleetshell-proxy-role \
#     --policy-arn arn:aws:iam::295934382486:policy/fleetproxy-eni
#   aws iam detach-role-policy --role-name fleetshell-proxy-role \
#     --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess

# ---- RESULT ----------------------------------------------------------------
# {
#     "InstanceProfile": {
#         "Path": "/",
#         "InstanceProfileName": "fleetshell-proxy-profile",
#         "InstanceProfileId": "AIPAUJZYQKGLN6HM67NDN",
#         "Arn": "arn:aws:iam::295934382486:instance-profile/fleetshell-proxy-profile",
#         "CreateDate": "2026-08-21T08:45:06+00:00",
#         "Roles": []
#     }
# }


# ===========================================================================
# STEP 5 -- Launch template (single primary ENI in a Backend subnet)
# ===========================================================================
# ONE ENI at launch (eth0) -- the second ENI is created+attached at boot by
# proxy-net (AWS cannot reliably launch an instance with two ENIs in different
# subnets; the aeroplug/boot-attach workaround is used, same as fleetroute).
# AMI_ID = the packer output (fleetproxy-alpine-*). IMDSv2 required.

# aws ec2 create-launch-template --launch-template-name fleetshell-proxy-lt \
#   --version-description "fleetproxy dual-homed squid" \
#   --launch-template-data "{
#     \"ImageId\": \"${AMI_ID}\",
#     \"InstanceType\": \"t3.small\",
#     \"KeyName\": \"rommel@md151vfc\",
#     \"IamInstanceProfile\": {\"Name\": \"${PROXY_INSTANCE_PROFILE}\"},
#     \"MetadataOptions\": {\"HttpTokens\": \"required\", \"HttpEndpoint\": \"enabled\"},
#     \"NetworkInterfaces\": [{\"DeviceIndex\": 0, \"Groups\": [\"${PROXY_IN_SG}\"], \"DeleteOnTermination\": true}],
#     \"TagSpecifications\": [{\"ResourceType\": \"instance\", \"Tags\": [{\"Key\": \"Name\", \"Value\": \"fleetshell-proxy\"}]}]
#   }" \
#   --region "${REGION}" --query 'LaunchTemplate.LaunchTemplateId' --output text
#
# NOTE: KeyName is REQUIRED for SSH login -- the Alpine AMI injects the pubkey
# from IMDS at boot (tiny-cloud). Login user is `alpine`. Without a KeyName the
# instances boot with NO authorized key and are unreachable (there is no SSM
# agent in the AMI either). If the LT was already created without it, add it as
# a new version and refresh the ASG:
#   aws ec2 create-launch-template-version --launch-template-id "${LT_ID}" \
#     --source-version '$Latest' \
#     --launch-template-data '{"KeyName":"rommel@md151vfc"}' --region "${REGION}"
#   aws ec2 modify-launch-template --launch-template-id "${LT_ID}" \
#     --default-version '$Latest' --region "${REGION}"
#   aws autoscaling start-instance-refresh --auto-scaling-group-name fleetshell-proxy-asg \
#     --preferences '{"MinHealthyPercentage":0}' --region "${REGION}"

# ---- RESULT (set LT_ID) ----------------------------------------------------
# LT_ID=lt-0fb19c41a6b427063



# ===========================================================================
# STEP 6 -- Auto Scaling group across the Backend subnets (eth0)
# ===========================================================================
# VPCZoneIdentifier = Backend-a,Backend-b (eth0 lands here; proxy-net then
# creates eth1 in the AZ-matching proxy-out subnet).
# aws autoscaling create-auto-scaling-group \
#   --auto-scaling-group-name fleetshell-proxy-asg \
#   --launch-template "LaunchTemplateId=${LT_ID},Version=\$Latest" \
#   --min-size 2 --max-size 20 --desired-capacity 2 \
#   --vpc-zone-identifier "${SUBNET_BACKEND_A},${SUBNET_BACKEND_B}" \
#   --health-check-type EC2 --health-check-grace-period 120 \
#   --tags "ResourceId=fleetshell-proxy-asg,ResourceType=auto-scaling-group,Key=Name,Value=fleetshell-proxy,PropagateAtLaunch=true" \
#   --region "${REGION}"

# ---- RESULT ----------------------------------------------------------------
# nothing printed


# ===========================================================================
# STEP 7 -- Scale on network saturation (target tracking)
# ===========================================================================
# Squid is throughput-bound; scale on average per-instance network out. Tune the
# TargetValue (bytes/instance over the metric period) against observed load.
# aws autoscaling put-scaling-policy \
#   --auto-scaling-group-name fleetshell-proxy-asg \
#   --policy-name fleetshell-proxy-net-tt \
#   --policy-type TargetTrackingScaling \
#   --estimated-instance-warmup 120 \
#   --target-tracking-configuration '{
#     "PredefinedMetricSpecification": {"PredefinedMetricType": "ASGAverageNetworkOut"},
#     "TargetValue": 52428800
#   }' \
#   --region "${REGION}"

# ---- RESULT ----------------------------------------------------------------
# {
#     "PolicyARN": "arn:aws:autoscaling:eu-west-2:295934382486:scalingPolicy:190593ad-b659-41cf-a9e1-32348a9d2baf:autoScalingGroupName/fleetshell-proxy-asg:policyName/fleetshell-proxy-net-tt",
#     "Alarms": [
#         {
#             "AlarmName": "TargetTracking-fleetshell-proxy-asg-AlarmHigh-2ea4f03a-e9cf-41c2-b256-3e403b62c248",
#             "AlarmARN": "arn:aws:cloudwatch:eu-west-2:295934382486:alarm:TargetTracking-fleetshell-proxy-asg-AlarmHigh-2ea4f03a-e9cf-41c2-b256-3e403b62c248"
#         },
#         {
#             "AlarmName": "TargetTracking-fleetshell-proxy-asg-AlarmLow-068ce07c-7037-4676-ae18-135c454b6786",
#             "AlarmARN": "arn:aws:cloudwatch:eu-west-2:295934382486:alarm:TargetTracking-fleetshell-proxy-asg-AlarmLow-068ce07c-7037-4676-ae18-135c454b6786"
#         }
#     ]
# }


# ===========================================================================
# STEP 8 -- ENI leak backstop (abrupt termination)
# ===========================================================================
# proxy-net deletes its egress ENI on graceful stop. For SIGKILL/terminate, add
# a terminating lifecycle hook (drain proxy-net) and/or a scheduled sweeper that
# deletes 'available' ENIs tagged Name=fleetproxy-egress whose fleetproxy-instance
# tag references a no-longer-running instance:
#   aws ec2 describe-network-interfaces --region "${REGION}" \
#     --filters Name=tag:Name,Values=fleetproxy-egress Name=status,Values=available \
#     --query 'NetworkInterfaces[].NetworkInterfaceId' --output text
#   # ... for each, verify the fleetproxy-instance tag is not a running instance, then:
#   #     aws ec2 delete-network-interface --network-interface-id <id>
aws autoscaling put-lifecycle-hook \
  --auto-scaling-group-name fleetshell-proxy-asg \
  --lifecycle-hook-name fleetproxy-drain \
  --lifecycle-transition autoscaling:EC2_INSTANCE_TERMINATING \
  --heartbeat-timeout 120 --default-result CONTINUE --region "${REGION}"

# ---- RESULT ----------------------------------------------------------------
# nothing printed


# ===========================================================================
# STEP 9 -- ipsecnode ECMP: split :8080 across the ASG eth0 IPs
# ===========================================================================
# Load-balancing lives in ipsecnode (VPP), not an NLB. Register the ASG's eth0
# private IPs as the ECMP target set for the port-8080 service split (replacing
# the single test backend 172.16.53.6). Enumerate current eth0 IPs:
#   aws ec2 describe-instances --region "${REGION}" \
#     --filters Name=tag:Name,Values=fleetshell-proxy Name=instance-state-name,Values=running \
#     --query 'Reservations[].Instances[].PrivateIpAddress' --output text
# Then update the ipsecnode svcroute (ipsecnode.toml 8080 split) to ECMP across
# them. See AGENTS.md "Global service routing table (ipsecnode_svcroute)".

# ---- RESULT ----------------------------------------------------------------
#
