#
# fleetscale.pkr.hcl — Packer build for the IPSec LVS AMI (Alpine Linux)
#
# Adapted from aerosuite/aerobake/aeroscale/aeroscale.pkr.hcl.
#
# Prerequisites — build both workspaces with the musl target before running:
#
#   # aeroplug (from the aerosuite submodule)
#   cd vendor/aerosuite
#   cargo build --release --target x86_64-unknown-linux-musl -p aeroplug
#   cd ../..
#
#   # ipsecpulse (this workspace)
#   cargo build --release --target x86_64-unknown-linux-musl -p ipsecpulse
#
# Then run from this directory:
#   packer build -var-file=../../infrastructure/fleetscale.pkrvars.hcl fleetscale.pkr.hcl
#

# ── Variables ─────────────────────────────────────────────────────────────────

variable "REGION" {
  type    = string
  default = "eu-west-2"
}

variable "VPC_ID" {
  type    = string
  default = "vpc-0595e17ce290fb050"
}

# Public subnet used to launch the temporary build instance.
# Using LVS-a (the primary AZ public subnet) — it has an IGW route and the
# bastion can reach it.
variable "SUBNET_BUILD" {
  type    = string
  default = "subnet-0fe6d05bc51c16ed8"   # FleetShell-IPSec-LVS-a
}

# Security group that allows inbound SSH from the build host / bastion.
variable "SECURITY_GROUP_BUILD" {
  type    = string
  default = "sg-011b3ebfcfbcca22d"   # CLI_RemoteAccess
}

# ── Source ────────────────────────────────────────────────────────────────────

