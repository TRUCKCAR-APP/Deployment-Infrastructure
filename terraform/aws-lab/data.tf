# Datos fuera del clúster: PostgreSQL (RDS), evidencias y audio (S3) y notificaciones push (SNS).

resource "aws_db_subnet_group" "main" {
  name       = "truckcar-lab-db"
  subnet_ids = aws_subnet.private[*].id
}

# 5432 solo desde la VPC (los pods llegan por PgBouncer); nunca desde Internet.
resource "aws_security_group" "rds" {
  name        = "truckcar-lab-rds"
  description = "PostgreSQL de TruckCar: 5432 solo desde la VPC del cluster"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "PostgreSQL desde la VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Sin restricciones de salida"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "main" {
  identifier     = "truckcar-lab"
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.rds_instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "truckcar_db"
  username = "truckcar_admin"
  password = var.db_admin_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = var.rds_multi_az

  backup_retention_period = var.rds_backup_retention_days
  backup_window           = "07:00-08:00"
  maintenance_window      = "sun:08:30-sun:09:30"

  auto_minor_version_upgrade = true
  apply_immediately          = true
  # Laboratorio: se puede destruir sin snapshot final ni protección. En producción, ambos al revés.
  deletion_protection = false
  skip_final_snapshot = true
}

resource "random_id" "bucket_suffix" {
  byte_length = 3
}

resource "aws_s3_bucket" "media" {
  for_each = toset(["pod-media", "voice"])

  bucket        = "truckcar-lab-${each.key}-${random_id.bucket_suffix.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "media" {
  for_each = aws_s3_bucket.media

  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "media" {
  for_each = aws_s3_bucket.media

  bucket = each.value.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "media" {
  for_each = aws_s3_bucket.media

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_sns_topic" "notifications" {
  name = "truckcar-notifications"
}
