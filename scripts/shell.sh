#!/usr/bin/env bash

#export REQUESTS_CA_BUNDLE=/etc/ssl/certs/zscaler_root.pem

TASK=$1
if [[ -z "$TASK" ]]; then
	echo "Usage: $0 <container task arn>"
	exit 1
fi

aws ecs execute-command \
	--region eu-west-2 \
	--cluster aeroftp-cluster \
	--container test-backend \
	--command "/bin/sh" \
	--interactive \
	--task "${TASK}"
