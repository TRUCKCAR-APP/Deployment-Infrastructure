# Arquitectura de TruckCar

Cinco vistas de la plataforma tal como está hoy: el despliegue en AWS (EKS en AWS Academy Learner Lab), el stack por
capa, los eventos entre servicios, el flujo de la telemetría en vivo y la frontera entre la IA, el motor determinista y
la capa sin señal. La red local de Docker está en el
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
        ai_svc["Amazon Polly<br/>(no permitido en el laboratorio:<br/>la voz queda FAILED)"]
    end
    aoai["Azure OpenAI · gpt-4.1-mini<br/>(East US 2; reglas como respaldo)"]

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
    ra -- HTTPS --> aoai
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
    ra -- "events.route-requests<br/>(route.replan.requested)" --> fd
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

## 5. Frontera entre la IA, el motor determinista y la capa sin señal

TruckCar usa un modelo de lenguaje en **un solo punto**: entender el texto libre de las alertas de la comunidad.
Las decisiones que pueden poner en riesgo un camión de carga pesada (a quién se asigna una carga, por dónde pasa y si
cabe bajo un puente) las toma código determinista sobre datos geográficos. El modelo solo informa: señala que la vía
está bloqueada. Si el modelo falla o no está disponible, el sistema sigue funcionando.

| Capa | Dónde vive | Qué decide | Qué **no** decide | Si falla |
|---|---|---|---|---|
| **IA (NLP)** | route-ai-agent: `ModelAlertInterpreter` con Azure OpenAI `gpt-4.1-mini` (Bedrock como alternativa) | Si el texto de una alerta describe un bloqueo (`roadBlockage`), su severidad y una confianza de 0 a 1. Solo con confianza ≥ 0,70 se pide replanteo | Rutas, asignaciones, gálibos ni pesos | Fallback a `RuleBasedAlertInterpreter` (palabras clave) con Resilience4j; métricas `truckcar_ai_requests_total` y `truckcar_ai_fallback_total` |
| **Motor determinista** | Routing-Restrictions (PostGIS: `validate-route`, `validate-compatibility`), AI-powered-fleet-allocation (`FleetScoringOptimizer`, `OsrmRouteRestrictionScreen`), OSRM, route-ai-agent (`TruckRoutePlanner` sobre HERE Routing v8 con perfil de camión) | Si una ruta es transitable para la altura y el peso del vehículo; a qué conductor se propone la carga (0,5·cercanía + 0,3·capacidad + 0,2·calificación, tras los filtros de cuenta verificada, ocupado, gálibo/peso de la ruta, RUNT, cadena de frío, tipo y capacidad); qué desvío se elige | La interpretación del texto libre | Fail-open documentado: sin Routing-Restrictions se asigna sin el filtro de ruta, con la métrica `component=route-restrictions`; la PWA avisa que la ruta no se pudo validar |
| **Capa sin señal** | PWA: `offlineQueue.js` (IndexedDB `truckcar-offline`), `routeStore.js` (`truckcar-route`), `tileStore.js` + Service Worker (teselas ya vistas, 100 MB) | Seguir guiando con la última ruta validada, avisar de gálibos a 3 km y de los puentes bajos vecinos fuera de ruta, encolar posiciones y entregas para `/sync/batch` | Nada nuevo: no recalcula rutas ni valida restricciones sin red, solo usa lo que el motor ya validó | Si no hay registro guardado, la guía queda como no disponible y el mapa sigue con las teselas en caché |

La explicación que ve la torre de control ("Asignado por algoritmo determinista (Cercanía + Capacidad +
Calificación)… Candidato ALT-410 descartado por gálibo/peso en la ruta (Límite: 3,80 m…)") la arma
`DecisionExplanation` a partir de los puntajes y motivos del optimizador. **No la escribe un LLM.** Se guarda en
`allocation_decisions.decision_explanation` y se devuelve en `GET /api/v1/fleet-allocation/history/{loadId}`.

### Ciclo del replanteo por bloqueo

```mermaid
sequenceDiagram
    autonumber
    participant C as Conductor (reporta)
    participant CA as community-alerts
    participant RA as route-ai-agent (IA)
    participant FD as fleets-drivers
    participant P as PWA del conductor en ruta
    participant RR as Routing-Restrictions (PostGIS)
    participant T as Torre de control
    C->>CA: alerta con texto libre y posición
    CA->>RA: alert.reported (events.road-alerts)
    RA->>RA: LLM: roadBlockage, confianza (reglas si falla)
    RA->>FD: route.replan.requested con lat/lng, texto y confianza (events.route-requests)
    FD-->>P: /topic/road-blockages (descarta eventos de más de 30 min)
    FD-->>T: /topic/road-blockages (aviso)
    P->>P: ¿a 150 m o menos de lo que falta de ruta? (geometría)
    P->>P: tono, HUD y voz: "Alerta en ruta procesada por IA… Recalculando trayectoria..."
    P->>P: OSRM: alternativas que no pasan por el bloqueo
    P->>RR: validate-route de cada alternativa (altura y peso del vehículo)
    RR-->>P: blocking / warnings
    P->>P: primera alternativa sin restricciones, guardada en IndexedDB
```

La IA decide **si** hay un bloqueo. La geometría decide **a quién** afecta y PostGIS decide **por dónde** se puede
pasar. Si la IA se equivoca, un falso positivo cuesta un desvío validado y un falso negativo deja la ruta como
estaba. En ningún caso se manda un camión bajo un puente bajo.

### Qué queda en el dispositivo

| Almacén | Contenido | Vida |
|---|---|---|
| `truckcar-route` (`routeStore.js`) | Ruta elegida (geometría, maniobras), restricciones de la ruta, restricciones vecinas del corredor de 500 m, bloqueos marcados por la IA, la carga y el perfil del propio conductor | Se precalcula al aceptar y se actualiza al iniciar y en cada recálculo. Caduca a los 3 días y se borra al entregar o al cerrar sesión |
| `truckcar-offline` (`offlineQueue.js`) | Eventos pendientes (posiciones, inicio, entrega con firma y foto, alertas) | Hasta que `/sync/batch` los confirma |
| `truckcar-tiles` + caché del SW | Teselas que el conductor ya vio | Según las cabeceras de la tesela; tope de 100 MB. Por los términos de Stadia Maps no se precargan zonas |
