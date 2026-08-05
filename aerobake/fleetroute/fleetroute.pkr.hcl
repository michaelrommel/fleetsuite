#
# fleetroute.pkr.hcl -- Packer build for the IPSec Return GW AMI (Alpine Linux)
#
# Adapted from aerosuite/aerobake/aeroscale/aeroscale.pkr.hcl and
# fleetsuite/aerobake/fleetscale/fleetscale.pkr.hcl.
#
# Prerequisites -- build both workspaces with the musl target before running:
#
#   # aeroplug (from the aerosuite submodule)
#   cd vendor/aerosuite
#   cargo build --release --target x86_64-unknown-linux-musl -p aeroplug
#   cd ../..
#
#   # fleetpulse (this workspace)
#   cargo build --release --target x86_64-unknown-linux-musl -p fleetpulse
#
# Then run from this directory:
#   packer build -var-file=../../infrastructure/fleetroute.pkrvars.hcl fleetroute.pkr.hcl
#

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
# Using LVS-a (AZ-a public subnet) -- it has an IGW route and is reachable
# from the office directly or via the bastion.
variable "SUBNET_BUILD" {
  type    = string
  default = "subnet-0fe6d05bc51c16ed8"   # FleetShell-IPSec-LVS-a
}

# Security group that allows inbound SSH from the build host / bastion.
variable "SECURITY_GROUP_BUILD" {
  type    = string
  default = "sg-011b3ebfcfbcca22d"   # CLI_RemoteAccess
}

# -- Source --------------------------------------------------------------------

