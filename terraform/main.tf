terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {}
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used for tagging and naming"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "public_key" {
  description = "SSH public key for EC2 key pair"
  type        = string
}

# ---------------------------------------------------------------------------
# Provider
# ---------------------------------------------------------------------------

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "udap"
    }
  }
}

# ---------------------------------------------------------------------------
# VPC  – adopt the account's default VPC instead of creating a new one.
# aws_default_vpc manages an EXISTING resource; it never creates a new VPC
# and therefore does not count against the 5-VPC-per-region quota.
# ---------------------------------------------------------------------------

resource "aws_default_vpc" "main" {
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-default-vpc"
  }
}

# ---------------------------------------------------------------------------
# Availability zones
# ---------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

# ---------------------------------------------------------------------------
# Public Subnets – adopt the default VPC's existing default subnets.
# aws_default_subnet never creates a new subnet; it manages the one that
# already exists in the given AZ inside the default VPC.
# ---------------------------------------------------------------------------

resource "aws_default_subnet" "public" {
  count             = 2
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${var.project_name}-public-${count.index}"
  }
}

# ---------------------------------------------------------------------------
# Security Groups
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Allow HTTP inbound to ALB"
  vpc_id      = aws_default_vpc.main.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-alb-sg"
  }
}

resource "aws_security_group" "app" {
  name        = "${var.project_name}-app-sg"
  description = "Allow traffic from ALB to app"
  vpc_id      = aws_default_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-app-sg"
  }
}

# Break the potential cycle by using standalone rules
resource "aws_security_group_rule" "app_ingress_from_alb" {
  type                     = "ingress"
  from_port                = 8000
  to_port                  = 8000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.app.id
  source_security_group_id = aws_security_group.alb.id
  description              = "Allow port 8000 from ALB SG"
}

# ---------------------------------------------------------------------------
# Security Group for VPC Endpoints
# Allows HTTPS (443) from the app instance security group into the
# interface endpoints so the SSM agent can communicate privately.
# ---------------------------------------------------------------------------

resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.project_name}-vpce-sg"
  description = "Allow HTTPS from app instances to VPC endpoints"
  vpc_id      = aws_default_vpc.main.id

  ingress {
    description     = "HTTPS from app SG"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-vpce-sg"
  }
}

# ---------------------------------------------------------------------------
# VPC Interface Endpoints for SSM
# These three endpoints are the minimum required for AWS Systems Manager
# Session Manager to function without internet access:
#   ssm          – control plane / agent registration
#   ssmmessages  – Session Manager data channel
#   ec2messages  – Run Command / Systems Manager messages
# private_dns_enabled = true rewrites the public DNS names to the private
# IPs so the SSM agent uses the endpoint automatically.
# ---------------------------------------------------------------------------

resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = aws_default_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_default_subnet.public[0].id]
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.project_name}-vpce-ssm"
  }
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = aws_default_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_default_subnet.public[0].id]
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.project_name}-vpce-ssmmessages"
  }
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = aws_default_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_default_subnet.public[0].id]
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.project_name}-vpce-ec2messages"
  }
}

# ---------------------------------------------------------------------------
# S3 Gateway Endpoint
# Allows the instance and the Ansible aws_ssm connection plugin to reach
# S3 (SSM session output bucket + apt package mirrors) without internet.
# Gateway endpoints are free and work by adding a route to the VPC
# route tables.
# ---------------------------------------------------------------------------

data "aws_route_tables" "default_vpc" {
  vpc_id = aws_default_vpc.main.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_default_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = data.aws_route_tables.default_vpc.ids

  tags = {
    Name = "${var.project_name}-vpce-s3"
  }
}

# ---------------------------------------------------------------------------
# IAM Role for SSM
# ---------------------------------------------------------------------------

resource "aws_iam_role" "ssm" {
  name = "${var.project_name}-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-ssm-role"
  }
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ssm_s3" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "${var.project_name}-ssm-profile"
  role = aws_iam_role.ssm.name
}

# ---------------------------------------------------------------------------
# SSM S3 Bucket for Ansible aws_ssm connection plugin
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "ssm" {
  bucket        = "${var.project_name}-ssm-ansible"
  force_destroy = true

  tags = {
    Name = "${var.project_name}-ssm-ansible"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "ssm" {
  bucket = aws_s3_bucket.ssm.id

  rule {
    id     = "expire-ssm-files"
    status = "Enabled"

    expiration {
      days = 1
    }

    filter {}
  }
}

# ---------------------------------------------------------------------------
# AMI (Ubuntu 24.04 LTS)
# ---------------------------------------------------------------------------

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd*/ubuntu-*-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ---------------------------------------------------------------------------
# Key Pair
# ---------------------------------------------------------------------------

resource "aws_key_pair" "app" {
  key_name   = "${var.project_name}-keypair"
  public_key = var.public_key

  tags = {
    Name = "${var.project_name}-keypair"
  }
}

# ---------------------------------------------------------------------------
# EC2 Instance
# Placed in a default subnet with no public IP assigned – the instance is
# not directly reachable from the internet.  Ansible connects exclusively
# via AWS SSM Session Manager using the VPC interface endpoints above
# (no NAT gateway or public IP required).
# depends_on ensures the VPC endpoints are in place before the instance
# boots so the SSM agent can register on its very first start.
# ---------------------------------------------------------------------------

resource "aws_instance" "app" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_default_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.ssm.name
  key_name                    = aws_key_pair.app.key_name
  associate_public_ip_address = false

  user_data = <<-EOF
    #!/bin/bash
    set -e
    snap install amazon-ssm-agent --classic || true
    systemctl enable amazon-ssm-agent
    systemctl start amazon-ssm-agent
  EOF

  # Ensure VPC endpoints exist before the instance boots so the SSM agent
  # can register immediately on first start.
  depends_on = [
    aws_vpc_endpoint.ssm,
    aws_vpc_endpoint.ssmmessages,
    aws_vpc_endpoint.ec2messages,
    aws_vpc_endpoint.s3,
  ]

  tags = {
    Name    = "${var.project_name}-app"
    Project = var.project_name
  }
}

# ---------------------------------------------------------------------------
# Application Load Balancer
# ---------------------------------------------------------------------------

resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_default_subnet.public[0].id, aws_default_subnet.public[1].id]

  tags = {
    Name = "${var.project_name}-alb"
  }
}

resource "aws_lb_target_group" "app" {
  name        = "${var.project_name}-tg"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = aws_default_vpc.main.id
  target_type = "instance"

  health_check {
    path                = "/health/"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200-399"
  }

  tags = {
    Name = "${var.project_name}-tg"
  }
}

resource "aws_lb_target_group_attachment" "app" {
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.app.id
  port             = 8000
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "alb_dns_name" {
  description = "Public DNS name of the Application Load Balancer"
  value       = aws_lb.main.dns_name
}

output "app_url" {
  description = "Application URL via ALB"
  value       = "http://${aws_lb.main.dns_name}"
}

output "instance_id" {
  description = "EC2 instance ID (for SSM)"
  value       = aws_instance.app.id
}

output "ssm_bucket" {
  description = "S3 bucket used by Ansible aws_ssm connection plugin"
  value       = aws_s3_bucket.ssm.bucket
}
