# TruckCar en Kubernetes (AWS EKS / Azure AKS)

Manifiestos base con kustomize y un overlay por nube. Reproducen en el clúster lo que docker-compose hace en local: un
punto de entrada, servicios aislados, PgBouncer delante de PostgreSQL, un esquema por servicio, trazas por OTLP y
métricas en `/actuator/prometheus`.

```
k8s/
├── base/
│   ├── kustomization.yaml          namespace truckcar, imágenes ghcr.io/truckcar-app/<servicio>:main
│   ├── namespace.yaml              Pod Security Admission "restricted"
│   ├── service-accounts.yaml       una ServiceAccount por componente (IRSA / Workload Identity en los overlays)
│   ├── platform-config.yaml        ConfigMap truckcar-platform (endpoints, Kafka, PgBouncer, OTLP, S3, CORS)
│   ├── apps/                       Deployment + Service de cada servicio, el api-gateway y la PWA
│   │   └── fleets-drivers.yaml     Service headless (balanceo DNS del WebSocket) + Service ClusterIP para REST
│   ├── data/
│   │   ├── pgbouncer.yaml          PgBouncer (transaction) + pgbouncer-exporter; userlist desde el Secret
│   │   ├── db-init-job.yaml        Job idempotente: un rol y un esquema por servicio
│   │   └── init-service-schemas.sql  copia exacta de docker/postgres/ (el CI lo comprueba)
│   ├── observability/otel-collector.yaml
│   ├── ingress.yaml                /api y /ws-telemetry -> api-gateway, / -> PWA
│   ├── network-policies.yaml       default-deny + permisos explícitos (equivalente a truckcar-network)
│   ├── autoscaling.yaml            HPA + PDB de api-gateway, fleets-drivers y la PWA
│   └── secrets/truckcar-secrets.example.yaml   plantilla para clústeres locales (no se aplica)
└── overlays/
    ├── aws-eks/                    RDS, MSK, ElastiCache, Amazon MQ, S3 con IRSA, AWS Secrets Manager, ALB, ADOT
    ├── azure-aks/                  PostgreSQL Flexible Server, Event Hubs, Azure Cache for Redis, Key Vault,
    │                               Application Routing, almacenamiento S3 (RustFS) en el clúster
    └── azure-students/             azure-aks recortado para Azure for Students: un nodo B-series, una réplica,
                                    Kafka/Redis/RabbitMQ en el clúster, imágenes de GHCR (ver abajo)
```

## Decisiones

- **Un solo Secret, alimentado por el gestor de secretos.** Los pods leen `truckcar-secrets`; en EKS/AKS lo crea
  External Secrets Operator desde AWS Secrets Manager (`truckcar/...`) o Azure Key Vault (`truckcar-...`). Ningún
  secreto está en Git. En EKS, Load-Allocation no tiene claves S3: usa IRSA.
- **WebSocket escalable.** `fleets-drivers` es un Service headless: el DNS devuelve la IP de cada pod y el api-gateway
  (`lb://fleets-drivers`, refresco de DNS de 10 s) reparte las conexiones STOMP; el relay en RabbitMQ entrega cada
  posición a todas las réplicas. Las llamadas REST entre servicios usan `fleets-drivers-api` (ClusterIP).
- **PgBouncer sin `auth_query`.** En RDS y Azure Flexible Server no hay superusuario que lea `pg_shadow`, así que el
  initContainer escribe `userlist.txt` con la contraseña de cada rol desde el Secret. TLS obligatorio hacia la base.
- **Actuator interno.** El Ingress solo llega a `:8000` del gateway y `:8080` de la PWA; `/actuator/prometheus` lo leen
  los namespaces etiquetados `truckcar.io/monitoring=true` (anotaciones `prometheus.io/*` en cada pod: Amazon Managed
  Prometheus, Azure Monitor managed Prometheus o kube-prometheus-stack). Los dashboards de
  `docker/observability/grafana/dashboards/` sirven sin cambios.
- **Pods endurecidos.** No root (UID 10001), sistema de archivos de solo lectura (`/tmp` en `emptyDir`), sin
  capabilities, `seccompProfile: RuntimeDefault`, sin token de la API de Kubernetes montado.

## Despliegue

Requisitos en el clúster: ingress-nginx / AWS Load Balancer Controller / Application Routing, External Secrets Operator,
metrics-server (HPA) y un CNI con NetworkPolicy. El namespace del controlador de Ingress lleva la etiqueta
`truckcar.io/ingress-controller=true` y el de Prometheus `truckcar.io/monitoring=true`.

