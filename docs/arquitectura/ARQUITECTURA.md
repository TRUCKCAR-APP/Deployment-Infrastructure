# Arquitectura de TruckCar

Cuatro vistas de la plataforma tal como está hoy: el despliegue en AWS (EKS en AWS Academy Learner Lab), el stack por
capa, los eventos entre servicios y el flujo de la telemetría en vivo. La red local de Docker está en el
[README](../../README.md#topología-de-red) y el escalamiento en [ESCALAMIENTO_Y_ESTABILIDAD.md](ESCALAMIENTO_Y_ESTABILIDAD.md).

## 1. Despliegue en AWS (overlay `k8s/overlays/aws-eks-lab`)

```mermaid
flowchart LR
    subgraph users["Usuarios"]
        phone["PWA en el teléfono<br/>(conductor)"]
        desk["Navegador<br/>(torre de control, generador)"]
    end
    tunnel["Túnel HTTPS de pruebas<br/>(Cloudflare Quick Tunnel)"]

    subgraph aws["AWS · us-east-1 (Learner Lab, LabRole)"]
        ecr[("Amazon ECR<br/>10 imágenes")]
        alb["Application Load Balancer<br/>HTTP :80 · health checks por servicio"]
        subgraph vpc["VPC 192.168.0.0/16 (eksctl)"]
            subgraph eks["Amazon EKS 1.36 · 2 nodos EC2 t3.large"]
                subgraph edge["Borde"]
                    gw["api-gateway :8000"]
                    fe["frontend (nginx) :8080"]
                end
                subgraph svc["Microservicios Spring Boot"]
                    ui["user-identity"]
                    fd["fleets-drivers"]
                    ca["community-alerts"]
                    la["load-allocation"]
                    rr["routing-restrictions"]
                    ai["ai-fleet-allocation"]
                    ra["route-ai-agent"]
                    nt["notifications"]
                end
                subgraph data["Datos y mensajería en el clúster (EBS gp3)"]
                    pb[["PgBouncer"]]
                    kf[["Kafka 3.8 (KRaft)"]]
                    rmq[["RabbitMQ 3.13<br/>relay STOMP"]]
                    rd[("Redis 7.4")]
                end
            end
            rds[("Amazon RDS<br/>PostgreSQL 16 + PostGIS<br/>subredes privadas")]
        end
        s3[("Amazon S3<br/>evidencias y voz")]
        sns["Amazon SNS<br/>push"]
        ai_svc["Amazon Bedrock / Polly<br/>(no permitidos en el laboratorio:<br/>reglas y FAILED como respaldo)"]
    end

    phone -- HTTPS / WSS --> tunnel --> alb
    desk -- HTTP --> alb
    alb -- "/api, /ws-telemetry" --> gw
    alb -- "/" --> fe
    gw --> ui & fd & ca & la & rr & ai & ra & nt
    gw -- tickets del WebSocket --> rd
    fd -- posición en vivo --> rd
    fd -- STOMP --> rmq
    ui & fd & ca & la & rr & ai & ra & nt --> pb -- TLS --> rds
    ui & fd & ca & la & rr & ai & ra & nt <--> kf
    la -- URLs prefirmadas --> s3
    nt --> sns & s3
    ra -. Converse .-> ai_svc
    nt -. SynthesizeSpeech .-> ai_svc
    ecr -. imágenes .-> eks
```

- **Credenciales de AWS:** sin IRSA ni Pod Identity (el laboratorio no permite crear roles). Los pods usan el LabRole
  del nodo por IMDSv2 (hop limit 2) con `DefaultCredentialsProvider`. En el repositorio no hay claves.
- **Red:** NetworkPolicies con `default-deny` de entrada. El ALB llega solo a `:8000` del gateway, `:8080` de la PWA y
  `:8090` (health check del gateway). PgBouncer solo acepta a los servicios, y la mensajería solo a la plataforma.
- **HTTPS:** el laboratorio no permite CloudFront ni hay dominio para ACM. Para probar en el teléfono se usa el túnel
  (`k8s/overlays/aws-eks-lab/optional/cloudflare-tunnel.yaml`).
- **Ciclo de vida:** el desmontaje se hace con `scripts/teardown.sh`, en este orden: ALB, discos EBS, RDS y clúster.

## 2. Stack tecnológico por capa

```mermaid
flowchart TB
    subgraph client["Cliente"]
        pwa["PWA · JavaScript sin framework · Tailwind CSS 3.4 · Leaflet 1.9<br/>Service Worker · IndexedDB (cola offline) · STOMP sobre WebSocket"]
    end
    subgraph entry["Entrada"]
        gwt["Spring Cloud Gateway 2023.0 · JWT · CORS · ticket de un solo uso en Redis<br/>nginx 1.27 (PWA)"]
    end
    subgraph services["Microservicios"]
        boot["Java 21 · Spring Boot 3.3 · Spring Data JPA / Redis · Flyway · Resilience4j<br/>outbox transaccional · AWS SDK v2 (S3, SNS, Polly, Bedrock)"]
    end
    subgraph messaging["Mensajería y datos"]
        msg["Apache Kafka 3.8 (eventos) · RabbitMQ 3.13 (relay STOMP) · Redis 7.4<br/>PostgreSQL 16 + PostGIS 3.4 · PgBouncer 1.24 · S3"]
    end
    subgraph ops["Plataforma y operación"]
        plat["Docker Compose (local) · Kubernetes con kustomize · Amazon EKS (eksctl) · ECR · ALB<br/>GitHub Actions (pruebas, imágenes GHCR y ECR, stack completo)<br/>OpenTelemetry · Tempo · Prometheus · Grafana"]
    end
    client --> entry --> services --> messaging
    services -.-> ops
```

## 3. Eventos entre servicios (Kafka)

```mermaid
flowchart LR
    la["load-allocation"] -- "events.load-allocation" --> fd["fleets-drivers"] & ai["ai-fleet-allocation"] & nt["notifications"]
    fd -- "events.vehicle-status" --> ai
    ai -- "events.fleet-allocation-results" --> la
    la -- "events.assignment-notifications" --> nt
    ca["community-alerts"] -- "events.road-alerts" --> ra["route-ai-agent"]
    ca -- "events.sos" --> nt
    rr["routing-restrictions"] -- "events.road-restrictions" --> ra & nt
    ra -- "events.route-plans" --> plans(("planes de ruta"))
    ui["user-identity"] -- "events.user-events" --> users(("eventos de usuario"))
```

Los tópicos llevan el prefijo `truckcar.`. Cada servicio publica con un outbox transaccional: el evento se guarda en
la misma transacción que el cambio y un publicador lo envía a Kafka.

## 4. Telemetría en vivo

```mermaid
sequenceDiagram
    autonumber
    participant P as PWA del conductor
    participant G as api-gateway
    participant R as Redis
    participant F as fleets-drivers
    participant Q as RabbitMQ (STOMP)
    participant T as Torre de control
    P->>G: POST /api/v1/telemetry/ws-ticket (JWT)
    G->>R: guarda ticket (TTL 30 s)
    G-->>P: ticket
    P->>G: WSS /ws-telemetry?ticket=… (Origin del navegador)
    G->>R: GETDEL ticket (un solo uso)
    G->>F: handshake con X-Auth-User / X-Auth-Role y el Origin original
    F-->>P: CONNECTED
    loop cada 3 s con señal
        P->>F: posición GPS
        F->>R: posición en vivo
        F->>Q: /topic/fleet-locations (agregado)
        Q-->>T: posiciones de la flota
    end
    Note over P: Sin señal: cola en IndexedDB y /sync/batch al volver
```
