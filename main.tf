terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "4.52.0"
    }
  }
  required_version = ">= 1.1.0"

  cloud {

    organization = "tech-challenge-fiap-fastfood"

    workspaces {
      name = "tech-challenge"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "Região da AWS"
  type        = string
  default     = "us-east-1"
}

variable "key_name" {
  description = "Nome da chave SSH usada para acessar a EC2"
  type        = string
  default     = "chave-ssh"
}

locals {
  project_name = "tech-challenge-terraform"
}

data "aws_ami" "ubuntu" { # Amazon Machine Image
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical (dona das imagens do Ubuntu)
}

data "aws_availability_zones" "available" {}

# Criando a VPC (Virtual Private Cloud)
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16" # Define o intervalo de IPs da VPC

  tags = {
    Name = "${local.project_name}-vpc"
  }
}

# Criando um Internet Gateway para acesso externo
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.project_name}-igw"
  }
}

# Criando uma tabela de rotas pública
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "${local.project_name}-route-table"
  }
}

# Criando a Subnet Pública
resource "aws_subnet" "main" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true # Permite IPs públicos automaticamente

  tags = {
    Name = "${local.project_name}-subnet"
  }
}

# Associando a Subnet à Tabela de Rotas
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.main.id
  route_table_id = aws_route_table.public.id
}

# Criando o Security Group (Firewall)
resource "aws_security_group" "web-sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Acessível para qualquer um
  }

  ingress {
    from_port   = 30001
    to_port     = 30001
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Acessível para qualquer um
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Permite SSH de qualquer lugar (para estudos, está ok)
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.project_name}-sg"
  }
}

# Criando a Instância EC2
resource "aws_instance" "app_server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.main.id
  vpc_security_group_ids = [aws_security_group.web-sg.id]
  key_name               = var.key_name

  tags = {
    Name = "${local.project_name}-server"
  }
}

# Criando um Elastic IP
resource "aws_eip" "elastic_ip" {
  instance = aws_instance.app_server.id
}

# Outputs (Resultados)
output "vpc_id" {
  description = "ID da VPC criada"
  value       = aws_vpc.main.id
}

output "elastic_ip" {
  description = "IP público fixo da instância EC2"
  value       = aws_eip.elastic_ip.public_ip
}

output "ssh_command" {
  description = "Comando para acessar a instância EC2 via SSH"
  value       = "ssh -i ${var.key_name}.pem ubuntu@${aws_eip.elastic_ip.public_ip}"
}

