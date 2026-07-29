#!/usr/bin/env bash
set -euo pipefail

# These must be run AFTER step 4, substituting the new SG IDs.
# Shown as: aws ec2 authorize-security-group-ingress --group-id <NEW-SG-ID> ...

# === FleetShell-IPSec-sg-lvs ===
# Proto 50 (ESP) from internet
aws ec2 authorize-security-group-ingress --group-id sg-0406887cfe67d8f15 \
  --ip-permissions '[{"IpProtocol":"50","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]'
# UDP 500 (IKE) from internet
aws ec2 authorize-security-group-ingress --group-id sg-0406887cfe67d8f15 \
  --ip-permissions '[{"IpProtocol":"udp","FromPort":500,"ToPort":500,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]'
# UDP 4500 (NAT-T) from internet
aws ec2 authorize-security-group-ingress --group-id sg-0406887cfe67d8f15 \
  --ip-permissions '[{"IpProtocol":"udp","FromPort":4500,"ToPort":4500,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]'
# VRRP (proto 112) between LVS pair
aws ec2 authorize-security-group-ingress --group-id sg-0406887cfe67d8f15 \
  --ip-permissions '[{"IpProtocol":"112","UserIdGroupPairs":[{"GroupId":"sg-0406887cfe67d8f15"}]}]'
# SSH from office (CLI_RemoteAccess)
aws ec2 authorize-security-group-ingress --group-id sg-0406887cfe67d8f15 \
  --ip-permissions '[{"IpProtocol":"tcp","FromPort":22,"ToPort":22,"UserIdGroupPairs":[{"GroupId":"sg-011b3ebfcfbcca22d"}]}]'

# === FleetShell-IPSec-sg-vpn ===
# Proto 50 + UDP 500/4500 from LVS only
aws ec2 authorize-security-group-ingress --group-id sg-04dcc0342150eb53b \
  --ip-permissions '[{"IpProtocol":"50","UserIdGroupPairs":[{"GroupId":"sg-0406887cfe67d8f15"}]}]'
aws ec2 authorize-security-group-ingress --group-id sg-04dcc0342150eb53b \
  --ip-permissions '[{"IpProtocol":"udp","FromPort":500,"ToPort":500,"UserIdGroupPairs":[{"GroupId":"sg-0406887cfe67d8f15"}]}]'
aws ec2 authorize-security-group-ingress --group-id sg-04dcc0342150eb53b \
  --ip-permissions '[{"IpProtocol":"udp","FromPort":4500,"ToPort":4500,"UserIdGroupPairs":[{"GroupId":"sg-0406887cfe67d8f15"}]}]'
# BGP from Return GW
aws ec2 authorize-security-group-ingress --group-id sg-04dcc0342150eb53b \
  --ip-permissions '[{"IpProtocol":"tcp","FromPort":179,"ToPort":179,"UserIdGroupPairs":[{"GroupId":"sg-0516f1d2561c7754d"}]}]'
# SSH from office
aws ec2 authorize-security-group-ingress --group-id sg-04dcc0342150eb53b \
  --ip-permissions '[{"IpProtocol":"tcp","FromPort":22,"ToPort":22,"UserIdGroupPairs":[{"GroupId":"sg-011b3ebfcfbcca22d"}]}]'

# === FleetShell-IPSec-sg-returngw ===
# BGP from VPN concentrators
aws ec2 authorize-security-group-ingress --group-id sg-0516f1d2561c7754d \
  --ip-permissions '[{"IpProtocol":"tcp","FromPort":179,"ToPort":179,"UserIdGroupPairs":[{"GroupId":"sg-04dcc0342150eb53b"}]}]'
# All from backend subnet (return traffic)
aws ec2 authorize-security-group-ingress --group-id sg-0516f1d2561c7754d \
  --ip-permissions '[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"172.16.0.0/16"}]}]'
# SSH from office
aws ec2 authorize-security-group-ingress --group-id sg-0516f1d2561c7754d \
  --ip-permissions '[{"IpProtocol":"tcp","FromPort":22,"ToPort":22,"UserIdGroupPairs":[{"GroupId":"sg-011b3ebfcfbcca22d"}]}]'

# === FleetShell-IPSec-sg-management ===
# PostgreSQL from VPN concentrators (StrongSwan SQL)
aws ec2 authorize-security-group-ingress --group-id sg-053524ea7dcdb64f1 \
  --ip-permissions '[{"IpProtocol":"tcp","FromPort":5432,"ToPort":5432,"UserIdGroupPairs":[{"GroupId":"sg-04dcc0342150eb53b"}]}]'
# SSH from office
aws ec2 authorize-security-group-ingress --group-id sg-053524ea7dcdb64f1 \
  --ip-permissions '[{"IpProtocol":"tcp","FromPort":22,"ToPort":22,"UserIdGroupPairs":[{"GroupId":"sg-011b3ebfcfbcca22d"}]}]'

