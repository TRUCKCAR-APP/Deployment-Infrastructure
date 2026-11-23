variable "region" {
  description = "Región de AWS (el Learner Lab solo permite us-east-1 y us-west-2)."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Nombre del clúster EKS."
  type        = string
  default     = "truckcar-cluster"
}

variable "kubernetes_version" {
  description = "Versión de Kubernetes del clúster."
  type        = string
  default     = "1.36"
}

variable "vpc_cidr" {
  description = "CIDR de la VPC. 192.168.0.0/16 es el que esperan k8s/overlays/aws-eks-lab/network-policies.yaml y TRUCKCAR_GATEWAY_TRUSTED_SOURCE_CIDRS."
  type        = string
  default     = "192.168.0.0/16"
}

variable "node_instance_type" {
  description = "Tipo de nodo. t3.large: 35 pods y 8 GiB por nodo (en t3.medium no caben las JVM)."
  type        = string
  default     = "t3.large"
}

variable "node_count" {
  description = "Nodos del clúster, uno por zona."
  type        = number
  default     = 2
}

variable "db_admin_password" {
  description = "Contraseña del usuario truckcar_admin de RDS (TRUCKCAR_DB_ADMIN_PASSWORD del .env, por TF_VAR_db_admin_password)."
  type        = string
  sensitive   = true
}

variable "rds_instance_class" {
  description = "Clase de la instancia RDS."
  type        = string
  default     = "db.t3.small"
}

variable "rds_multi_az" {
  description = "RDS en dos zonas (réplica en espera). Duplica el costo; en producción, true."
  type        = bool
  default     = false
}

variable "rds_backup_retention_days" {
  description = "Días de copias de seguridad automáticas de RDS (0 las desactiva)."
  type        = number
  default     = 7
}
