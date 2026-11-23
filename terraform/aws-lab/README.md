# Terraform: infraestructura de AWS del Learner Lab

Crea en AWS lo que necesita el overlay `k8s/overlays/aws-eks-lab`. Lo que corre dentro del clúster sigue en Kustomize.

| Recurso | Detalle |
|---|---|
| VPC `192.168.0.0/16` | 2 zonas; subredes públicas (ALB, NAT) y privadas (nodos, RDS); un NAT gateway |
| EKS `truckcar-cluster` | Kubernetes 1.36 con el LabRole, `vpc-cni` con NetworkPolicy, `coredns`, `kube-proxy`, `aws-ebs-csi-driver`, `metrics-server` |
| Nodos | 2 × `t3.large` en subredes privadas, IMDSv2 con 2 saltos (los pods usan las credenciales del nodo) |
| RDS | PostgreSQL 16, `db.t3.small`, cifrado, solo desde la VPC, **copias de seguridad de 7 días** |
| S3 | Buckets privados y cifrados de evidencias (`pod-media`) y audio (`voice`) |
| SNS | Tema `truckcar-notifications` |
| ECR | Los 11 repositorios `truckcar/*` (se adoptan con `import`; conservan las imágenes) |

**Restricciones del Learner Lab:** no se crean roles de IAM ni OIDC (todo usa el `LabRole`), sin CloudFront, y las
credenciales vencen en cada sesión.

## Uso

```bash
# Credenciales del laboratorio en ~/.aws/credentials (Start Lab → AWS Details).
set -a; . ./.env; set +a
export TF_VAR_db_admin_password="$TRUCKCAR_DB_ADMIN_PASSWORD"

bash scripts/terraform-bootstrap.sh            # una vez: bucket del estado + terraform init
terraform -chdir=terraform/aws-lab plan -out=tfplan
terraform -chdir=terraform/aws-lab apply tfplan # ~20 min (EKS)
terraform -chdir=terraform/aws-lab output       # valores para k8s/overlays/lab-local
```

Después, lo de dentro del clúster: `$(terraform -chdir=terraform/aws-lab output -raw kubeconfig_command)`, el AWS
Load Balancer Controller con `vpcId` de la salida, el Secret `truckcar-secrets` y el overlay (ver `k8s/README.md`).

**Cambios comunes:** RDS en dos zonas con `-var rds_multi_az=true`; más nodos con `-var node_count=3` (y una zona más
en `locals.azs`).

**Desmontar:** primero lo de dentro del clúster (Ingress y PVC, para que AWS borre el ALB y los discos), luego
`terraform -chdir=terraform/aws-lab destroy`. Los repositorios ECR tienen `prevent_destroy`: para borrarlos de verdad,
quíteselo o sáquelos del estado con `terraform state rm`.