source "amazon-ebs" "alpine" {
  ami_name      = "fleetscale-alpine-{{timestamp}}"
  instance_type = "t3.micro"
  region        = var.REGION
  vpc_id        = var.VPC_ID
  subnet_id     = var.SUBNET_BUILD

  source_ami_filter {
    filters = {
      # Pin to an exact Alpine version; "most_recent" on a name filter can
      # return older patch releases due to non-lexicographic sort order.
      name                = "alpine-3.23.3-x86_64-uefi-tiny-r0"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    owners      = ["538276064493"]   # Alpine Linux official AWS account
    most_recent = true
  }

  # Install sudo before any provisioner runs (not present in the tiny AMI).
  user_data = <<-EOF
    #!/bin/sh
    apk add --no-cache sudo
    echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/wheel
  EOF

  ssh_username = "alpine"

  # Give the instance time to fully boot before the first SSH attempt.
  pause_before_connecting = "90s"
  ssh_timeout             = "5m"

  # Build instance is reachable via the office bastion.
  associate_public_ip_address = true
  ssh_interface               = "public_ip"
  # ssh_bastion_host            = "192.168.30.1"
  # ssh_bastion_port            = 22
  # ssh_bastion_username        = "rommel"
  # ssh_bastion_agent_auth      = true

  security_group_ids = [var.SECURITY_GROUP_BUILD]

  tags = {
    Name        = "fleetscale-alpine"
    Environment = "production"
    BuildDate   = "{{timestamp}}"
  }
}

# ── Build ─────────────────────────────────────────────────────────────────────

build {
  sources = ["source.amazon-ebs.alpine"]

  # ── 1. System packages ─────────────────────────────────────────────────────
  provisioner "shell" {
    inline = [
      "sudo apk update",
      "sudo apk add --no-cache ca-certificates openssh curl procps binutils logrotate iproute2 nftables socat conntrack-tools iputils tcpdump nload keepalived dnsmasq prometheus-node-exporter",
      # Enable at boot
      "sudo rc-update add sshd default",
      "sudo rc-update add nftables default",
      "sudo rc-update add dnsmasq default",
      "sudo rc-update add node-exporter default",
    ]
  }

  # ── 2. Root shell convenience aliases ──────────────────────────────────────
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

  # ── 3. Syslog — route local3.* to /var/log/keepalived/keepalived.log ───────
  # keepalived and the ipsecpulse notify scripts both log to local3.
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

  # ── 4. Log rotation ─────────────────────────────────────────────────────────
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

  # ── 5. dnsmasq — local caching resolver ────────────────────────────────────
  provisioner "file" {
    source      = "./_etc_dnsmasq.d_fleetscale.conf"
    destination = "/tmp/_etc_dnsmasq.d_fleetscale.conf"
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
      "sudo mv /tmp/_etc_dnsmasq.d_fleetscale.conf /etc/dnsmasq.d/fleetscale.conf",
      "sudo chown root:root /etc/dnsmasq.d/fleetscale.conf",
      "sudo mv /tmp/_etc_dhcpcd.conf /etc/dhcpcd.conf",
      "sudo chown root:root /etc/dhcpcd.conf",
      # Install resolv.conf last so it wins over any prior dhcpcd hook.
      "sudo mv /tmp/_etc_resolv.conf /etc/resolv.conf",
      "sudo chown root:root /etc/resolv.conf",
    ]
  }

  # ── 6. sysctl tuning ────────────────────────────────────────────────────────
  provisioner "file" {
    source      = "./_etc_sysctl.d_50-fleetscale.conf"
    destination = "/tmp/_etc_sysctl.d_50-fleetscale.conf"
  }
  provisioner "shell" {
    inline = [
      "sudo mv /tmp/_etc_sysctl.d_50-fleetscale.conf /etc/sysctl.d/50-fleetscale.conf",
      "sudo chown root:root /etc/sysctl.d/50-fleetscale.conf",
    ]
  }

  # ── 7. Kernel modules ───────────────────────────────────────────────────────
  provisioner "file" {
    source      = "./_etc_modules-load.d_fleetscale.conf"
    destination = "/tmp/_etc_modules-load.d_fleetscale.conf"
  }
  provisioner "shell" {
    inline = [
      "sudo mv /tmp/_etc_modules-load.d_fleetscale.conf /etc/modules-load.d/fleetscale.conf",
      "sudo chown root:root /etc/modules-load.d/fleetscale.conf",
    ]
  }

  # ── 8. nftables ruleset ──────────────────────────────────────────────────────
  # The static ruleset (filter table only) includes /etc/nftables.d/ipsec-nat.nft
  # which is generated at instance boot by ipsecpulse (complete nat table with
  # inline anonymous maps — no $VARIABLE references, no 'type integer' named maps).
  # Place an empty placeholder so nftables loads cleanly before ipsecpulse runs.
  provisioner "file" {
    source      = "./_etc_nftables_fleetscale.nft"
    destination = "/tmp/_etc_nftables_fleetscale.nft"
  }
  provisioner "file" {
    source      = "./_etc_nftables.d_ipsec-nat.nft"
    destination = "/tmp/_etc_nftables.d_ipsec-nat.nft"
  }
  provisioner "shell" {
    inline = [
      "sudo mv /tmp/_etc_nftables_fleetscale.nft /etc/nftables.nft",
      "sudo mv /tmp/_etc_nftables.d_ipsec-nat.nft /etc/nftables.d/ipsec-nat.nft",
      "sudo chown root:root /etc/nftables.nft",
      "sudo chown root:root /etc/nftables.d/ipsec-nat.nft",
    ]
  }

  # ── 9. Binaries — ipsecpulse and aeroplug ───────────────────────────────────
  # Both are statically linked musl binaries.  Build with:
  #   cd vendor/aerosuite && cargo build --release --target x86_64-unknown-linux-musl -p aeroplug
  #   cargo build --release --target x86_64-unknown-linux-musl -p ipsecpulse
  provisioner "file" {
    source      = "../../target/x86_64-unknown-linux-musl/release/ipsecpulse"
    destination = "/tmp/ipsecpulse"
  }
  provisioner "file" {
    source      = "../../vendor/aerosuite/target/x86_64-unknown-linux-musl/release/aeroplug"
    destination = "/tmp/aeroplug"
  }
  provisioner "shell" {
    inline = [
      "sudo mkdir -p /usr/local/bin",
      "sudo mv /tmp/ipsecpulse /usr/local/bin/ipsecpulse",
      "sudo mv /tmp/aeroplug   /usr/local/bin/aeroplug",
      "sudo chown root:root /usr/local/bin/ipsecpulse /usr/local/bin/aeroplug",
      "sudo chmod +x       /usr/local/bin/ipsecpulse /usr/local/bin/aeroplug",
    ]
  }

  # ── 10. keepalived — config, init.d, and conf.d ─────────────────────────────
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
      # keepalived_script user — required by keepalived's enable_script_security
      "sudo adduser -S -D -H -s /sbin/nologin keepalived_script",
      "sudo mv /tmp/_etc_keepalived_keepalived.conf /etc/keepalived/keepalived.conf",
      "sudo mv /tmp/_etc_init.d_keepalived          /etc/init.d/keepalived",
      "sudo mv /tmp/_etc_conf.d_keepalived          /etc/conf.d/keepalived",
      "sudo chown root:root /etc/keepalived/keepalived.conf",
      "sudo chown root:root /etc/init.d/keepalived",
      "sudo chown root:root /etc/conf.d/keepalived",
      "sudo chmod +x /etc/init.d/keepalived",
      "sudo rc-update add keepalived default",
    ]
  }

  # ── 11. ipsecscale — stub init.d (started by notify scripts, not at boot) ───
  provisioner "file" {
    source      = "./_etc_init.d_ipsecscale"
    destination = "/tmp/_etc_init.d_ipsecscale"
  }
  provisioner "file" {
    source      = "./_etc_conf.d_ipsecscale"
    destination = "/tmp/_etc_conf.d_ipsecscale"
  }
  provisioner "shell" {
    inline = [
      "sudo mv /tmp/_etc_init.d_ipsecscale /etc/init.d/ipsecscale",
      "sudo mv /tmp/_etc_conf.d_ipsecscale /etc/conf.d/ipsecscale",
      "sudo chown root:root /etc/init.d/ipsecscale /etc/conf.d/ipsecscale",
      "sudo chmod +x /etc/init.d/ipsecscale",
      # NOT added to the default runlevel — started only by notify-master.sh.
    ]
  }

  # ── 12. Reset cloud-init so the AMI is reusable as a launch template base ───
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
