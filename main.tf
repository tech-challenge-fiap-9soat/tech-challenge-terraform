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
  subnet_id              = aws_subnet.main.id
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

    # Comandos iptables
    # Verificar se a regra de DNAT já existe
    if ! sudo iptables -t nat -C PREROUTING -p tcp --dport 30001 -j DNAT --to-destination 172.18.0.2:30001; then
      sudo iptables -t nat -A PREROUTING -p tcp --dport 30001 -j DNAT --to-destination 172.18.0.2:30001
    fi

    # Verificar se a regra de ACCEPT já existe
    if ! sudo iptables -C FORWARD -p tcp --dport 30001 -j ACCEPT; then
      sudo iptables -A FORWARD -p tcp --dport 30001 -j ACCEPT
    fi

    # Instalar iptables-persistent para salvar regras
    if ! dpkg -l | grep -q iptables-persistent; then
      sudo apt-get install -y iptables-persistent
    fi

    # Aguardar para garantir que os serviços estejam prontos
    sleep 10

    # Garantir que o serviço netfilter-persistent esteja ativo
    sudo systemctl start netfilter-persistent

    # Salvar regras e garantir que elas sejam aplicadas após o reboot
    sudo netfilter-persistent save
    sudo systemctl enable netfilter-persistent
    sudo systemctl restart netfilter-persistent

    echo "✅ Setup finalizado!"
  EOF

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