source "amazon-ebs" "alpine" {
  ami_name      = "fleetroute-alpine-{{timestamp}}"
  instance_type = "t3.micro"
  region        = var.REGION
  vpc_id        = var.VPC_ID
  subnet_id     = var.SUBNET_BUILD

  source_ami_filter {
    filters = {
      name                = "alpine-3.23.3-x86_64-uefi-tiny-r0"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    owners      = ["538276064493"]   # Alpine Linux official AWS account
    most_recent = true
  }

  # Install sudo before any provisioner runs.
  user_data = <<-EOF
    #!/bin/sh
    apk add --no-cache sudo
    echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/wheel
  EOF

  ssh_username = "alpine"

  pause_before_connecting = "90s"
  ssh_timeout             = "5m"

  associate_public_ip_address = true
  ssh_interface               = "public_ip"

  security_group_ids = [var.SECURITY_GROUP_BUILD]

  tags = {
    Name        = "fleetroute-alpine"
    Environment = "production"
    BuildDate   = "{{timestamp}}"
  }
}

# -- Build ---------------------------------------------------------------------

build {
  sources = ["source.amazon-ebs.alpine"]

  # -- 1. System packages ------------------------------------------------------
  provisioner "shell" {
    inline = [
      "sudo apk update",
      "sudo apk add --no-cache ca-certificates openssh curl procps binutils logrotate iproute2 nftables socat iputils tcpdump nload keepalived frr frr-openrc dnsmasq prometheus-node-exporter",
      # Enable at boot
      "sudo rc-update add sshd         default",
      # dnsmasq must run even in debug mode -- resolv.conf points to 127.0.0.1
      # and aeroplug/fleetpulse need DNS to reach the EC2 API.
      "sudo rc-update add dnsmasq      default",
      # DEBUG: services below are intentionally disabled for manual boot-sequence
      # debugging. Re-enable before building the production AMI.
      #"sudo rc-update add nftables     default",
      #"sudo rc-update add frr          default",
      #"sudo rc-update add node-exporter default",
    ]
  }

  # -- 2. Root shell convenience aliases ---------------------------------------
  provisioner "file" {
    source      = "./_root_.profile"
    destination = "/tmp/_root_.profile"
  }
  provisioner "file" {
    source      = "./_root_.ashrc"
    destination = "/tmp/_root_.ashrc"
  }
  provisioner "shell" {
    inline = [
      "sudo mv /tmp/_root_.profile /root/.profile",
      "sudo mv /tmp/_root_.ashrc   /root/.ashrc",
      "sudo chown root:root /root/.profile /root/.ashrc",
    ]
  }

  # -- 3. Syslog -- route local3.* to /var/log/keepalived/keepalived.log ------
  provisioner "file" {
    source      = "./_etc_syslog.conf"
    destination = "/tmp/_etc_syslog.conf"
  }
  provisioner "shell" {
    inline = [
      "sudo mkdir -p /var/log/keepalived",
      "sudo mv /tmp/_etc_syslog.conf /etc/syslog.conf",
      "sudo chown root:root /etc/syslog.conf",
    ]
  }

  # -- 4. Log rotation ---------------------------------------------------------
  provisioner "file" {
    source      = "./_etc_logrotate.d_keepalived"
    destination = "/tmp/_etc_logrotate.d_keepalived"
  }
  provisioner "shell" {
    inline = [
      "sudo mkdir -p /etc/logrotate.d",
      "sudo mv /tmp/_etc_logrotate.d_keepalived /etc/logrotate.d/keepalived",
      "sudo chown root:root /etc/logrotate.d/keepalived",
    ]
  }

  # -- 5. dnsmasq -- local caching resolver ------------------------------------
  provisioner "file" {
    source      = "./_etc_dnsmasq.d_fleetroute.conf"
    destination = "/tmp/_etc_dnsmasq.d_fleetroute.conf"
  }
  provisioner "file" {
    source      = "./_etc_dhcpcd.conf"
    destination = "/tmp/_etc_dhcpcd.conf"
  }
  provisioner "file" {
    source      = "./_etc_resolv.conf"
    destination = "/tmp/_etc_resolv.conf"
  }
  provisioner "shell" {
    inline = [
      "sudo mkdir -p /etc/dnsmasq.d",
      "sudo mv /tmp/_etc_dnsmasq.d_fleetroute.conf /etc/dnsmasq.d/fleetroute.conf",
      "sudo chown root:root /etc/dnsmasq.d/fleetroute.conf",
      "sudo mv /tmp/_etc_dhcpcd.conf /etc/dhcpcd.conf",
      "sudo chown root:root /etc/dhcpcd.conf",
      "sudo mv /tmp/_etc_resolv.conf /etc/resolv.conf",
      "sudo chown root:root /etc/resolv.conf",
    ]
  }

  # -- 6. sysctl tuning --------------------------------------------------------
  provisioner "file" {
    source      = "./_etc_sysctl.d_50-fleetroute.conf"
    destination = "/tmp/_etc_sysctl.d_50-fleetroute.conf"
  }
  provisioner "shell" {
    inline = [
      "sudo mv /tmp/_etc_sysctl.d_50-fleetroute.conf /etc/sysctl.d/50-fleetroute.conf",
      "sudo chown root:root /etc/sysctl.d/50-fleetroute.conf",
    ]
  }

  # -- 7. nftables ruleset (filter table only -- no NAT) -----------------------
  provisioner "file" {
    source      = "./_etc_nftables_fleetroute.nft"
    destination = "/tmp/_etc_nftables_fleetroute.nft"
  }
  provisioner "shell" {
    inline = [
      "sudo mv /tmp/_etc_nftables_fleetroute.nft /etc/nftables.nft",
      "sudo chown root:root /etc/nftables.nft",
    ]
  }

  # -- 8. FRR config -----------------------------------------------------------
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
      "sudo mkdir -p /etc/frr",
      "sudo mv /tmp/_etc_frr_daemons /etc/frr/daemons",
      "sudo mv /tmp/_etc_frr_frr.conf /etc/frr/frr.conf",
      "sudo chown -R frr:frr /etc/frr",
      "sudo chmod 640 /etc/frr/daemons /etc/frr/frr.conf",
    ]
  }

  # -- 9. Binaries -- fleetpulse and aeroplug ----------------------------------
  # Both are statically linked musl binaries.  Build with:
  #   cd vendor/aerosuite && cargo build --release --target x86_64-unknown-linux-musl -p aeroplug
  #   cargo build --release --target x86_64-unknown-linux-musl -p fleetpulse
  provisioner "file" {
    source      = "../../target/x86_64-unknown-linux-musl/release/fleetpulse"
    destination = "/tmp/fleetpulse"
  }
  provisioner "file" {
    source      = "../../vendor/aerosuite/target/x86_64-unknown-linux-musl/release/aeroplug"
    destination = "/tmp/aeroplug"
  }
  provisioner "shell" {
    inline = [
      "sudo mkdir -p /usr/local/bin",
      "sudo mv /tmp/fleetpulse /usr/local/bin/fleetpulse",
      "sudo mv /tmp/aeroplug   /usr/local/bin/aeroplug",
      "sudo chown root:root /usr/local/bin/fleetpulse /usr/local/bin/aeroplug",
      "sudo chmod +x       /usr/local/bin/fleetpulse /usr/local/bin/aeroplug",
    ]
  }

  # -- 10. keepalived -- config, init.d, and conf.d ----------------------------
  provisioner "file" {
    source      = "./_etc_keepalived_keepalived.conf"
    destination = "/tmp/_etc_keepalived_keepalived.conf"
  }
  provisioner "file" {
    source      = "./_etc_init.d_keepalived"
    destination = "/tmp/_etc_init.d_keepalived"
  }
  provisioner "file" {
    source      = "./_etc_conf.d_keepalived"
    destination = "/tmp/_etc_conf.d_keepalived"
  }
  provisioner "shell" {
    inline = [
      "sudo mkdir -p /etc/keepalived",
      # keepalived_script user required by keepalived's enable_script_security.
      "sudo adduser -S -D -H -s /sbin/nologin keepalived_script",
      "sudo mv /tmp/_etc_keepalived_keepalived.conf /etc/keepalived/keepalived.conf",
      "sudo mv /tmp/_etc_init.d_keepalived          /etc/init.d/keepalived",
      "sudo mv /tmp/_etc_conf.d_keepalived          /etc/conf.d/keepalived",
      "sudo chown root:root /etc/keepalived/keepalived.conf",
      "sudo chown root:root /etc/init.d/keepalived",
      "sudo chown root:root /etc/conf.d/keepalived",
      "sudo chmod +x /etc/init.d/keepalived",
      # DEBUG: disabled for manual boot-sequence debugging.
      # Re-enable before building the production AMI.
      #"sudo rc-update add keepalived default",
    ]
  }

  # -- 11. Reset cloud-init so the AMI is reusable as a launch template base ---
  provisioner "shell" {
    inline = [
      "sudo rm -rf /var/lib/cloud",
      "sudo rm -f /etc/hostname",
      "sudo tiny-cloud --bootstrap incomplete",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo truncate -s 0 /var/log/*.log",
      "history -c",
    ]
  }
}