1. Crear los secretos en el gestor de la nube con las claves de `overlays/<nube>/external-secrets.yaml` (las mismas
   variables que `.env.example`).
2. Ajustar en el overlay los valores de ejemplo (`123456789012`, `abcd12`, `truckcar.example.com`, ARNs, registro de
   imágenes) y el tag de las imágenes (`newTag`).
3. Revisar y aplicar:

   ```bash
   kubectl kustomize k8s/overlays/aws-eks | less     # o azure-aks
   kubectl apply -k k8s/overlays/aws-eks
   kubectl -n truckcar wait --for=condition=complete job/db-init --timeout=5m
   kubectl -n truckcar rollout status deploy/api-gateway
   ```

   `db-init` es idempotente; en un pipeline GitOps conviene ejecutarlo como hook previo (PreSync en Argo CD,
   pre-upgrade en Helm) para que los esquemas existan antes de que arranquen los servicios.

El workflow `platform.yml` valida en cada cambio que los tres overlays compilen con kustomize y cumplan los esquemas de
Kubernetes 1.30 y de los CRD de External Secrets (`kubeconform -strict`).

## Azure for Students (100 USD de crédito)

`overlays/azure-students` es `azure-aks` recortado para que el crédito alcance el semestre. La regla de oro: **el clúster
y la base solo encendidos para trabajar o presentar.** Con 24/7 el crédito no llega al segundo mes.

| Recurso | Qué se usa | Costo aproximado (verificar en la calculadora de Azure) |
|---|---|---|
| AKS | Plano de control en el nivel Free | 0 USD |
| Nodo | 1 × Standard_B4ms (4 vCPU, 16 GiB), disco del SO de 32 GiB | ~0,17 USD/h: ~15 USD/mes con 90 h de uso, ~120 USD/mes encendido siempre |
| PostgreSQL | Flexible Server Burstable B1ms, 32 GiB | Incluido en los servicios gratuitos de 12 meses (750 h/mes); si no, ~13 USD/mes |
| Kafka, Redis, RabbitMQ | En el clúster (`messaging.yaml`), discos estándar de 4, 1 y 1 GiB | ~0,5 USD/mes de disco |
| Evidencias (RustFS) | En el clúster, 8 GiB estándar | ~0,5 USD/mes |
| Imágenes | GHCR. Los paquetes son **privados**: hace falta un `imagePullSecret` o hacerlos públicos (ver abajo) | Públicos: 0 USD. Privados: cuentan contra la cuota de GitHub Packages de la organización (verificar en Billing) |
| Key Vault | Estándar | Centavos |
| Balanceador del Ingress | Standard Load Balancer + IP pública | ~20 USD/mes mientras exista (revisar si sigue cobrando con el clúster detenido) |
| Azure OpenAI | Opcional | Sin clave, Route-AI usa las reglas y todo funciona |

Por qué así:
- **Event Hubs y Azure Cache for Redis no se pueden pausar** y cuestan ~38 USD/mes juntos. Además, el overlay
  `azure-aks` aún no les configura SASL_SSL ni TLS (ver "Pendiente por entorno"). En el clúster, con el nodo detenido,
  solo cuestan sus discos.
- **B4ms y no B2ms:** son 9 JVM de Spring (384 Mi de request, hasta 768 Mi) más la mensajería. En 8 GiB caben las
  requests, pero los límites no y el arranque de las 9 JVM en 2 vCPU tarda varios minutos. B2ms solo si el crédito
  lo exige.
- **PostgreSQL gestionado:** es lo único con estado valioso, tiene respaldos automáticos y el B1ms es gratuito el
  primer año.
- **Sin trazas:** el collector queda en 0 réplicas y los servicios no exportan; las métricas siguen en
  `/actuator/prometheus` (Azure Monitor managed Prometheus tiene nivel gratuito).

### Acceso a las imágenes de GHCR

Los paquetes `ghcr.io/truckcar-app/*` son **privados**: sin credenciales, el registro responde `unauthorized` y los
pods quedan en `ImagePullBackOff`. Hay dos opciones.

**Opción A · `imagePullSecret` con un token de solo lectura.**
- **Token:** un token personal *classic* de GitHub con **solo** el permiso `read:packages`, con vencimiento, de una cuenta
  con acceso a la organización. No da escritura ni acceso al código.
- **Dónde vive:** el token **no se guarda en el repositorio**. Se pasa por variable de entorno al crear el Secret y, si se
  quiere, se guarda en Key Vault.

