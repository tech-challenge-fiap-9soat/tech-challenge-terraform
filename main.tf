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

variable "existing_vpc_id" {
  description = "ID da VPC existente (deixe vazio para criar uma nova)"
  type        = string
  default     = "vpc-0aac8157501ffc23c" # Se vazio, criará uma nova VPC
}

variable "existing_subnet_id" {
  description = "ID da subnet existente"
  type        = string
  default     = "subnet-0f849d165103ae570"
}

locals {
  project_name = "tech-challenge-terraform"
}

# Se a VPC já existe, busca a VPC existente
data "aws_vpc" "existing" {
  count = var.existing_vpc_id != "" ? 1 : 0
  id    = var.existing_vpc_id
}

# Se a VPC não existe, cria uma nova
resource "aws_vpc" "this" {
  count      = var.existing_vpc_id == "" ? 1 : 0
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "${local.project_name}-vpc"
  }
}

# Definição do ID da VPC, seja existente ou criada
locals {
  vpc_id = var.existing_vpc_id != "" ? data.aws_vpc.existing[0].id : aws_vpc.this[0].id
}

data "aws_availability_zones" "available" {}

data "aws_subnet" "existing" {
  id = var.existing_subnet_id # Substitua pelo ID da subnet existente
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

# Criando um Security Group (Firewall)
resource "aws_security_group" "web-sg" {
  vpc_id = local.vpc_id

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Acessível para qualquer IPv4
  }

  ingress {
    from_port        = 30001
    to_port          = 30001
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"] # Acessível para qualquer IPv4
    ipv6_cidr_blocks = ["::/0"]      # Acessível para qualquer IPv6
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Permite SSH de qualquer IPv4
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
  instance_type          = "t2.medium"
  subnet_id              = data.aws_subnet.existing.id
  vpc_security_group_ids = [aws_security_group.web-sg.id]
  key_name               = var.key_name

  user_data = <<-EOF
    #!/bin/bash
    set -e

    echo "🚀 Verificando pacotes na EC2..."

    # Atualiza pacotes apenas se necessário
    sudo apt update -y && sudo apt upgrade -y

    # Instalar Docker se não estiver instalado
    if ! command -v docker &> /dev/null; then
      echo "⚙️ Instalando Docker..."
      sudo apt install -y docker.io
      sudo systemctl enable docker
      sudo systemctl start docker
      sudo usermod -aG docker ubuntu
    else
      echo "✅ Docker já instalado"
    fi

    # Instalar kubectl se não estiver instalado
    if ! command -v kubectl &> /dev/null; then
      echo "⚙️ Instalando kubectl..."
      KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
      curl -LO "https://dl.k8s.io/release/$${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
      curl -LO "https://dl.k8s.io/$${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256"
      echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check || exit 1
      chmod +x kubectl
      sudo mv kubectl /usr/local/bin/
      rm -f kubectl.sha256
    else
      echo "✅ kubectl já instalado"
    fi

    # Instalar Kind apenas se não estiver instalado
    if ! command -v kind &> /dev/null; then
      echo "⚙️ Instalando Kind..."
      curl -Lo ./kind https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64
      chmod +x ./kind
      sudo mv ./kind /usr/local/bin/kind
    else
      echo "✅ Kind já instalado"
    fi

    echo "🚀 Criando script de configuração do iptables..."

    # Criar script no /etc/rc.local
    sudo bash -c 'cat <<EOT > /etc/rc.local
    #!/bin/bash
    iptables -t nat -A PREROUTING -p tcp --dport 30001 -j DNAT --to-destination 172.18.0.2:30001
    iptables -A FORWARD -p tcp --dport 30001 -j ACCEPT
    exit 0
    EOT'

    # Dar permissão de execução
    sudo chmod +x /etc/rc.local

    # Executa script
    sudo /etc/rc.local

    echo "✅ Script configurado para rodar no boot!"
    echo "✅ Setup finalizado!"
  EOF

  tags = {
    Name = "${local.project_name}-server"
  }
}

# Outputs (Resultados)
output "vpc_id" {
  description = "ID da VPC"
  value       = local.vpc_id
}

output "elastic_ip" {
  description = "IP público fixo da instância EC2"
  value       = aws_instance.app_server.public_ip
}

output "ssh_command" {
  description = "Comando para acessar a instância EC2 via SSH"
  value       = "ssh -i ${var.key_name}.pem ubuntu@${aws_instance.app_server.public_ip}"
}