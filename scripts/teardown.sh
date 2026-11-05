#!/usr/bin/env bash
# Desmonta TruckCar en Amazon EKS (overlay aws-eks-lab, AWS Academy Learner Lab) sin dejar recursos huérfanos que
# bloqueen la eliminación de la VPC. El orden importa:
#   1. Ingress: el AWS Load Balancer Controller borra el ALB y sus Security Groups. Si el clúster muere antes, el ALB
#      queda huérfano y la VPC no se puede borrar.
#   2. StatefulSets y PVCs: los discos EBS gp3 de Kafka, Redis y RabbitMQ (reclaimPolicy: Delete). Un PVC en uso no se
#      borra (pvc-protection), por eso antes se borran los StatefulSets que lo montan.
#   3. RDS dentro de la VPC del clúster: la instancia (sin snapshot final), su grupo de subredes y sus Security Groups.
#      Mientras existan, CloudFormation no puede borrar las subredes ni la VPC y eksctl falla al final.
#   4. Pausa para que las APIs de AWS terminen las eliminaciones en segundo plano.
#   5. eksctl delete cluster: nodegroups, clúster y el stack de CloudFormation de la VPC.
#   6. Informe de lo que queda y no se borra aquí: RDS fuera de la VPC, buckets S3, repositorios ECR y CloudFront.
#
# Uso:
#   scripts/teardown.sh --dry-run           muestra los pasos sin ejecutar nada
#   scripts/teardown.sh                     pide escribir el nombre del clúster para confirmar
#   scripts/teardown.sh --yes               sin confirmación (por ejemplo, en un pipeline)
# Variables: TRUCKCAR_CLUSTER_NAME (truckcar-cluster), AWS_REGION (us-east-1), TRUCKCAR_NAMESPACE (truckcar),
#            TRUCKCAR_TEARDOWN_TIMEOUT (segundos de espera por el ALB, los discos y los Security Groups; 300).
#            RDS se espera con el waiter de la CLI (hasta 30 min).
set -euo pipefail

CLUSTER="${TRUCKCAR_CLUSTER_NAME:-truckcar-cluster}"
REGION="${AWS_REGION:-us-east-1}"
NAMESPACE="${TRUCKCAR_NAMESPACE:-truckcar}"
TIMEOUT="${TRUCKCAR_TEARDOWN_TIMEOUT:-300}"
DRY_RUN=0
ASSUME_YES=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "Opción desconocida: $arg (use --dry-run, --yes o --help)" >&2; exit 2 ;;
  esac
done

step() { echo; echo "== $1"; }
info() { echo "   $1"; }
die()  { echo "ERROR: $1" >&2; exit 1; }

# Ejecuta el comando, o solo lo muestra con --dry-run.
run() {
  echo "   \$ $*"
  [ "$DRY_RUN" -eq 1 ] || "$@"
}

# ---------------------------------------------------------------- comprobaciones previas
step "Comprobaciones previas (clúster $CLUSTER, región $REGION, namespace $NAMESPACE)"
for tool in kubectl eksctl aws; do
  command -v "$tool" >/dev/null 2>&1 || die "falta '$tool' en el PATH"
done

# Las credenciales del Learner Lab vencen con la sesión: sin ellas el ALB no se puede comprobar ni el clúster borrar.
if ! ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"; then
  die "las credenciales de AWS no son válidas o vencieron (en el Learner Lab: Start Lab y copie de nuevo 'AWS Details')"
fi
info "Cuenta de AWS: $ACCOUNT"

if ! VPC_ID="$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
    --query cluster.resourcesVpcConfig.vpcId --output text 2>/dev/null)"; then
  die "el clúster '$CLUSTER' no existe en $REGION (defina TRUCKCAR_CLUSTER_NAME o AWS_REGION)"
fi
info "VPC del clúster: $VPC_ID"

