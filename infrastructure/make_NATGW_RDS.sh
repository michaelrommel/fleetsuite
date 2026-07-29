#!/usr/bin/env bash
set -euo pipefail

echo "# NAT Gateway in LVS-a public subnet"
# (requires EIP alloc-id from step 2 output)
aws ec2 create-nat-gateway \
  --subnet-id subnet-0fe6d05bc51c16ed8 \
  --allocation-id eipalloc-0ac2fb2dd51415b30 \
  --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=FleetShell-IPSec-NatGW}]'

echo "# RDS subnet group (uses Management + one more private subnet for Multi-AZ)"
aws rds create-db-subnet-group \
  --db-subnet-group-name fleetshell-ipsec-rds \
  --db-subnet-group-description "StrongSwan SQL backend for FleetShell IPSec" \
  --subnet-ids subnet-02387719b5b2c3352 subnet-082703ab573f0f4e9

echo "# RDS PostgreSQL for StrongSwan SQL plugin"
aws rds create-db-instance \
  --db-instance-identifier fleetshell-ipsec-strongswan \
  --db-instance-class db.t4g.medium \
  --engine postgres \
  --engine-version "18.4" \
  --master-username strongswan \
  --master-user-password xxxxxx  \
  --allocated-storage 20 \
  --storage-type gp3 \
  --db-subnet-group-name fleetshell-ipsec-rds \
  --vpc-security-group-ids sg-053524ea7dcdb64f1 \
  --no-publicly-accessible \
  --backup-retention-period 7 \
  --multi-az \
  --db-name strongswan \
  --tags '[{"Key":"Name","Value":"FleetShell-IPSec-StrongSwan"}]'

RESULT

# NAT Gateway in LVS-a public subnet
{
    "ClientToken": "48fd1c7d-af3d-46f3-83da-9fba9befe510",
    "NatGateway": {
        "CreateTime": "2026-07-29T19:32:08+00:00",
        "NatGatewayAddresses": [
            {
                "AllocationId": "eipalloc-0ac2fb2dd51415b30",
                "IsPrimary": true,
                "Status": "associating"
            }
        ],
        "NatGatewayId": "nat-0fb75bf0679751582",
        "State": "pending",
        "SubnetId": "subnet-0fe6d05bc51c16ed8",
        "VpcId": "vpc-0595e17ce290fb050",
        "Tags": [
            {
                "Key": "Name",
                "Value": "FleetShell-IPSec-NatGW"
            }
        ],
        "ConnectivityType": "public"
    }
}
# RDS subnet group (uses Management + one more private subnet for Multi-AZ)
{
    "DBSubnetGroup": {
        "DBSubnetGroupName": "fleetshell-ipsec-rds",
        "DBSubnetGroupDescription": "StrongSwan SQL backend for FleetShell IPSec",
        "VpcId": "vpc-0595e17ce290fb050",
        "SubnetGroupStatus": "Complete",
        "Subnets": [
            {
                "SubnetIdentifier": "subnet-082703ab573f0f4e9",
                "SubnetAvailabilityZone": {
                    "Name": "eu-west-2b"
                },
                "SubnetOutpost": {},
                "SubnetStatus": "Active"
            },
            {
                "SubnetIdentifier": "subnet-02387719b5b2c3352",
                "SubnetAvailabilityZone": {
                    "Name": "eu-west-2a"
                },
                "SubnetOutpost": {},
                "SubnetStatus": "Active"
            }
        ],
        "DBSubnetGroupArn": "arn:aws:rds:eu-west-2:295934382486:subgrp:fleetshell-ipsec-rds",
        "SupportedNetworkTypes": [
            "IPV4"
        ]
    }
}
# RDS PostgreSQL for StrongSwan SQL plugin
{
    "DBInstance": {
        "DBInstanceIdentifier": "fleetshell-ipsec-strongswan",
        "DBInstanceClass": "db.t4g.medium",
        "Engine": "postgres",
        "DBInstanceStatus": "creating",
        "MasterUsername": "strongswan",
        "DBName": "strongswan",
        "AllocatedStorage": 20,
        "PreferredBackupWindow": "00:20-00:50",
        "BackupRetentionPeriod": 7,
        "DBSecurityGroups": [],
        "VpcSecurityGroups": [
            {
                "VpcSecurityGroupId": "sg-053524ea7dcdb64f1",
                "Status": "active"
            }
        ],
        "DBParameterGroups": [
            {
                "DBParameterGroupName": "default.postgres18",
                "ParameterApplyStatus": "in-sync"
            }
        ],
        "DBSubnetGroup": {
            "DBSubnetGroupName": "fleetshell-ipsec-rds",
            "DBSubnetGroupDescription": "StrongSwan SQL backend for FleetShell IPSec",
            "VpcId": "vpc-0595e17ce290fb050",
            "SubnetGroupStatus": "Complete",
            "Subnets": [
                {
                    "SubnetIdentifier": "subnet-082703ab573f0f4e9",
                    "SubnetAvailabilityZone": {
                        "Name": "eu-west-2b"
                    },
                    "SubnetOutpost": {},
                    "SubnetStatus": "Active"
                },
                {
                    "SubnetIdentifier": "subnet-02387719b5b2c3352",
                    "SubnetAvailabilityZone": {
                        "Name": "eu-west-2a"
                    },
                    "SubnetOutpost": {},
                    "SubnetStatus": "Active"
                }
            ]
        },
        "PreferredMaintenanceWindow": "wed:05:14-wed:05:44",
        "PendingModifiedValues": {
            "MasterUserPassword": "****"
        },
        "MultiAZ": true,
        "EngineVersion": "18.4",
        "AutoMinorVersionUpgrade": true,
        "ReadReplicaDBInstanceIdentifiers": [],
        "LicenseModel": "postgresql-license",
        "Iops": 3000,
        "OptionGroupMemberships": [
            {
                "OptionGroupName": "default:postgres-18",
                "Status": "in-sync"
            }
        ],
        "PubliclyAccessible": false,
        "StorageType": "gp3",
        "DbInstancePort": 0,
        "StorageEncrypted": false,
        "DbiResourceId": "db-5HBRG2GJKKCAXTHTQ4COT554LQ",
        "CACertificateIdentifier": "rds-ca-rsa2048-g1",
        "DomainMemberships": [],
        "CopyTagsToSnapshot": false,
        "MonitoringInterval": 0,
        "DBInstanceArn": "arn:aws:rds:eu-west-2:295934382486:db:fleetshell-ipsec-strongswan",
        "IAMDatabaseAuthenticationEnabled": false,
        "PerformanceInsightsEnabled": false,
        "DeletionProtection": false,
        "AssociatedRoles": [],
        "TagList": [
            {
                "Key": "Name",
                "Value": "FleetShell-IPSec-StrongSwan"
            }
        ],
        "CustomerOwnedIpEnabled": false,
        "BackupTarget": "region",
        "NetworkType": "IPV4",
        "StorageThroughput": 125,
        "CertificateDetails": {
            "CAIdentifier": "rds-ca-rsa2048-g1"
        },
        "DedicatedLogVolume": false
    }
}

