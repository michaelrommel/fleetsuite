#!/usr/bin/env bash

export REQUESTS_CA_BUNDLE=/etc/ssl/certs/zscaler_root.pem

CLUSTER=aeroftp-cluster

START=$1
END=$2
if [[ -z "$START" ]] || [[ -z "$END" ]]; then
	echo "Usage: $0 <start> <end> [FARGATE]"
	exit 1
fi

SPOT=$3
if [[ -z "$SPOT" ]]; then
	SPOT=FARGATE_SPOT
fi

# The backend subnets are ready. You can now move the Fargate task to subnet-01a513292ea15ae83 (Backend-a) or subnet-08213d03f2940855c
#  (Backend-b) with sg-backend attached, and the full return path will work without any further routing changes.

fakeme() {
	ID=${1: -2}
	aws ecs run-task \
		--no-cli-pager \
		--count 1 \
		--cluster $CLUSTER \
		--capacity-provider-strategy capacityProvider=${SPOT},weight=1 \
		--network-configuration "awsvpcConfiguration={subnets=[subnet-01a513292ea15ae83],securityGroups=[sg-05aacef85bd425965],assignPublicIp=ENABLED}" \
		--task-definition test-backend \
		--enable-execute-command \
		--overrides "{
			\"containerOverrides\": [{
				\"name\": \"test-backend\"
			}]
		}"
}

# Launch agents pointing at aerocoach's public gRPC port
for i in $(seq "${START}" "${END}"); do
	TASK_OUT=$(fakeme "0$i")
	echo ${TASK_OUT} | jq '.tasks[0] | { taskArn: .taskArn, containerOverrides: .overrides.containerOverrides }'
done