# Instancias RDS cuyo grupo de subredes está en la VPC del clúster. Se descubren antes de borrar nada: con protección
# contra borrado el desmontaje no podría terminar, así que se aborta aquí sin tocar el clúster.
DB_INSTANCES="$(aws rds describe-db-instances --region "$REGION" \
  --query "DBInstances[?DBSubnetGroup.VpcId=='$VPC_ID'].DBInstanceIdentifier" --output text 2>/dev/null \
  | tr '\t' '\n' | grep -v '^$' || true)"
DB_SUBNET_GROUPS=""
DB_SECURITY_GROUPS=""
for db in $DB_INSTANCES; do
  # shellcheck disable=SC2016  # las comillas invertidas son literales de JMESPath, no sustitución del shell
  read -r protected subnet_group security_groups <<< "$(aws rds describe-db-instances --region "$REGION" \
    --db-instance-identifier "$db" --output text \
    --query 'DBInstances[0].[DeletionProtection,DBSubnetGroup.DBSubnetGroupName,join(`,`,VpcSecurityGroups[].VpcSecurityGroupId)]')"
  [ "$protected" = "True" ] && die "la instancia RDS '$db' tiene protección contra borrado: desactívela con
       aws rds modify-db-instance --region $REGION --db-instance-identifier $db --no-deletion-protection --apply-immediately"
  [ "$protected" = "False" ] || die "no se pudo leer la instancia RDS '$db' (aws rds describe-db-instances)"
  info "RDS en la VPC: $db (subredes: $subnet_group; Security Groups: $security_groups)"
  DB_SUBNET_GROUPS="$DB_SUBNET_GROUPS $subnet_group"
  DB_SECURITY_GROUPS="$DB_SECURITY_GROUPS ${security_groups//,/ }"
done

# kubectl debe apuntar a ESTE clúster: borrar el Ingress de otro contexto (minikube, AKS) sería un error grave.
CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
CONTEXT_CLUSTER="$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null || true)"
case "$CONTEXT_CLUSTER" in
  *":cluster/$CLUSTER"|"$CLUSTER"|"$CLUSTER.$REGION.eksctl.io") ;;
  *) die "kubectl apunta a '$CONTEXT' ($CONTEXT_CLUSTER), no a $CLUSTER. Ejecute:
       aws eks update-kubeconfig --name $CLUSTER --region $REGION" ;;
esac
info "kubectl: $CONTEXT"

if [ "$DRY_RUN" -eq 1 ]; then
  info "Modo --dry-run: se muestran los comandos, no se borra nada."
elif [ "$ASSUME_YES" -eq 0 ]; then
  echo
  echo "Se borrarán el Ingress (ALB), los discos EBS del namespace $NAMESPACE, las instancias RDS de la VPC del clúster"
  echo "(${DB_INSTANCES:-ninguna}, sin snapshot final) y el clúster EKS $CLUSTER."
  echo "Los datos de Kafka, Redis, RabbitMQ y PostgreSQL se pierden. S3 y ECR no se tocan."
  read -r -p "Escriba el nombre del clúster para continuar: " answer
  [ "$answer" = "$CLUSTER" ] || die "confirmación incorrecta: no se borró nada"
fi

# Balanceadores que el AWS Load Balancer Controller creó para este clúster (etiqueta elbv2.k8s.aws/cluster).
cluster_load_balancers() {
  local arns
  arns="$(aws elbv2 describe-load-balancers --region "$REGION" --query 'LoadBalancers[].LoadBalancerArn' \
    --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true)"
  [ -n "$arns" ] || return 0
  # describe-tags acepta hasta 20 ARN por llamada.
  echo "$arns" | xargs -n 20 aws elbv2 describe-tags --region "$REGION" --output text \
    --query "TagDescriptions[?Tags[?Key=='elbv2.k8s.aws/cluster' && Value=='$CLUSTER']].ResourceArn" \
    | tr '\t' '\n' | grep -v '^$' || true
}

