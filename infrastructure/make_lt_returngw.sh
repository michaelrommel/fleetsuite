#!/usr/bin/env bash
set -euo pipefail
#
# make_lt_returngw.sh
#
# Creates a SINGLE Launch Template for both Return GW nodes.
# No fixed primary IP in the LT -- AWS ASG does not support that.
# The fixed BGP address (172.16.51.4 / 172.16.51.36) is a pre-allocated
# standalone ENI (ipsec-gw-bgp=master/backup) that is claimed at boot via:
#   aeroplug eni --tag ipsec-gw-bgp=$ROLE --takeover --device-index 2
#
# Per-node differences (role, peer mgmt IP, rtb) come from ASG PropagateAtLaunch
# tags -- instances read them from IMDS at boot.
#
# Prerequisites (run first, in order):
#   make_enis_returngw.sh    -- management ENIs for eth1
#   make_bgp_enis_returngw.sh -- BGP ENIs for eth2 (fixed IP)
#   make_rtb_backend.sh       -- backend route table
#
# To update the AMI after each new Packer build:
#   aws ec2 create-launch-template-version \
#     --launch-template-name fleetipsec-lt-returngw \
#     --source-version '$Latest' \
#     --launch-template-data '{"ImageId":"ami-NEWID"}' \
#     --region eu-west-2
#   aws ec2 modify-launch-template \
#     --launch-template-name fleetipsec-lt-returngw \
#     --default-version '$Latest' \
#     --region eu-west-2

KEYPAIR_NAME="${KEYPAIR_NAME:-rommel@md151vfc}"
INSTANCE_TYPE="${INSTANCE_TYPE:-c6in.xlarge}"   # use c6in.2xlarge for production
FLEETROUTE_AMI="${FLEETROUTE_AMI:-ami-00000000000000000}"   # set after packer build

cat > /tmp/fleetipsec-lt-returngw.json << EOF
{
  "ImageId": "${FLEETROUTE_AMI}",
  "InstanceType": "${INSTANCE_TYPE}",
  "KeyName": "${KEYPAIR_NAME}",
  "NetworkInterfaces": [
    {
      "DeviceIndex": 0,
      "AssociatePublicIpAddress": false,
      "Groups": ["sg-0516f1d2561c7754d"]
    }
  ],
  "IamInstanceProfile": {
    "Arn": "arn:aws:iam::295934382486:instance-profile/ecsInstanceRole"
  },
  "MetadataOptions": {
    "HttpEndpoint": "enabled",
    "HttpTokens": "required",
    "InstanceMetadataTags": "enabled"
  },
  "InstanceInitiatedShutdownBehavior": "terminate",
  "TagSpecifications": [
    {
      "ResourceType": "instance",
      "Tags": [
        {"Key": "Name",             "Value": "fleetipsec-returngw"},
        {"Key": "ipsec-gw-cluster", "Value": "fleetipsec-returngw"}
      ]
    }
  ]
}
EOF

# Role, peer-mgmt-ip and rtb are propagated by the ASG tags (PropagateAtLaunch=true).
# The subnet is specified at the ASG level (different per node).

aws ec2 create-launch-template \
  --launch-template-name fleetipsec-lt-returngw \
  --version-description "v1 -- initial fleetroute AMI" \
  --launch-template-data "$(cat /tmp/fleetipsec-lt-returngw.json)" \
  --region eu-west-2
