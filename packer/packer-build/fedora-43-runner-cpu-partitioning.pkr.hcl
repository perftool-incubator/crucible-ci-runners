packer {
  required_plugins {
    amazon = {
      version = ">= 1.2.8"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "ami_prefix" {
  type    = string
  default = "crucible-ci-fedora-43-runner-cpu-partitioning-nohz1-3"
}

variable "instance_type" {
  type    = string
  default = "m5.2xlarge"
}

# Get the latest Fedora 43 AMI
data "amazon-ami" "fedora_43" {
  filters = {
    name                = "Fedora-Cloud-Base-AmazonEC2.x86_64-43-*"
    root-device-type    = "ebs"
    virtualization-type = "hvm"
  }
  most_recent = true
  owners      = ["125523088429"] # Fedora project
  region      = var.region
}

source "amazon-ebs" "fedora_runner_cpu_partitioning" {
  ami_name      = "${var.ami_prefix}-${formatdate("YYYY-MM-DD-hhmm", timestamp())}"
  instance_type = var.instance_type
  region        = var.region
  source_ami    = data.amazon-ami.fedora_43.id
  ssh_username  = "fedora"

  # Use existing VPC and public subnet
  vpc_id    = "vpc-09ace6ee53d7b69c7"
  subnet_id = "subnet-0762d5806c615b70d"  # Public subnet in us-east-1a

  # Enable public IP for SSH access
  associate_public_ip_address = true

  tags = {
    Name        = "${var.ami_prefix}"
    Project     = "crucible-ci"
    BaseAMI     = data.amazon-ami.fedora_43.id
    BuildDate   = formatdate("YYYY-MM-DD", timestamp())
    OS          = "Fedora 43"
    Purpose     = "GitHub Actions Runner - CPU Partitioning"
  }

  launch_block_device_mappings {
    device_name = "/dev/sda1"
    volume_size = 20
    volume_type = "gp3"
    delete_on_termination = true
  }
}

build {
  sources = ["source.amazon-ebs.fedora_runner_cpu_partitioning"]

  # Wait for cloud-init to finish
  provisioner "shell" {
    inline = [
      "echo 'Waiting for cloud-init to complete...'",
      "cloud-init status --wait || true",
      "echo 'Cloud-init completed'"
    ]
  }

  # Install required packages and configure system
  provisioner "shell" {
    inline = [
      "set -e",
      "echo 'Installing required packages for crucible-ci workflows...'",

      # Update package metadata
      "sudo dnf check-update || true",

      # Install required packages (podman and curl are already installed)
      "sudo dnf install -y git wget jq tar gzip buildah",

      # Install AWS SSM Agent for remote access
      "echo 'Installing AWS SSM Agent...'",
      "sudo dnf install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm",
      "sudo systemctl enable amazon-ssm-agent",
      "sudo systemctl start amazon-ssm-agent",
      "sudo systemctl status amazon-ssm-agent --no-pager || true",

      # Verify podman is installed
      "podman --version",

      # Create docker compatibility symlinks
      "echo 'Creating docker compatibility symlinks for podman...'",
      "sudo ln -sf /usr/bin/podman /usr/bin/docker",
      "sudo ln -sf /usr/bin/podman /usr/bin/dockerd",

      # Verify docker symlink works
      "docker --version",

      # Create ec2-user compatibility (terraform module expects ec2-user)
      "echo 'Creating ec2-user compatibility for terraform module...'",
      "sudo useradd -m -s /bin/bash ec2-user || true",
      "echo 'fedora ALL=(ALL) NOPASSWD:ALL' | sudo tee -a /etc/sudoers.d/fedora",
      "echo 'ec2-user ALL=(ALL) NOPASSWD:ALL' | sudo tee -a /etc/sudoers.d/ec2-user",

      # Create docker group and add both users
      "sudo groupadd docker || true",
      "sudo usermod -aG docker fedora || true",
      "sudo usermod -aG docker ec2-user || true",

      # Configure SSH for root localhost access
      "echo 'Configuring SSH for root localhost access...'",
      # Enable root login via SSH
      "sudo sed -i 's/^#\\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config",
      # Generate SSH key for root if it doesn't exist
      "sudo mkdir -p /root/.ssh",
      "sudo chmod 700 /root/.ssh",
      "sudo ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N '' -q || true",
      # Add root's public key to authorized_keys
      "sudo cat /root/.ssh/id_rsa.pub | sudo tee -a /root/.ssh/authorized_keys",
      "sudo chmod 600 /root/.ssh/authorized_keys",
      # Configure SSH client for localhost (no host key checking)
      "echo 'Host localhost' | sudo tee /root/.ssh/config",
      "echo '  StrictHostKeyChecking no' | sudo tee -a /root/.ssh/config",
      "echo '  UserKnownHostsFile /dev/null' | sudo tee -a /root/.ssh/config",
      "sudo chmod 600 /root/.ssh/config",
      # Ensure sshd is enabled
      "sudo systemctl enable sshd",
      "sudo systemctl restart sshd",
      "echo 'SSH configuration complete'",

      # Configure kernel parameters for CPU isolation
      "echo 'Configuring kernel parameters for CPU isolation...'",

      # Step 1: Update /etc/default/grub for future kernel updates
      "sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=\"\\(.*\\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\\1 nohz=on nohz_full=1-3\"/' /etc/default/grub",
      "echo 'Updated /etc/default/grub:'",
      "grep GRUB_CMDLINE_LINUX /etc/default/grub",

      # Step 2: Regenerate grub configuration (do this before grubby)
      "sudo grub2-mkconfig -o /boot/grub2/grub.cfg",

      # Step 3: Use grubby to update BLS entries (these override grub.cfg on Fedora)
      "DEFAULT_KERNEL=$(sudo grubby --default-kernel)",
      "echo 'Default kernel: '$DEFAULT_KERNEL",
      "echo 'Updating ALL kernels with grubby...'",
      "sudo grubby --update-kernel=ALL --args='nohz=on nohz_full=1-3'",

      # Verify the changes
      "echo 'Verifying kernel parameters in grubby:'",
      "sudo grubby --info=$DEFAULT_KERNEL | grep args",
      "echo 'Verifying BLS entries:'",
      "sudo ls -la /boot/loader/entries/ || echo 'BLS directory not found'",
      "sudo cat /boot/loader/entries/*.conf 2>/dev/null | grep -E '^options' | head -3 || echo 'No BLS conf files found'",

      # Install K3s (lightweight Kubernetes)
      "echo 'Installing K3s...'",
      "curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_START=true INSTALL_K3S_SKIP_ENABLE=true sh -",
      "echo 'K3s installed, checking version:'",
      "K3S_VERSION=$(k3s --version | head -1 | awk '{print $3}')",
      "echo \"K3s version: $${K3S_VERSION}\"",

      # Pre-download K3s airgap images to avoid Docker Hub pulls at runtime
      "echo 'Downloading K3s airgap images...'",
      "sudo mkdir -p /var/lib/rancher/k3s/agent/images/",
      "curl -sfL \"https://github.com/k3s-io/k3s/releases/download/$${K3S_VERSION}/k3s-airgap-images-amd64.tar.zst\" -o /tmp/k3s-airgap-images.tar.zst || curl -sfL \"https://github.com/k3s-io/k3s/releases/download/$${K3S_VERSION}/k3s-airgap-images-amd64.tar.gz\" -o /tmp/k3s-airgap-images.tar.gz",
      "if [ -f /tmp/k3s-airgap-images.tar.zst ]; then sudo mv /tmp/k3s-airgap-images.tar.zst /var/lib/rancher/k3s/agent/images/; elif [ -f /tmp/k3s-airgap-images.tar.gz ]; then sudo mv /tmp/k3s-airgap-images.tar.gz /var/lib/rancher/k3s/agent/images/; fi",
      "echo 'K3s airgap images installed'",
      "ls -la /var/lib/rancher/k3s/agent/images/",
      "echo 'K3s installation complete (service disabled for AMI)'",

      # Create minimal dummy amazon-cloudwatch-agent RPM
      "echo 'Creating dummy amazon-cloudwatch-agent package...'",
      "sudo dnf install -y rpm-build",
      # Create dummy binary first
      "sudo mkdir -p /usr/bin",
      "echo '#!/bin/bash' | sudo tee /usr/bin/amazon-cloudwatch-agent",
      "echo 'exit 0' | sudo tee -a /usr/bin/amazon-cloudwatch-agent",
      "sudo chmod +x /usr/bin/amazon-cloudwatch-agent",
      # Build a minimal RPM using fpm (easier than rpmbuild)
      "sudo dnf install -y ruby rubygems ruby-devel gcc make",
      "sudo gem install --no-document fpm",
      "cd /tmp",
      "fpm -s dir -t rpm -n amazon-cloudwatch-agent -v 1.0.0 --iteration 1 --description 'Dummy CloudWatch Agent' --license MIT /usr/bin/amazon-cloudwatch-agent",
      "sudo rpm -ivh amazon-cloudwatch-agent-*.rpm",
      "rm -f amazon-cloudwatch-agent-*.rpm",

      # Install libicu (required by GitHub Actions runner on non-Ubuntu)
      "sudo dnf install -y libicu",

      # Pre-install GitHub Actions runner binary
      "echo 'Installing GitHub Actions runner...'",
      "sudo mkdir -p /opt/actions-runner",
      "sudo mkdir -p /opt/hostedtoolcache",
      "cd /opt/actions-runner",
      "RUNNER_VERSION=$(curl -s https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name' | sed 's/v//')",
      "echo \"Downloading runner version $RUNNER_VERSION\"",
      "sudo curl -sL -o actions-runner.tar.gz https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-linux-x64-$RUNNER_VERSION.tar.gz",
      "sudo tar xzf actions-runner.tar.gz",
      "sudo rm -f actions-runner.tar.gz",
      "sudo chown -R fedora:fedora /opt/actions-runner /opt/hostedtoolcache",
      "echo \"GitHub Actions runner $RUNNER_VERSION installed\"",

      # Run dnf upgrade-minimal now so it doesn't run at boot time
      "echo 'Running dnf upgrade-minimal (so boot is faster)...'",
      "sudo dnf upgrade-minimal -y || true",

      # Print installed versions
      "echo 'Installed software versions:'",
      "podman --version",
      "git --version",
      "wget --version | head -1",
      "curl --version | head -1",
      "jq --version",
      "echo 'Docker (podman symlink):' && docker --version",

      # Verify root can SSH to localhost
      "echo 'Verifying root SSH to localhost...'",
      "sudo ssh -o BatchMode=yes -o ConnectTimeout=5 root@localhost 'echo Root SSH to localhost works!' || echo 'Warning: Root SSH verification failed'",

      "echo 'AMI preparation complete!'"
    ]
  }

  # Clean up for AMI creation
  provisioner "shell" {
    inline = [
      "echo 'Cleaning up before AMI creation...'",

      # Clean dnf cache
      "sudo dnf clean all",

      # Remove SSH host keys (will be regenerated on first boot)
      "sudo rm -f /etc/ssh/ssh_host_*",

      # Clear cloud-init data (will be re-initialized on first boot)
      "sudo cloud-init clean --logs --seed",

      # Clear bash history
      "history -c",
      "cat /dev/null > ~/.bash_history",

      "echo 'Cleanup complete!'"
    ]
  }

  post-processor "manifest" {
    output = "packer-manifest-cpu-partitioning.json"
    strip_path = true
  }
}
