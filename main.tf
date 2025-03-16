terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "4.52.0"
    }
  }
  required_version = ">= 1.1.0"
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "Região da AWS"
  type        = string
  default     = "us-east-1"
}

locals {
  project_name = "tech-challenge-terraform"
}

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

data "aws_availability_zones" "available" {}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16" # Define o intervalo de IPs da VPC

  tags = {
    Name = "${local.project_name}-vpc"
  }
}

resource "aws_subnet" "main" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.project_name}-subnet"
  }
}

resource "aws_security_group" "web-sg" {
  vpc_id = aws_vpc.main.id
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Acessível para qualquer um
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "app_server" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.main.id # Coloca a instância dentro da subnet
  security_groups = [aws_security_group.web-sg.id]  # Aplica regras de firewall

  tags = {
    Name = "${local.project_name}-server"
  }
}

resource "aws_eip" "elastic_ip" {
  instance = aws_instance.app_server.id
}

output "vpc_id" {
  description = "ID da VPC criada"
  value       = aws_vpc.main.id
}

output "elastic_ip" {
  description = "IP público fixo da instância EC2"
  value       = aws_eip.elastic_ip.public_ip
}