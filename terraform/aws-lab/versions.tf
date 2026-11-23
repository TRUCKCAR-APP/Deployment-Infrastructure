# Infraestructura de AWS de TruckCar para el AWS Academy Learner Lab (overlay k8s/overlays/aws-eks-lab).
# Lo que va dentro del clúster sigue en Kustomize; aquí solo lo que vive en AWS.
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Estado en S3 con bloqueo nativo (use_lockfile, sin DynamoDB). El bucket lo crea scripts/terraform-bootstrap.sh y se
  # pasa al iniciar: terraform init -backend-config="bucket=truckcar-tfstate-<cuenta>"
  backend "s3" {
    key          = "aws-eks-lab/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project     = "truckcar"
      environment = "aws-eks-lab"
      managed-by  = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  # El laboratorio no permite crear roles de IAM: el clúster, los nodos y los pods (por las credenciales del nodo) usan
  # el LabRole que ya existe en la cuenta.
  lab_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/LabRole"
  azs          = ["${var.region}a", "${var.region}b"]
}
