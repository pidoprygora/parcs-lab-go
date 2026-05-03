terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    # "al2023-ami-2023*" matches the standard AMI with SSM Agent pre-installed.
    # Excludes "al2023-ami-minimal-*" which is a stripped image without SSM Agent.
    values = ["al2023-ami-2023*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ---------------------------------------------------------------------------
# IAM
# ---------------------------------------------------------------------------

resource "aws_iam_role" "parcs_ec2" {
  name = "parcs-lab-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.parcs_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "read_github_token" {
  name = "parcs-lab-read-github-token"
  role = aws_iam_role.parcs_ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter${var.github_token_ssm_path}"
      },
      {
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "parcs_ec2" {
  name = "parcs-lab-ec2-profile"
  role = aws_iam_role.parcs_ec2.name
}

# ---------------------------------------------------------------------------
# Security Group — no inbound, all outbound allowed
# Inbound is fully closed (no SSH, no exposed ports).
# Outbound must be unrestricted so the SSM agent can resolve DNS (port 53),
# pull Docker images (port 443), and download packages (port 80/443).
# ---------------------------------------------------------------------------

resource "aws_security_group" "parcs_ec2" {
  name        = "parcs-lab-ec2-sg"
  description = "PARCS lab EC2: no inbound, all outbound for SSM, DNS, Docker, dnf"

  egress {
    description = "Allow all outbound traffic (DNS, HTTPS, HTTP)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------------------------------------------------------------------------
# EC2 Instance
# ---------------------------------------------------------------------------

locals {
  user_data = <<-EOT
    #!/bin/bash
    set -euxo pipefail

    # Ensure SSM Agent is installed and running (pre-installed on standard AL2023)
    dnf install -y amazon-ssm-agent || true
    systemctl enable --now amazon-ssm-agent

    # Install Docker and Git
    dnf install -y docker git
    systemctl enable --now docker

    # Init Docker Swarm (single-node)
    docker swarm init

    # Create PARCS overlay network
    docker network create -d overlay parcs

    # Start docker-proxy: exposes Docker socket via TCP 4321 for PARCS runner
    docker service create \
      --name docker-proxy \
      --network parcs \
      --restart-condition any \
      --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
      alpine/socat tcp-listen:4321,fork,reuseaddr unix-connect:/var/run/docker.sock

    # Fetch GitHub token from SSM Parameter Store and clone the repo
    TOKEN=$(aws ssm get-parameter \
      --region ${var.aws_region} \
      --name "${var.github_token_ssm_path}" \
      --with-decryption \
      --query "Parameter.Value" \
      --output text)

    REPO_URL_WITH_TOKEN=$(echo "${var.repo_url}" | sed "s|https://|https://$TOKEN@|")
    git clone "$REPO_URL_WITH_TOKEN" /home/ec2-user/parcs-lab-go
    chown -R ec2-user:ec2-user /home/ec2-user/parcs-lab-go

    echo "PARCS infrastructure ready" >> /var/log/parcs-setup.log
  EOT
}

resource "aws_instance" "parcs_ec2" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  iam_instance_profile        = aws_iam_instance_profile.parcs_ec2.name
  vpc_security_group_ids      = [aws_security_group.parcs_ec2.id]
  associate_public_ip_address = true

  user_data                   = local.user_data
  user_data_replace_on_change = true

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = {
    Name    = "parcs-lab"
    Project = "parcs-lab-go"
  }
}
