#
# fleetnode.pkr.hcl -- Packer build for the IPSec VPN concentrator AMI
#                      (Debian 12 Bookworm, amd64)
#
# Increment 4+6ab: Debian 12 base + StrongSwan + FRR BGP base config (disabled)
#             + ipsecnode Increment 6a+6b + VPP with startup.conf (step 5).
# ipsecnode Increments 6c-6f are added in subsequent build increments.
#
# Prerequisites -- build the ipsecnode binary before running:
#   cargo build --release --target x86_64-unknown-linux-musl -p ipsecnode
#
# Run from this directory:
#   packer build fleetnode.pkr.hcl
#
# After a successful build, update the launch template to the new AMI ID:
#   aws ec2 create-launch-template-version \
#     --launch-template-name fleetipsec-lt-vpn \
#     --source-version '$Latest' \
#     --launch-template-data '{"ImageId":"ami-NEWID"}' \
#     --region eu-west-2
#   aws ec2 modify-launch-template \
#     --launch-template-name fleetipsec-lt-vpn \
#     --default-version '$Latest' \
#     --region eu-west-2
#
# Testing increments after launch (see AGENTS.md):
#   T1  IKE SA establishment (NAT-T)  -- StrongSwan + ipsecnode only
#   T2  kernel xfrm data path         -- add test-narrow.conf manually
#   T3  FRR /32 route advertisement   -- systemctl start frr
#   T4  VPP data plane                -- af_packet + ipsecnode Increment 6d

# -- Variables -----------------------------------------------------------------

variable "REGION" {
  type    = string
  default = "eu-west-2"
}

variable "VPC_ID" {
  type    = string
  default = "vpc-0595e17ce290fb050"
}

# Public subnet for the temporary Packer build instance.
# VPN nodes run in private subnets, but the build instance needs internet
# access for apt.  Reuse LVS-a (public, IGW route).
variable "SUBNET_BUILD" {
  type    = string
  default = "subnet-0fe6d05bc51c16ed8"   # FleetShell-IPSec-LVS-a
}

variable "SECURITY_GROUP_BUILD" {
  type    = string
  default = "sg-011b3ebfcfbcca22d"   # CLI_RemoteAccess
}

# -- Source --------------------------------------------------------------------