```bash
# GHCR_USER y GHCR_TOKEN solo en la sesión; history -c o una terminal nueva al terminar.
kubectl -n truckcar create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io --docker-username="$GHCR_USER" --docker-password="$GHCR_TOKEN"
# Cada servicio usa su propia ServiceAccount (k8s/base/service-accounts.yaml):
for sa in api-gateway user-identity fleets-drivers community-alerts load-allocation routing-restrictions \
          ai-fleet-allocation route-ai-agent notifications frontend; do
  kubectl -n truckcar patch serviceaccount "$sa" -p '{"imagePullSecrets":[{"name":"ghcr-pull"}]}'
done
kubectl -n truckcar rollout restart deployment
```

- **A favor:** las imágenes siguen privadas y la decisión es reversible.
- **En contra:**
  - El token vence y hay que rotarlo, y depende de una persona.
  - Las descargas desde AKS de paquetes privados cuentan contra la cuota de transferencia de GitHub Packages de la
    organización: unas 10 imágenes de ~200-300 MB por cada nodo nuevo o reiniciado. Verificar los límites del plan en
    *Settings → Billing* de TRUCKCAR-APP.

**Opción B · hacer públicos los paquetes** (en GitHub: *Package settings → Change visibility*, uno por paquete).
- **A favor:**
  - Sin token ni Secret en el clúster.
  - Almacenamiento y descargas sin costo, cualquier nodo descarga sin configuración, y `docker compose pull` funciona
    para todo el equipo.
- **En contra:**
  - Cualquiera puede descargar las imágenes.
  - **Según la documentación de GitHub, un paquete público no se puede volver privado**: hay que borrarlo y volver a
    publicarlo.
- **Qué se expone:** nada que no sea ya público. Los repos de código de TRUCKCAR-APP son públicos y las imágenes solo
  empaquetan ese código y su `application.yml`. Revisado: sin credenciales, solo valores de desarrollo como `test` o
  `guest` que se sobrescriben por variables de entorno.

**Recomendación: opción B (paquetes públicos).**
- El código ya es público y las imágenes no agregan nada sensible.
- Evita un token personal que vence dentro del clúster de la sustentación, y evita gastar la cuota de Packages con cada
  arranque del nodo.
- **Si el equipo prefiere conservar la privacidad, o mientras se decide, use la opción A:** es reversible y la B no.

Creación (Azure CLI; revise cada opción con `--help`, cambian entre versiones):

```bash
az group create -n truckcar-rg -l eastus
az aks create -g truckcar-rg -n truckcar --tier free --node-count 1 --node-vm-size Standard_B4ms   --node-osdisk-size 32 --network-plugin azure --network-plugin-mode overlay --network-policy azure   --enable-app-routing --enable-oidc-issuer --enable-workload-identity --generate-ssh-keys
az postgres flexible-server create -g truckcar-rg -n truckcar-pg --tier Burstable --sku-name Standard_B1ms   --storage-size 32 --version 16
# PostGIS hay que permitirlo en Flexible Server antes de que db-init cree las extensiones.
az postgres flexible-server parameter set -g truckcar-rg -s truckcar-pg --name azure.extensions --value POSTGIS
```

Después: Key Vault con los secretos de `overlays/azure-aks/external-secrets.yaml`, External Secrets Operator (Helm) y
`kubectl apply -k k8s/overlays/azure-students`.

Apagar y encender (lo que más ahorra):

```bash
az aks stop  -g truckcar-rg -n truckcar        # nodos desasignados: deja de cobrar el cómputo
az postgres flexible-server stop -g truckcar-rg -n truckcar-pg   # Azure la vuelve a encender sola a los 7 días
az aks start -g truckcar-rg -n truckcar && az postgres flexible-server start -g truckcar-rg -n truckcar-pg
```

Ponga una alerta de presupuesto (Cost Management → Budgets) en 20, 50 y 80 USD.

Validado con `kubectl kustomize` y `kubeconform -strict` (194 recursos válidos en los tres overlays). **No se probó en
un clúster AKS real**: en especial los usuarios no root de Kafka (1000), Redis (999) y RabbitMQ (100) con Pod Security
"restricted", y el disco `managed-csi` de los StatefulSets.

## Pendiente por entorno

- Kafka en Event Hubs (AKS) requiere SASL_SSL: agregar `SPRING_KAFKA_PROPERTIES_*` y la cadena de conexión al Secret.
- RabbitMQ en AKS corre fuera de este repo (operador de RabbitMQ o Helm chart) en `truckcar-messaging`.
- Los dominios, certificados y el backend de trazas (`OTEL_TRACES_ENDPOINT`) son de cada entorno.