# Discos EBS que el driver EBS CSI creó para los PVC del namespace.
namespace_volumes() {
  aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=tag:kubernetes.io/created-for/pvc/namespace,Values=$NAMESPACE" \
    --query 'Volumes[].VolumeId' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true
}

# Espera hasta TIMEOUT segundos a que la función $1 ya no devuelva nada.
wait_until_empty() {
  local what="$1" check="$2" waited=0 remaining
  [ "$DRY_RUN" -eq 1 ] && { info "(--dry-run) se esperaría a que no quede ningún $what"; return 0; }
  while remaining="$($check)"; [ -n "$remaining" ]; do
    if [ "$waited" -ge "$TIMEOUT" ]; then
      echo "   Siguen existiendo después de ${TIMEOUT}s:"
      while IFS= read -r item; do echo "     $item"; done <<< "$remaining"
      return 1
    fi
    sleep 10; waited=$((waited + 10))
    info "esperando $what (${waited}s)..."
  done
  info "sin $what pendientes"
}

# Borra un Security Group creado a mano para RDS. Se omiten el "default" de la VPC y los de CloudFormation (los del
# clúster, que borra eksctl). Reintenta: AWS libera la interfaz de red de RDS unos minutos después de borrar la instancia.
delete_security_group() {
  local sg="$1" waited=0 name stack
  # shellcheck disable=SC2016  # literales de JMESPath
  read -r name stack <<< "$(aws ec2 describe-security-groups --region "$REGION" --group-ids "$sg" --output text \
    --query 'SecurityGroups[0].[GroupName,length(Tags[?Key==`aws:cloudformation:stack-name`] || `[]`)]' 2>/dev/null)"
  if [ -z "$name" ]; then info "$sg ya no existe"; return 0; fi
  if [ "$name" = "default" ] || [ "${stack:-0}" != "0" ]; then info "se conserva $sg ($name): no es solo de RDS"; return 0; fi
  echo "   \$ aws ec2 delete-security-group --region $REGION --group-id $sg"
  [ "$DRY_RUN" -eq 1 ] && return 0
  until aws ec2 delete-security-group --region "$REGION" --group-id "$sg" 2>/dev/null; do
    [ "$waited" -ge "$TIMEOUT" ] && return 1
    sleep 10; waited=$((waited + 10))
    info "esperando a que AWS libere $sg (${waited}s)..."
  done
}

# ---------------------------------------------------------------- 1. Ingress
step "1/6 Ingress: el AWS Load Balancer Controller borra el ALB y sus Security Groups"
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  # kubectl espera el finalizer del controller, que se quita cuando el ALB ya no existe.
  run kubectl delete ingress -n "$NAMESPACE" --all --wait=true --timeout="${TIMEOUT}s"
  # Un Service type=LoadBalancer también crea un balanceador (NLB/CLB) que bloquearía la VPC.
  lb_services="$(kubectl get service -n "$NAMESPACE" \
    -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  for svc in $lb_services; do
    run kubectl delete service -n "$NAMESPACE" "$svc" --wait=true --timeout="${TIMEOUT}s"
  done
else
  info "el namespace $NAMESPACE no existe: no hay Ingress que borrar"
fi
wait_until_empty "balanceador del clúster en AWS" cluster_load_balancers \
  || die "el ALB sigue existiendo: revise los logs del AWS Load Balancer Controller antes de borrar el clúster
       (kubectl -n kube-system logs deploy/aws-load-balancer-controller)"

# ---------------------------------------------------------------- 2. StatefulSets y PVCs
step "2/6 Discos EBS gp3 de Kafka, Redis y RabbitMQ"
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  # Primero los StatefulSets: mientras un pod monta el PVC, kubernetes.io/pvc-protection impide borrarlo.
  run kubectl delete statefulset -n "$NAMESPACE" --all --wait=true --timeout="${TIMEOUT}s"
  run kubectl delete pvc -n "$NAMESPACE" --all --wait=true --timeout="${TIMEOUT}s"
