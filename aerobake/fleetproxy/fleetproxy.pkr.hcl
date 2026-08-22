#
# fleetproxy.pkr.hcl -- Packer build for the FleetShell dual-homed Squid proxy
# AMI (Alpine Linux). Adapted from aerobake/fleetroute/fleetroute.pkr.hcl.
#
# The instance is DUAL-HOMED at runtime (see aerobake/fleetproxy/README.md):
#   eth0  device-facing ENI  (subnet default -> IPSec concentrator)  Squid :8080
#   eth1  egress ENI          (subnet default -> NAT gateway)         created +
#         attached at boot by the `proxy-net` OpenRC service, which also sets up
#         source-based policy routing and materialises the Squid egress binding.
#
# Prerequisites -- build both workspaces with the musl target before running:
#
#   # squid-infoproxy (this workspace)
#   cargo build --release --target x86_64-unknown-linux-musl -p squid-infoproxy
#
#   # aeroplug (aerosuite submodule)
#   cd vendor/aerosuite
#   cargo build --release --target x86_64-unknown-linux-musl -p aeroplug
#   cd ../..
#
# Then from this directory:
#   packer build -var-file=../../infrastructure/fleetproxy.pkrvars.hcl fleetproxy.pkr.hcl

# -- Variables -----------------------------------------------------------------

variable "REGION" {
  type    = string
  default = "eu-west-2"
}

variable "VPC_ID" {
  type    = string
  default = "vpc-0595e17ce290fb050"
}

# Public subnet for the temporary Packer build instance (IGW route).
variable "SUBNET_BUILD" {
  type    = string
  default = "subnet-0fe6d05bc51c16ed8"   # FleetShell-IPSec-LVS-a
}

variable "SECURITY_GROUP_BUILD" {
  type    = string
  default = "sg-011b3ebfcfbcca22d"   # CLI_RemoteAccess (SSH from bastion)
}

# -- Source --------------------------------------------------------------------

source "amazon-ebs" "alpine" {
  ami_name      = "fleetproxy-alpine-{{timestamp}}"
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

  tags = {
    Name        = "fleetproxy-alpine"
    Environment = "production"
    BuildDate   = "{{timestamp}}"
  }
}

# -- Build ---------------------------------------------------------------------

build {
  sources = ["source.amazon-ebs.alpine"]

  # -- 1. System packages ------------------------------------------------------
  # squid          -- the forward proxy
  # aws-cli        -- create/describe/delete the egress ENI in proxy-net
  # iproute2       -- policy routing (ip rule / ip route)
  # ca-certificates-- TLS peer trust (squid) + rediss roots for the helper
  provisioner "shell" {
    inline = [
      "sudo apk update",
      "sudo apk add --no-cache ca-certificates openssh curl procps binutils logrotate iproute2 nftables tcpdump nload squid aws-cli prometheus-node-exporter",
      "sudo rc-update add sshd          default",
      "sudo rc-update add nftables      default",
      "sudo rc-update add node-exporter default",
    ]
  }

  # -- 2. Binaries -- squid-infoproxy (this workspace) + aeroplug (aerosuite) --
  provisioner "file" {
    source      = "../../target/x86_64-unknown-linux-musl/release/squid-infoproxy"
    destination = "/tmp/squid-infoproxy"
  }
  provisioner "file" {
    source      = "../../vendor/aerosuite/target/x86_64-unknown-linux-musl/release/aeroplug"
    destination = "/tmp/aeroplug"
  }
  provisioner "shell" {
    inline = [
      "sudo mkdir -p /usr/local/bin",
      "sudo mv /tmp/squid-infoproxy /usr/local/bin/squid-infoproxy",
      "sudo mv /tmp/aeroplug        /usr/local/bin/aeroplug",
      "sudo chown root:root /usr/local/bin/squid-infoproxy /usr/local/bin/aeroplug",
      "sudo chmod +x        /usr/local/bin/squid-infoproxy /usr/local/bin/aeroplug",
    ]
  }

  # -- 3. Squid config ---------------------------------------------------------
  provisioner "file" {
    source      = "./_etc_squid_squid.conf"
    destination = "/tmp/squid.conf"
  }
  provisioner "file" {
    source      = "./_etc_conf.d_squid"
    destination = "/tmp/conf.d_squid"
  }
  provisioner "shell" {
    inline = [
      "sudo mkdir -p /etc/squid/conf.d /var/log/squid /var/cache/squid",
      "sudo mv /tmp/squid.conf          /etc/squid/squid.conf",
      "sudo mv /tmp/conf.d_squid        /etc/conf.d/squid",
      "sudo chown -R squid:squid /var/log/squid /var/cache/squid",
      "sudo chown root:root /etc/squid/squid.conf /etc/conf.d/squid",
      "sudo rc-update add squid default",
    ]
  }

  # -- 4. proxy-net service (create+attach eth1, policy routing) ----------------
  provisioner "file" {
    source      = "./_etc_init.d_proxy-net"
    destination = "/tmp/init.d_proxy-net"
  }
  provisioner "file" {
    source      = "./_etc_conf.d_proxy-net"
    destination = "/tmp/conf.d_proxy-net"
  }
  provisioner "shell" {
    inline = [
      "sudo mv /tmp/init.d_proxy-net /etc/init.d/proxy-net",
      "sudo mv /tmp/conf.d_proxy-net /etc/conf.d/proxy-net",
      "sudo chown root:root /etc/init.d/proxy-net /etc/conf.d/proxy-net",
      "sudo chmod +x /etc/init.d/proxy-net",
      "sudo rc-update add proxy-net default",
    ]
  }

  # -- 5. nftables ruleset (INPUT filter: SSH/ICMP/9100 from VPC, 8080 on eth0) -
  # Replaces the base image's default ruleset (which drops inbound with no SSH
  # allow). Installed to /etc/nftables.nft, loaded by the nftables service.
  provisioner "file" {
    source      = "./_etc_nftables_fleetproxy.nft"
    destination = "/tmp/nftables.nft"
  }
  provisioner "shell" {
    inline = [
      "sudo mv /tmp/nftables.nft /etc/nftables.nft",
      "sudo chown root:root /etc/nftables.nft",
      "sudo nft -c -f /etc/nftables.nft",
    ]
  }

  # -- 6. Root shell profile (aliases + ENV) -----------------------------------
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

  # -- 7. Reset cloud state so the AMI re-bootstraps on every launch -----------
  # Without `tiny-cloud --bootstrap incomplete` the baked-in bootstrap marker
  # makes every launched instance report "already bootstrapped" and SKIP SSH
  # key injection -- so the LT KeyName is never installed and login fails.
  # Must be the LAST provisioner (Packer's own SSH session stays up; the reset
  # only affects the next boot).
  provisioner "shell" {
    inline = [
      "sudo tiny-cloud --bootstrap incomplete",
      "sudo rm -f /etc/hostname",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo sh -c 'truncate -s 0 /var/log/*.log 2>/dev/null || true'",
      "history -c || true",
    ]
  }
}
