# Repositorios de imágenes. Ya existían (los creó el CI) con las imágenes construidas: se adoptan con import en vez
# de recrearlos, para no tener que reconstruir y subir los 11 servicios.
locals {
  ecr_repositories = toset([
    "truckcar/api-gateway",
    "truckcar/user-identity",
    "truckcar/fleets-drivers",
    "truckcar/community-alerts",
    "truckcar/load-allocation",
    "truckcar/routing-restrictions",
    "truckcar/ai-fleet-allocation",
    "truckcar/route-ai-agent",
    "truckcar/notifications",
    "truckcar/voice-ai-assistant",
    "truckcar/truckcar-frontend",
  ])
}

import {
  for_each = local.ecr_repositories
  to       = aws_ecr_repository.service[each.key]
  id       = each.key
}

resource "aws_ecr_repository" "service" {
  for_each = local.ecr_repositories

  name = each.key
  # :main se sobrescribe en cada push a main (además de la etiqueta del commit).
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = false
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Conserva las 20 imágenes más recientes de cada servicio: el registro no crece sin límite.
resource "aws_ecr_lifecycle_policy" "service" {
  for_each = aws_ecr_repository.service

  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Conservar las 20 imagenes mas recientes"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 20
      }
      action = { type = "expire" }
    }]
  })
}
