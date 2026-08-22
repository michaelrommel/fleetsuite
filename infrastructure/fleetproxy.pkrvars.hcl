# fleetproxy.pkrvars.hcl
#
# Packer variables for aerobake/fleetproxy/fleetproxy.pkr.hcl. Passed with:
#   packer build -var-file=../../infrastructure/fleetproxy.pkrvars.hcl fleetproxy.pkr.hcl
#
# These OVERRIDE the `variable {}` defaults in the template. Every value below
# already matches the template default, so this file is optional (build without
# -var-file works identically); it exists to document the build-time knobs and
# to make dev/prod overrides a one-line edit rather than a template change.
#
# NOTE: these only affect the TEMPORARY Packer BUILD instance (where the AMI is
# assembled), not the runtime fleet. Runtime networking (eth0 Backend subnets,
# eth1 proxy-out subnets, SGs, ASG) is created by
# infrastructure/make_proxy_service.sh.

REGION = "eu-west-2"
VPC_ID = "vpc-0595e17ce290fb050"

# Public subnet with an IGW route, reachable from the bastion for SSH during
# the build (Packer connects over the public IP).
SUBNET_BUILD = "subnet-0fe6d05bc51c16ed8"   # FleetShell-IPSec-LVS-a

# Security group allowing inbound SSH to the build instance.
SECURITY_GROUP_BUILD = "sg-011b3ebfcfbcca22d"   # CLI_RemoteAccess