source "amazon-ebs" "bookworm" {
  ami_name      = "fleetnode-bookworm-{{timestamp}}"
  instance_type = "t3.medium"
  region        = var.REGION
  vpc_id        = var.VPC_ID
  subnet_id     = var.SUBNET_BUILD

  source_ami_filter {
    filters = {
      name                = "debian-12-amd64-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    owners      = ["136693071363"]   # Debian official AWS account
    most_recent = true
  }

  ssh_username = "admin"

  pause_before_connecting = "60s"
  ssh_timeout             = "5m"

  associate_public_ip_address = true
  ssh_interface               = "public_ip"

  security_group_ids = [var.SECURITY_GROUP_BUILD]

  tags = {
    Name        = "fleetnode-bookworm"
    Environment = "production"
    BuildDate   = "{{timestamp}}"
  }
}

# -- Build ---------------------------------------------------------------------

build {
  sources = ["source.amazon-ebs.bookworm"]

  # -- 1. System packages ------------------------------------------------------
  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl gnupg apt-transport-https nftables prometheus-node-exporter jq iproute2 tcpdump nload conntrack logrotate netcat-traditional valkey-tools",
      "sudo systemctl enable nftables",
      "sudo systemctl enable prometheus-node-exporter",
    ]
  }

  # -- 2. StrongSwan -----------------------------------------------------------
  # strongswan-libcharon does not exist on Debian; charon-systemd pulls in
  # libcharon-standard-plugins as a dependency automatically.
  provisioner "shell" {
    inline = [
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends charon-systemd strongswan-swanctl libcharon-extra-plugins libstrongswan-standard-plugins",
      "sudo systemctl enable strongswan",
    ]
  }

  # -- 3. StrongSwan config files ----------------------------------------------
  provisioner "file" {
    source      = "./_etc_strongswan_strongswan.conf"
    destination = "/tmp/_etc_strongswan_strongswan.conf"
  }
  provisioner "file" {
    source      = "./_etc_strongswan.d_charon.conf"
    destination = "/tmp/_etc_strongswan.d_charon.conf"
  }
  provisioner "file" {
    source      = "./_etc_strongswan.d_charon_sql.conf"
    destination = "/tmp/_etc_strongswan.d_charon_sql.conf"
  }
  provisioner "shell" {
    inline = [
      "sudo mv /tmp/_etc_strongswan_strongswan.conf   /etc/strongswan.conf",
      "sudo mv /tmp/_etc_strongswan.d_charon.conf     /etc/strongswan.d/charon.conf",
      "sudo mkdir -p /etc/strongswan.d/charon",
      "sudo mv /tmp/_etc_strongswan.d_charon_sql.conf /etc/strongswan.d/charon/sql.conf",
      "sudo chown root:root /etc/strongswan.conf /etc/strongswan.d/charon.conf /etc/strongswan.d/charon/sql.conf",
      "sudo chmod 640 /etc/strongswan.d/charon/sql.conf",
    ]
  }

  # -- 4. swanctl connection definitions ---------------------------------------
  # Catch-all IKEv1 + IKEv2 connections.  No credentials baked in;
  # ipsecnode loads PSKs via VICI load-shared at runtime.
  # bypass-vpc (172.16.0.0/16) and bypass-office (192.168.30.0/24) protect
  # management SSH access even when a broad test tunnel is active.
  provisioner "file" {
    source      = "./_etc_swanctl_conf.d_fleetipsec.conf"
    destination = "/tmp/_etc_swanctl_conf.d_fleetipsec.conf"
  }
  provisioner "shell" {
    inline = [
      "sudo mkdir -p /etc/swanctl/conf.d",
      "sudo mv /tmp/_etc_swanctl_conf.d_fleetipsec.conf /etc/swanctl/conf.d/fleetipsec.conf",
      "sudo chown root:root /etc/swanctl/conf.d/fleetipsec.conf",
    ]
  }

  # -- 5. FRR from deb.frrouting.org ------------------------------------------
  # bgpd enabled.  Full BGP config (AS 65001 -> AS 65002) in frr.conf.
  # Service is DISABLED -- enable when Return GW is ready (Build Order step 7).
  provisioner "file" {
    source      = "./_etc_frr_daemons"
    destination = "/tmp/_etc_frr_daemons"
  }
  provisioner "file" {
    source      = "./_etc_frr_frr.conf"
    destination = "/tmp/_etc_frr_frr.conf"
  }
  provisioner "shell" {
    inline = [
      "curl -s https://deb.frrouting.org/frr/keys.gpg | sudo tee /usr/share/keyrings/frrouting.gpg > /dev/null",
      "echo 'deb [signed-by=/usr/share/keyrings/frrouting.gpg] https://deb.frrouting.org/frr bookworm frr-stable' | sudo tee /etc/apt/sources.list.d/frr.list",
      "sudo apt-get update",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends frr frr-pythontools",
      # frr package creates /etc/frr/ and the frr user/group
      "sudo mv /tmp/_etc_frr_daemons  /etc/frr/daemons",
      "sudo mv /tmp/_etc_frr_frr.conf /etc/frr/frr.conf",
      "sudo chown root:frr /etc/frr/daemons /etc/frr/frr.conf",
      "sudo chmod 640     /etc/frr/daemons /etc/frr/frr.conf",
      "sudo systemctl enable frr",
    ]
  }

  # -- 6. VPP from packagecloud.io/fdio/release ----------------------------------
  # Build Order step 5: startup.conf and setup.gate baked in.
  # Hugepages (vm.nr_hugepages=1024) configured via sysctl.d (step 7 below);
  # systemd-sysctl.service applies them before vpp.service starts at boot.
  # DPDK plugin disabled -- ENA stays with the kernel driver (af_packet mode).
  # VPP is ENABLED: starts at boot, exposes /run/vpp/api.sock for ipsecnode
  # (Increment 6d) to configure af_packet interfaces, VRFs, and NAT tables.
  # policy-rc.d guard prevents the apt postinstall script from attempting to
  # start VPP on the t3.medium Packer build instance (no hugepages there).
  provisioner "file" {
    source      = "./_etc_vpp_startup.conf"
    destination = "/tmp/_etc_vpp_startup.conf"
  }
  provisioner "file" {
    source      = "./_etc_vpp_setup.gate"
    destination = "/tmp/_etc_vpp_setup.gate"
  }
  provisioner "shell" {
    inline = [
      "curl -fsSL https://packagecloud.io/fdio/release/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/fdio-release.gpg",
      "echo 'deb [signed-by=/usr/share/keyrings/fdio-release.gpg] https://packagecloud.io/fdio/release/debian/ bookworm main' | sudo tee /etc/apt/sources.list.d/fdio-release.list",
      "sudo apt-get update",
      "echo 'exit 101' | sudo tee /usr/sbin/policy-rc.d && sudo chmod +x /usr/sbin/policy-rc.d",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends vpp vpp-plugin-core vpp-plugin-dpdk",
      "sudo rm -f /usr/sbin/policy-rc.d",
      # Deploy startup.conf and setup.gate.
      # The vpp package creates /etc/vpp/ and the 'vpp' system group.
      "sudo mv /tmp/_etc_vpp_startup.conf /etc/vpp/startup.conf",
      "sudo mv /tmp/_etc_vpp_setup.gate   /etc/vpp/setup.gate",
      "sudo chown root:root /etc/vpp/startup.conf /etc/vpp/setup.gate",
      # Ensure the VPP log directory exists (package postinstall normally
      # creates it, but be explicit so the AMI is consistent).
      "sudo mkdir -p /var/log/vpp",
      "sudo chown root:vpp /var/log/vpp",
      "sudo chmod 750 /var/log/vpp",
      # Enable VPP: starts at boot, exposes binary API socket for ipsecnode.
      # (Was masked in prior increments; startup.conf is now baked in.)
      "sudo systemctl enable vpp",
    ]
  }

  # -- 7. sysctl tuning --------------------------------------------------------
  provisioner "file" {
    source      = "./_etc_sysctl.d_50-fleetnode.conf"
    destination = "/tmp/_etc_sysctl.d_50-fleetnode.conf"
  }
  provisioner "shell" {
    inline = [
      "sudo mv /tmp/_etc_sysctl.d_50-fleetnode.conf /etc/sysctl.d/50-fleetnode.conf",
      "sudo chown root:root /etc/sysctl.d/50-fleetnode.conf",
    ]
  }

  # -- 8. Kernel modules -------------------------------------------------------
  provisioner "file" {
    source      = "./_etc_modules-load.d_fleetnode.conf"
    destination = "/tmp/_etc_modules-load.d_fleetnode.conf"
  }
  provisioner "shell" {
    inline = [
      "sudo mv /tmp/_etc_modules-load.d_fleetnode.conf /etc/modules-load.d/fleetnode.conf",
      "sudo chown root:root /etc/modules-load.d/fleetnode.conf",
    ]
  }

  # -- 9. nftables ruleset -----------------------------------------------------
  provisioner "file" {
    source      = "./_etc_nftables_fleetnode.nft"
    destination = "/tmp/_etc_nftables_fleetnode.nft"
  }
  provisioner "shell" {
    inline = [
      "sudo mv /tmp/_etc_nftables_fleetnode.nft /etc/nftables.conf",
      "sudo chown root:root /etc/nftables.conf",
    ]
  }

  # -- 10. ipsecnode binary and systemd service --------------------------------
  # Static musl binary -- no glibc dependency.
  # Build with: cargo build --release --target x86_64-unknown-linux-musl -p ipsecnode
  provisioner "file" {
    source      = "../../target/x86_64-unknown-linux-musl/release/ipsecnode"
    destination = "/tmp/ipsecnode"
  }
  provisioner "file" {
    source      = "./_etc_systemd_system_ipsecnode.service"
    destination = "/tmp/_etc_systemd_system_ipsecnode.service"
  }
  provisioner "file" {
    source      = "./_etc_ipsecnode_ipsecnode.toml"
    destination = "/tmp/_etc_ipsecnode_ipsecnode.toml"
  }
  provisioner "shell" {
    inline = [
      "sudo mkdir -p /usr/local/bin",
      "sudo mv /tmp/ipsecnode /usr/local/bin/ipsecnode",
      "sudo chown root:root /usr/local/bin/ipsecnode",
      "sudo chmod +x /usr/local/bin/ipsecnode",
      "sudo mv /tmp/_etc_systemd_system_ipsecnode.service /etc/systemd/system/ipsecnode.service",
      "sudo chown root:root /etc/systemd/system/ipsecnode.service",
      # CA certificate directory -- ipsecnode loads CA certs from here (Inc 6a)
      "sudo mkdir -p /etc/ipsecnode/ca",
      "sudo mv /tmp/_etc_ipsecnode_ipsecnode.toml /etc/ipsecnode/ipsecnode.toml",
      "sudo chown root:root /etc/ipsecnode /etc/ipsecnode/ca /etc/ipsecnode/ipsecnode.toml",
      "sudo chmod 755 /etc/ipsecnode /etc/ipsecnode/ca",
      "sudo chmod 644 /etc/ipsecnode/ipsecnode.toml",
      "sudo systemctl daemon-reload",
      "sudo systemctl enable ipsecnode",
    ]
  }

  # -- 11. Clean up and reset cloud-init ---------------------------------------
  # Flush apt caches accumulated during the build to keep the AMI lean.
  # cloud-init clean ensures a fresh run on every instance launch from this AMI.
  provisioner "shell" {
    inline = [
      "sudo apt-get clean",
      "sudo cloud-init clean --logs",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -rf /var/lib/cloud/instances /var/lib/cloud/data",
      "sudo find /var/log -maxdepth 1 -name '*.log' -exec truncate -s 0 {} +",
      "sudo rm -f /root/.bash_history",
      "rm -f /home/admin/.bash_history",
    ]
  }
}