fi
wait_until_empty "disco EBS del namespace" namespace_volumes \
  || die "quedan discos EBS del namespace: bórrelos (aws ec2 delete-volume) o revise el driver EBS CSI"

# ---------------------------------------------------------------- 3. RDS
step "3/6 RDS en la VPC del clúster: instancias, grupos de subredes y Security Groups"
if [ -z "$DB_INSTANCES" ]; then
  info "no hay instancias RDS en $VPC_ID"
else
  for db in $DB_INSTANCES; do
    run aws rds delete-db-instance --region "$REGION" --db-instance-identifier "$db" \
      --skip-final-snapshot --delete-automated-backups --query DBInstance.DBInstanceStatus --output text
  done
  for db in $DB_INSTANCES; do
    run aws rds wait db-instance-deleted --region "$REGION" --db-instance-identifier "$db"
  done
  for group in $(tr ' ' '\n' <<< "$DB_SUBNET_GROUPS" | grep -v '^$' | sort -u); do
    # El grupo "default" lo administra RDS y no se puede borrar.
    [ "$group" = "default" ] || run aws rds delete-db-subnet-group --region "$REGION" --db-subnet-group-name "$group"
  done
  for sg in $(tr ' ' '\n' <<< "$DB_SECURITY_GROUPS" | grep -v '^$' | sort -u); do
    delete_security_group "$sg" || die "no se pudo borrar $sg después de ${TIMEOUT}s: revise qué lo usa
       (aws ec2 describe-network-interfaces --filters Name=group-id,Values=$sg) y vuelva a ejecutar el script"
  done
fi

# ---------------------------------------------------------------- 4. pausa
step "4/6 Pausa de 30 s para que AWS termine las eliminaciones en segundo plano"
run sleep 30

# ---------------------------------------------------------------- 5. clúster
step "5/6 Clúster EKS $CLUSTER (nodegroups, clúster y stack de la VPC)"
run eksctl delete cluster --name "$CLUSTER" --region "$REGION" --wait

# ---------------------------------------------------------------- 6. informe
step "6/6 Recursos que este script no borra (revise y borre a mano si ya no los necesita)"
if [ "$DRY_RUN" -eq 1 ]; then
  info "(--dry-run) aquí se listarían los repositorios ECR truckcar/*, las instancias RDS y los buckets S3 de TruckCar"
else
  echo "   Repositorios ECR (truckcar/*):"
  aws ecr describe-repositories --region "$REGION" \
    --query "repositories[?starts_with(repositoryName, 'truckcar/')].repositoryName" --output text \
    | tr '\t' '\n' | grep -v '^$' | sed 's/^/     /' || echo "     (ninguno)"
  echo "   Instancias RDS con 'truckcar' en el nombre:"
  aws rds describe-db-instances --region "$REGION" \
    --query "DBInstances[?contains(DBInstanceIdentifier, 'truckcar')].[DBInstanceIdentifier,DBInstanceStatus]" \
    --output text | sed 's/^/     /' | grep . || echo "     (ninguna)"
  echo "   Buckets S3 con 'truckcar' en el nombre:"
  aws s3api list-buckets --query "Buckets[?contains(Name, 'truckcar')].Name" --output text \
    | tr '\t' '\n' | grep -v '^$' | sed 's/^/     /' || echo "     (ninguno)"
fi
cat <<EOF

   Para borrarlos (irreversible):
     aws ecr delete-repository --region $REGION --repository-name truckcar/<servicio> --force
     aws rds delete-db-instance --region $REGION --db-instance-identifier <id> --skip-final-snapshot
     aws s3 rb s3://<bucket> --force
   Si creó una distribución de CloudFront delante del ALB, desactívela y bórrela en la consola.
EOF
echo
echo "Desmontaje terminado."
