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
    └── azure-aks/                  PostgreSQL Flexible Server, Event Hubs, Azure Cache for Redis, Key Vault,
                                    Application Routing, almacenamiento S3 (RustFS) en el clúster
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

El workflow `platform.yml` valida en cada cambio que ambos overlays compilen con kustomize y cumplan los esquemas de
Kubernetes 1.30 y de los CRD de External Secrets (`kubeconform -strict`).

## Pendiente por entorno

- Kafka en Event Hubs (AKS) requiere SASL_SSL: agregar `SPRING_KAFKA_PROPERTIES_*` y la cadena de conexión al Secret.
- RabbitMQ en AKS corre fuera de este repo (operador de RabbitMQ o Helm chart) en `truckcar-messaging`.
- Los dominios, certificados y el backend de trazas (`OTEL_TRACES_ENDPOINT`) son de cada entorno.
