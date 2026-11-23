#!/usr/bin/env bash
# Crea (una sola vez por cuenta) el bucket S3 donde Terraform guarda el estado de terraform/aws-lab, e inicializa
# Terraform con él. Seguro de repetir: si el bucket ya existe, solo inicializa.
#
#   bash scripts/terraform-bootstrap.sh
#
# Requiere credenciales de AWS vigentes (en el Learner Lab: Start Lab y copiar "AWS Details" a ~/.aws/credentials).
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)" \
  || { echo "ERROR: credenciales de AWS no válidas o vencidas" >&2; exit 1; }
BUCKET="truckcar-tfstate-${ACCOUNT}"
DIR="$(cd "$(dirname "$0")/../terraform/aws-lab" && pwd)"

if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "Bucket de estado: $BUCKET (ya existe)"
else
  echo "Creando el bucket de estado $BUCKET"
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  fi
  # Versionado: se puede volver a un estado anterior si algo sale mal.
  aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption --bucket "$BUCKET" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-tagging --bucket "$BUCKET" \
    --tagging 'TagSet=[{Key=project,Value=truckcar},{Key=managed-by,Value=terraform-bootstrap}]'
fi

terraform -chdir="$DIR" init -input=false -backend-config="bucket=${BUCKET}" -backend-config="region=${REGION}"
