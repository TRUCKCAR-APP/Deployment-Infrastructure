# Valores que necesita el overlay local (k8s/overlays/lab-local) y el AWS Load Balancer Controller.
output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.main.name}"
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "vpc_cidr" {
  value = aws_vpc.main.cidr_block
}

output "rds_address" {
  description = "POSTGRES_HOST del overlay."
  value       = aws_db_instance.main.address
}

output "pod_media_bucket" {
  description = "TRUCKCAR_S3_BUCKET (evidencias de entrega)."
  value       = terraform_data.bucket["pod-media"].output
}

output "voice_bucket" {
  description = "AWS_S3_BUCKET de notifications (audio de voz)."
  value       = terraform_data.bucket["voice"].output
}

output "sns_topic_arn" {
  description = "AWS_SNS_TOPIC_ARN de notifications."
  value       = aws_sns_topic.notifications.arn
}

output "ecr_registry" {
  value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}
