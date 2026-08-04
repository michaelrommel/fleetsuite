#!/usr/bin/env bash
set -euo pipefail
#
# make_valkey_params.sh
#
# Creates a custom MemoryDB parameter group that enables keyspace event
# notifications (notify-keyspace-events = KEg$) and applies it to the
# shared dev-valkey-aeroftp cluster.
#
# Background: MemoryDB is a managed service that blocks CONFIG SET.
# Keyspace notifications must be configured at the cluster level via a
# parameter group.  ipsecnode's pubsub listener subscribes to
# __keyevent@0__:set and __keyevent@0__:del to react to PSK / device
# record changes without restarting.
#
# KEg$:
#   K -- Keyspace events
#   E -- Keyevent events
#   g -- Generic commands (DEL, EXPIRE, RENAME, ...)
#   $ -- String commands (SET, GETSET, ...)
#
# notify-keyspace-events is a dynamic parameter -- no cluster restart needed.
# Changes take effect within a few minutes of update-cluster being called.
#
# This parameter group is shared between aeroftp and fleetipsec workloads
# because they share the same cluster.  The KEg$ setting adds no load and
# does not affect aeroftp behaviour.
#
# Run once from your workstation.

REGION="eu-west-2"
PG_NAME="dev-valkey-keyspace-events"
CLUSTER="dev-valkey-aeroftp"
FAMILY="memorydb_valkey7"

echo "# Creating parameter group $PG_NAME ..."
aws memorydb create-parameter-group \
  --parameter-group-name "$PG_NAME" \
  --family "$FAMILY" \
  --description "Keyspace notifications (KEg$) for fleetipsec ipsecnode pubsub" \
  --region "$REGION"

echo "# Setting notify-keyspace-events = KEg$ ..."
aws memorydb update-parameter-group \
  --parameter-group-name "$PG_NAME" \
  --parameter-name-values "ParameterName=notify-keyspace-events,ParameterValue=KEg$" \
  --region "$REGION"

echo "# Applying parameter group to cluster $CLUSTER ..."
aws memorydb update-cluster \
  --cluster-name "$CLUSTER" \
  --parameter-group-name "$PG_NAME" \
  --region "$REGION"

echo "# Verifying (may show 'applying' for a few minutes) ..."
aws memorydb describe-clusters \
  --cluster-name "$CLUSTER" \
  --region "$REGION" \
  --query 'Clusters[0].{ParameterGroup:ParameterGroupName,Status:Status}'

#RESULT

# Creating parameter group dev-valkey-keyspace-events ...
# {
#     "ParameterGroup": {
#         "Name": "dev-valkey-keyspace-events",
#         "Family": "memorydb_valkey7",
#         "Description": "Keyspace notifications (KEg$) for fleetipsec ipsecnode pubsub",
#         "ARN": "arn:aws:memorydb:eu-west-2:295934382486:parametergroup/dev-valkey-keyspace-events"
#     }
# }
# # Setting notify-keyspace-events = KEg$ ...
# {
#     "ParameterGroup": {
#         "Name": "dev-valkey-keyspace-events",
#         "Family": "memorydb_valkey7",
#         "Description": "Keyspace notifications (KEg$) for fleetipsec ipsecnode pubsub",
#         "ARN": "arn:aws:memorydb:eu-west-2:295934382486:parametergroup/dev-valkey-keyspace-events"
#     }
# }
# # Applying parameter group to cluster dev-valkey-aeroftp ...
# {
#     "Cluster": {
#         "Name": "dev-valkey-aeroftp",
#         "Description": "Cluster created for Nucleus aeroftp demo",
#         "Status": "available",
#         "NumberOfShards": 1,
#         "AvailabilityMode": "SingleAZ",
#         "ClusterEndpoint": {
#             "Address": "clustercfg.dev-valkey-aeroftp.ak121m.memorydb.eu-west-2.amazonaws.com",
#             "Port": 6379
#         },
#         "NodeType": "db.t4g.small",
#         "EngineVersion": "7.3",
#         "EnginePatchVersion": "7.3.0",
#         "ParameterGroupName": "default.memorydb-valkey7",
#         "ParameterGroupStatus": "applying",
#         "SecurityGroups": [                                                                          {
#                 "SecurityGroupId": "sg-06d737ea5595c275d",
#                 "Status": "active"
#             },
#             {                                                                                            "SecurityGroupId": "sg-04dcc0342150eb53b",
#                 "Status": "active"
#             },
#             {
#                 "SecurityGroupId": "sg-0709bc00b444b3a9a",
#                 "Status": "active"
#             },
#             {
#                 "SecurityGroupId": "sg-04e471905c7422a96",
#                 "Status": "active"
#             },
#             {                                                                                            "SecurityGroupId": "sg-065f9193da9f46436",
#                 "Status": "active"
#             }
#         ],
#         "SubnetGroupName": "nucleus-private-subnets",
#         "TLSEnabled": true,                                                                      "ARN": "arn:aws:memorydb:eu-west-2:295934382486:cluster/dev-valkey-aeroftp",
#         "SnapshotRetentionLimit": 1,
#         "MaintenanceWindow": "mon:23:00-tue:00:00",
#         "SnapshotWindow": "03:30-04:30",
#         "ACLName": "open-access",
#         "AutoMinorVersionUpgrade": true,
#         "DataTiering": "false"
#     }
# }
# # Verifying (may show 'applying' for a few minutes) ...
# {
#     "ParameterGroup": "dev-valkey-keyspace-events",
#     "Status": "available"
# }
