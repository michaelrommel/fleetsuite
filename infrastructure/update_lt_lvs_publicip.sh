#!/usr/bin/env bash
set -euo pipefail
#
# update_lt_lvs_publicip.sh
#
# Adds AssociatePublicIpAddress=true to the fleetipsec-lt-lvs launch template.
#
# Background: LVS nodes need outbound internet access to call the EC2 API
# (aeroplug attach, ipsecpulse DescribeInstances, ipsecscale).  They are in
# PUBLIC subnets with an IGW route, but the IGW silently drops outbound packets
# from instances with no public IP.
#
# The single customer-facing EIP (eipalloc-095ac59bb763cd2ce) is only
# associated AFTER the VRRP master election — it cannot bootstrap the API
# calls needed to reach that point.  Each instance therefore needs its own
# auto-assigned public IP until the EIP is moved onto the master node.
#
# Note: specifying AssociatePublicIpAddress requires a NetworkInterfaces block
# in the LT data; the top-level SecurityGroupIds must move into that block.
#
# After running this script, terminate the existing LVS instances so the ASG
# relaunches them using $Latest (which now points to version 2).

KEYPAIR_NAME="${KEYPAIR_NAME:-rommel@md151vfc}"

cat > /tmp/fleetipsec-lt-lvs-v2.json << EOF
{
  "ImageId": "ami-0cbada86feaa752f7",
  "InstanceType": "c6in.4xlarge",
  "KeyName": "${KEYPAIR_NAME}",
  "NetworkInterfaces": [
    {
      "DeviceIndex": 0,
      "AssociatePublicIpAddress": true,
      "Groups": ["sg-0406887cfe67d8f15"]
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
        {"Key": "Name",              "Value": "fleetipsec-lvs"},
        {"Key": "ipsec-lb-cluster",  "Value": "fleetipsec-lb"},
        {"Key": "ipsec-vip-outside", "Value": "eipalloc-095ac59bb763cd2ce"},
        {"Key": "ipsec-vpn-asg",     "Value": "fleetipsec-vpn"},
        {"Key": "ipsec-rtb-vpn",     "Value": "rtb-01c3275faa537fcc1"}
      ]
    }
  ]
}
EOF

echo "# Creating LT version 2 with AssociatePublicIpAddress=true"
aws ec2 create-launch-template-version \
  --launch-template-name fleetipsec-lt-lvs \
  --version-description "v2 - add AssociatePublicIpAddress on eth0" \
  --source-version 1 \
  --launch-template-data file:///tmp/fleetipsec-lt-lvs-v2.json

echo "# Setting version 2 as the default"
aws ec2 modify-launch-template \
  --launch-template-name fleetipsec-lt-lvs \
  --default-version 2

echo "# Current LT versions"
aws ec2 describe-launch-template-versions \
  --launch-template-name fleetipsec-lt-lvs \
  --query 'LaunchTemplateVersions[*].{Ver:VersionNumber,Desc:VersionDescription,Default:DefaultVersion}' \
  --output table

echo ""
echo "# Now terminate the running LVS instances so the ASG relaunches them"
echo "# with the new LT version (public IP will be auto-assigned):"
echo ""
echo "  MASTER_ID=\$(aws autoscaling describe-auto-scaling-groups \\"
echo "    --auto-scaling-group-names fleetipsec-lvs-master \\"
echo "    --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)"
echo "  BACKUP_ID=\$(aws autoscaling describe-auto-scaling-groups \\"
echo "    --auto-scaling-group-names fleetipsec-lvs-backup \\"
echo "    --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)"
echo "  aws ec2 terminate-instances --instance-ids \$MASTER_ID \$BACKUP_ID"

rm -f /tmp/fleetipsec-lt-lvs-v2.json

RESULT

# Creating LT version 2 with AssociatePublicIpAddress=true
{
    "LaunchTemplateVersion": {
        "LaunchTemplateId": "lt-097024e3facf45bd3",
        "LaunchTemplateName": "fleetipsec-lt-lvs",
        "VersionNumber": 2,
        "VersionDescription": "v2 - add AssociatePublicIpAddress on eth0",
        "CreateTime": "2026-07-30T10:06:39+00:00",
        "CreatedBy": "arn:aws:sts::295934382486:assumed-role/AWSReservedSSO_CLI-Role-PowerUserAndVPC_3a45f6c9035e1a71/michael.rommel@siemens-healthineers.com",
        "DefaultVersion": false,
        "LaunchTemplateData": {
            "IamInstanceProfile": {
                "Arn": "arn:aws:iam::295934382486:instance-profile/ecsInstanceRole"
            },
            "NetworkInterfaces": [
                {
                    "AssociatePublicIpAddress": true,
                    "DeviceIndex": 0,
                    "Groups": [
                        "sg-0406887cfe67d8f15"
                    ]
                }
            ],
            "ImageId": "ami-0cbada86feaa752f7",
            "InstanceType": "c6in.4xlarge",
            "KeyName": "rommel",
            "InstanceInitiatedShutdownBehavior": "terminate",
            "TagSpecifications": [
                {
                    "ResourceType": "instance",
                    "Tags": [
                        {
                            "Key": "Name",
                            "Value": "fleetipsec-lvs"
                        },
                        {
                            "Key": "ipsec-lb-cluster",
                            "Value": "fleetipsec-lb"
                        },
                        {
                            "Key": "ipsec-vip-outside",
                            "Value": "eipalloc-095ac59bb763cd2ce"
                        },
                        {
                            "Key": "ipsec-vpn-asg",
                            "Value": "fleetipsec-vpn"
                        },
                        {
                            "Key": "ipsec-rtb-vpn",
                            "Value": "rtb-01c3275faa537fcc1"
                        }
                    ]
                }
            ],
            "SecurityGroupIds": [
                "sg-0406887cfe67d8f15"
            ],
            "MetadataOptions": {
                "HttpTokens": "required",
                "HttpEndpoint": "enabled",
                "InstanceMetadataTags": "enabled"
            }
        }
    }
}
# Setting version 2 as the default
{
    "LaunchTemplate": {
        "LaunchTemplateId": "lt-097024e3facf45bd3",
        "LaunchTemplateName": "fleetipsec-lt-lvs",
        "CreateTime": "1970-01-01T00:00:00+00:00",
        "CreatedBy": "arn:aws:sts::295934382486:assumed-role/AWSReservedSSO_CLI-Role-PowerUserAndVPC_3a45f6c9035e1a71/michael.rommel@siemens-healthineers.com",
        "DefaultVersionNumber": 2,
        "LatestVersionNumber": 2
    }
}