# === Grant VPN concentrators access to existing MemoryDB ===
# Add sg-vpn to the MemoryDB cluster — allows TCP 6379 from VPN nodes
aws memorydb update-cluster \
  --cluster-name dev-valkey-aeroftp \
  --security-group-ids sg-06d737ea5595c275d sg-0709bc00b444b3a9a sg-04e471905c7422a96 sg-065f9193da9f46436 sg-04dcc0342150eb53b

RESULT

{
    "Return": true,
    "SecurityGroupRules": [
        {
            "SecurityGroupRuleId": "sgr-0650255c078cc9a13",
            "GroupId": "sg-0406887cfe67d8f15",
            "GroupOwnerId": "295934382486",
            "IsEgress": false,
            "IpProtocol": "50",
            "FromPort": -1,
            "ToPort": -1,
            "CidrIpv4": "0.0.0.0/0"
        }
    ]
}
{
    "Return": true,
    "SecurityGroupRules": [
        {
            "SecurityGroupRuleId": "sgr-097aa84f2325e769f",
            "GroupId": "sg-0406887cfe67d8f15",
            "GroupOwnerId": "295934382486",
            "IsEgress": false,
            "IpProtocol": "udp",
            "FromPort": 500,
            "ToPort": 500,
            "CidrIpv4": "0.0.0.0/0"
        }
    ]
}
{
    "Return": true,
    "SecurityGroupRules": [
        {
            "SecurityGroupRuleId": "sgr-0039c815b6dfc4eab",
            "GroupId": "sg-0406887cfe67d8f15",
            "GroupOwnerId": "295934382486",
            "IsEgress": false,
            "IpProtocol": "udp",
            "FromPort": 4500,
            "ToPort": 4500,
            "CidrIpv4": "0.0.0.0/0"
        }
    ]
}
{
    "Return": true,
    "SecurityGroupRules": [
        {
            "SecurityGroupRuleId": "sgr-0cf22eb4d6486c004",
            "GroupId": "sg-0406887cfe67d8f15",
            "GroupOwnerId": "295934382486",
            "IsEgress": false,
            "IpProtocol": "112",
            "FromPort": -1,
            "ToPort": -1,
            "ReferencedGroupInfo": {
                "GroupId": "sg-0406887cfe67d8f15",
                "UserId": "295934382486"
            }
        }
    ]
}
{
    "Return": true,
    "SecurityGroupRules": [
        {
            "SecurityGroupRuleId": "sgr-09bb282e7460d0c05",
            "GroupId": "sg-0406887cfe67d8f15",
            "GroupOwnerId": "295934382486",
            "IsEgress": false,
            "IpProtocol": "tcp",
            "FromPort": 22,
            "ToPort": 22,
            "ReferencedGroupInfo": {
                "GroupId": "sg-011b3ebfcfbcca22d",
                "UserId": "295934382486"
            }
        }
    ]
}
{
    "Return": true,
    "SecurityGroupRules": [
        {
            "SecurityGroupRuleId": "sgr-05b743f2c4ca289e8",
            "GroupId": "sg-04dcc0342150eb53b",
            "GroupOwnerId": "295934382486",
            "IsEgress": false,
            "IpProtocol": "50",
            "FromPort": -1,
            "ToPort": -1,
            "ReferencedGroupInfo": {
                "GroupId": "sg-0406887cfe67d8f15",
                "UserId": "295934382486"
            }
        }
    ]
}
{
    "Return": true,
    "SecurityGroupRules": [
        {
            "SecurityGroupRuleId": "sgr-0e861256b8cd5b33f",
            "GroupId": "sg-04dcc0342150eb53b",
            "GroupOwnerId": "295934382486",
            "IsEgress": false,
            "IpProtocol": "udp",
            "FromPort": 500,
            "ToPort": 500,
            "ReferencedGroupInfo": {
                "GroupId": "sg-0406887cfe67d8f15",
                "UserId": "295934382486"
            }
        }
    ]
}
{
    "Return": true,
    "SecurityGroupRules": [
        {
            "SecurityGroupRuleId": "sgr-0845cca88f58c9068",
            "GroupId": "sg-04dcc0342150eb53b",
            "GroupOwnerId": "295934382486",
            "IsEgress": false,
            "IpProtocol": "udp",
            "FromPort": 4500,
            "ToPort": 4500,
            "ReferencedGroupInfo": {
                "GroupId": "sg-0406887cfe67d8f15",
                "UserId": "295934382486"
            }
        }
    ]
}
{
    "Return": true,
    "SecurityGroupRules": [
        {
            "SecurityGroupRuleId": "sgr-0b475de5e099c39bd",
            "GroupId": "sg-04dcc0342150eb53b",
            "GroupOwnerId": "295934382486",
            "IsEgress": false,
            "IpProtocol": "tcp",
            "FromPort": 179,
            "ToPort": 179,
            "ReferencedGroupInfo": {
                "GroupId": "sg-0516f1d2561c7754d",
                "UserId": "295934382486"
            }
        }
    ]
}
{
    "Return": true,
    "SecurityGroupRules": [
        {
            "SecurityGroupRuleId": "sgr-060d9060fbfd90d78",
            "GroupId": "sg-04dcc0342150eb53b",
            "GroupOwnerId": "295934382486",
            "IsEgress": false,
            "IpProtocol": "tcp",
            "FromPort": 22,
            "ToPort": 22,
            "ReferencedGroupInfo": {
                "GroupId": "sg-011b3ebfcfbcca22d",
                "UserId": "295934382486"
            }
        }
    ]
}
{
    "Return": true,
    "SecurityGroupRules": [
        {
            "SecurityGroupRuleId": "sgr-00f4c930e520aa69d",
            "GroupId": "sg-0516f1d2561c7754d",
            "GroupOwnerId": "295934382486",
            "IsEgress": false,
            "IpProtocol": "tcp",
            "FromPort": 179,
            "ToPort": 179,
            "ReferencedGroupInfo": {
                "GroupId": "sg-04dcc0342150eb53b",
                "UserId": "295934382486"
            }
        }
    ]
}
{
    "Return": true,
    "SecurityGroupRules": [
        {
            "SecurityGroupRuleId": "sgr-085b12b616bfe5d3d",
            "GroupId": "sg-0516f1d2561c7754d",
            "GroupOwnerId": "295934382486",
            "IsEgress": false,
            "IpProtocol": "-1",
            "FromPort": -1,
            "ToPort": -1,
            "CidrIpv4": "172.16.0.0/16"
        }
    ]
}
{
    "Return": true,
    "SecurityGroupRules": [
        {
            "SecurityGroupRuleId": "sgr-0938cd4d743a847eb",
            "GroupId": "sg-0516f1d2561c7754d",
            "GroupOwnerId": "295934382486",
            "IsEgress": false,
            "IpProtocol": "tcp",
            "FromPort": 22,
            "ToPort": 22,
            "ReferencedGroupInfo": {
                "GroupId": "sg-011b3ebfcfbcca22d",
                "UserId": "295934382486"
            }
        }
    ]
}
{
    "Return": true,
    "SecurityGroupRules": [
        {
            "SecurityGroupRuleId": "sgr-0cc179b80ed1a9189",
            "GroupId": "sg-053524ea7dcdb64f1",
            "GroupOwnerId": "295934382486",
            "IsEgress": false,
            "IpProtocol": "tcp",
            "FromPort": 5432,
            "ToPort": 5432,
            "ReferencedGroupInfo": {
                "GroupId": "sg-04dcc0342150eb53b",
                "UserId": "295934382486"
            }
        }
    ]
}
{
    "Return": true,
    "SecurityGroupRules": [
        {
            "SecurityGroupRuleId": "sgr-0058777839d95d45c",
            "GroupId": "sg-053524ea7dcdb64f1",
            "GroupOwnerId": "295934382486",
            "IsEgress": false,
            "IpProtocol": "tcp",
            "FromPort": 22,
            "ToPort": 22,
            "ReferencedGroupInfo": {
                "GroupId": "sg-011b3ebfcfbcca22d",
                "UserId": "295934382486"
            }
        }
    ]
}
{
    "Cluster": {
        "Name": "dev-valkey-aeroftp",
        "Description": "Cluster created for Nucleus aeroftp demo",
        "Status": "available",
        "NumberOfShards": 1,
        "AvailabilityMode": "SingleAZ",
        "ClusterEndpoint": {
            "Address": "clustercfg.dev-valkey-aeroftp.ak121m.memorydb.eu-west-2.amazonaws.com",
            "Port": 6379
        },
        "NodeType": "db.t4g.small",
        "EngineVersion": "7.3",
        "EnginePatchVersion": "7.3.0",
        "ParameterGroupName": "default.memorydb-valkey7",
        "ParameterGroupStatus": "in-sync",
        "SecurityGroups": [
            {
                "SecurityGroupId": "sg-06d737ea5595c275d",
                "Status": "active"
            },
            {
                "SecurityGroupId": "sg-04dcc0342150eb53b",
                "Status": "adding"
            },
            {
                "SecurityGroupId": "sg-0709bc00b444b3a9a",
                "Status": "active"
            },
            {
                "SecurityGroupId": "sg-04e471905c7422a96",
                "Status": "active"
            },
            {
                "SecurityGroupId": "sg-065f9193da9f46436",
                "Status": "active"
            }
        ],
        "SubnetGroupName": "nucleus-private-subnets",
        "TLSEnabled": true,
        "ARN": "arn:aws:memorydb:eu-west-2:295934382486:cluster/dev-valkey-aeroftp",
        "SnapshotRetentionLimit": 1,
        "MaintenanceWindow": "mon:23:00-tue:00:00",
        "SnapshotWindow": "03:30-04:30",
        "ACLName": "open-access",
        "AutoMinorVersionUpgrade": true,
        "DataTiering": "false"
    }
}
