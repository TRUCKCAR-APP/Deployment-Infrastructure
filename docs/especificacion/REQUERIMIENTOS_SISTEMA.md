# TruckCar · Especificación de requerimientos del sistema (SRS)

| | |
|---|---|
| **Versión** | 1.0 |
| **Fecha de corte** | 7 de noviembre de 2026 |
| **Fuentes** | Ramas `main` de los 11 repositorios de la organización TRUCKCAR-APP y proyecto de Jira **KAN** (`truckcar.atlassian.net`), 149 tickets |
| **Documentos relacionados** | [ESCALAMIENTO_Y_ESTABILIDAD.md](../arquitectura/ESCALAMIENTO_Y_ESTABILIDAD.md), [README](../../README.md) (topología de red), [k8s/README.md](../../k8s/README.md) (despliegue), `truckcar-frontend/docs/redesign/` (rediseño y auditorías de la PWA) |

**Convenciones.**
- Las rutas de código se escriben relativas a cada repositorio: `fleets-drivers/...` es el repositorio
  `TRUCKCAR-APP/fleets-drivers`, y `truckcar-frontend/...` es la PWA (carpeta local `untitled/`).
- **Estado** de cada requisito:
  - **Implementado:** existe en `main` y hay evidencia en el código o en una verificación de punta a punta.
  - **En progreso:** una parte existe en `main` y la otra está abierta en Jira.
  - **Pendiente:** no hay código en `main`.
- Un requisito no se marca Implementado solo porque su ticket esté en "Finalizado": se exige la evidencia en el
  código. Las diferencias entre Jira y el repositorio están en la [sección 4.3](#43-inconsistencias-entre-jira-y-el-repositorio).

---

## 1. Introducción y alcance del sistema

### 1.1 Propósito

TruckCar conecta a los generadores de carga con conductores de carga pesada en Colombia y acompaña el viaje de punta a
punta: asignación de la carga, ruta apta para el vehículo (gálibo y peso), navegación paso a paso, alertas viales
comunitarias, SOS, prueba de entrega digital y operación sin señal.

El sistema cumple su objetivo cuando:
- el conductor completa el viaje y registra la entrega desde el teléfono, aunque pierda la señal en el camino;
- la torre de control ve la flota en tiempo real;
- el generador y el destinatario pueden seguir el envío.

### 1.2 Usuarios y roles

| Rol (`User-Identity`) | Responsabilidad | Interfaz |
|---|---|---|
| `CONDUCTOR` | Recibe y acepta cargas, navega, reporta alertas, activa el SOS y registra la entrega | App del conductor (PWA en el teléfono) |
| `COORDINADOR` | Monitorea la flota, gestiona cargas y restricciones y atiende los SOS | Torre de control |
| `ADMIN` | Lo mismo que el coordinador, más la gestión de usuarios, roles y plantillas | Torre de control |
| `GENERADOR` | Publica cargas y sigue sus envíos | Panel "Mis envíos" |
| Destinatario (sin cuenta) | Sigue un envío con un enlace firmado | Seguimiento público |

### 1.3 Modelo operativo

**PWA ultraliviana para el conductor en carretera.** Premisa de diseño: *el teléfono solo captura, guarda y muestra;
todo cálculo costoso o compartido ocurre en la nube.*
- HTML, CSS y JavaScript sin framework. Tailwind se compila en el despliegue (≈20 KB) y no en el teléfono.
- Service Worker con el *app shell* y una caché de teselas acotada a 100 MB.
- Cola offline en IndexedDB con envío por lotes al reconectar.
- La validación de gálibo y peso, la interpretación de alertas y la asignación corren en el clúster.

**Torre de control en tiempo real para coordinadores.**
- Recibe las posiciones de la flota por WebSocket (STOMP) desde el tópico agregado `/topic/fleet-locations`.
- Gestiona cargas, propuestas de asignación y SOS.
- En el teléfono, los roles `ADMIN` y `COORDINADOR` solo ven la torre: no tienen selector de vistas ni acceso a la
  vista del conductor.

### 1.4 Arquitectura

**Diez componentes desplegables:** nueve servicios del backend detrás de un gateway, más la PWA. Cada servicio tiene
su esquema y su rol de base de datos, y ninguno lee el esquema de otro.

| Componente | Responsabilidad | Tecnología principal |
|---|---|---|
| `api-gateway` | Entrada única: valida el JWT, aplica CORS, enruta y emite el ticket del WebSocket | Spring Cloud Gateway 2023.0, Redis |
| `user-identity` | Registro, inicio de sesión, tokens, roles y ADMIN inicial | Spring Boot 3.3, Spring Security |
| `fleets-drivers` | Estado del conductor y del vehículo, telemetría en vivo e historial | Spring Boot, STOMP, Redis, RabbitMQ |
| `load-allocation` | Cargas, propuestas de asignación, viaje, prueba de entrega (POD) y seguimiento público | Spring Boot, S3 |
| `ai-fleet-allocation` | Elegibilidad y puntaje de conductores para cada carga | Spring Boot, Resilience4j |
| `routing-restrictions` | Restricciones de gálibo y peso, y validación de rutas | Spring Boot, PostGIS |
| `route-ai-agent` | Interpretación de alertas con un modelo de lenguaje, con respaldo por reglas; planeación de rutas para camión (altura, peso, ejes y peajes) validadas contra las restricciones registradas | Azure OpenAI (gpt-4.1-mini) o Amazon Bedrock; HERE Routing v8 y Geocoding |
| `community-alerts` | Alertas viales comunitarias, confirmaciones y SOS | Spring Boot |
| `notifications` | Push (SNS) y voz (Polly), con reintentos y estado `FAILED` | Spring Boot, AWS SDK v2 |
| `truckcar-frontend` | PWA del conductor, torre de control, "Mis envíos" y seguimiento público | JavaScript, Leaflet 1.9, nginx 1.27 |

**Comunicación.**
- **Síncrona:** REST a través del gateway.
- **Asíncrona:** Apache Kafka 3.8 (KRaft). Tópicos `truckcar.events.*` con colas de mensajes fallidos (`*.DLT`).
  Cada servicio publica con un outbox transaccional.
- **Telemetría en vivo:** STOMP sobre WebSocket, con RabbitMQ 3.13 como relay entre réplicas de `fleets-drivers`.
- **Datos:** PostgreSQL 16 con PostGIS 3.4 detrás de PgBouncer 1.24 (modo `transaction`), Redis 7.4 y S3.

**Entornos.**

| Entorno | Estado | Detalle |
|---|---|---|
| Local | Operativo | Docker Compose con red privada; el CI comprueba el aislamiento con `verify-isolation.sh` |
| AWS (Academy Learner Lab) | **Desplegado y verificado** | EKS 1.36 (2 × t3.large), overlay `k8s/overlays/aws-eks-lab`, RDS PostgreSQL 16, S3, SNS, ALB y ECR. Kafka, Redis y RabbitMQ en el clúster. HTTPS de prueba con un túnel de Cloudflare. |
| Azure (`azure-aks`, `azure-students`) | Preparado, **sin desplegar** | Manifiestos validados con kubeconform. El escalamiento con KEDA y el autoescalador de nodos de AKS están diseñados en [ESCALAMIENTO_Y_ESTABILIDAD.md](../arquitectura/ESCALAMIENTO_Y_ESTABILIDAD.md) §3 y §5, pero no existen en el repositorio. |

**Restricciones del Learner Lab que condicionan los requisitos.**
- **Identidad de los pods:** no se pueden crear roles de IAM, así que no hay IRSA ni Pod Identity. Los pods usan el
  LabRole del nodo por IMDSv2.
- **Servicios denegados:** Amazon Bedrock, Amazon Polly y CloudFront. Por eso las alertas las clasifica Azure OpenAI
  (`gpt-4.1-mini`), fuera de AWS, y la voz queda como `FAILED`.
- **Sesión:** las credenciales vencen con la sesión del laboratorio.

### 1.5 Fuera del alcance

- Apps nativas de Android o iOS: se usa una PWA.
- Un modelo de aprendizaje automático entrenado con el historial de asignaciones: no hay datos suficientes.
- HTTPS con dominio propio dentro del Learner Lab.

---

## 2. Requisitos funcionales (RF)

### 2.1 Identidad, acceso y gateway

#### RF-01 · Registro de usuarios
- **Descripción:**
  - `POST /api/v1/auth/register` crea una cuenta con correo, contraseña y rol.
  - El registro público solo admite `CONDUCTOR` y `GENERADOR`.
  - La cuenta nace en estado `PENDING_VERIFICATION`.
  - El primer `ADMIN` lo crea `AdminBootstrap` al arrancar, a partir de variables de entorno, y es idempotente.
- **Criterios de aceptación:**
  1. Un correo repetido responde `409`.
  2. Un cuerpo inválido responde `400` con el detalle del campo.
  3. Reiniciar el servicio no duplica al `ADMIN` inicial.
  4. La contraseña se guarda con hash y nunca aparece en una respuesta.
- **Componentes:** `user-identity`, `api-gateway`, `truckcar-frontend` (`loginView.js`).
- **Estado:** **Implementado.** Evidencia: `User-Identity/.../AuthController` (`/register`) y `AdminBootstrap`.
  Jira: KAN-34 y KAN-26 (Finalizado). La pantalla de registro (KAN-28) sigue "En curso".

#### RF-02 · Inicio de sesión, renovación y cierre de sesión
- **Descripción:**
  - `POST /auth/login` emite un *access token* JWT de 15 min y un *refresh token* de 7 días, que es de un solo uso.
  - `POST /auth/refresh` rota el refresh token.
  - `POST /auth/logout` lo revoca.
  - La PWA renueva el token sola cuando recibe un `401`.
- **Criterios de aceptación:**
  1. Credenciales inválidas responden `401`, sin decir si existe el correo.
  2. Reusar un refresh token ya rotado responde `401`.
  3. Después del logout, el refresh token deja de servir.
  4. La PWA reintenta una sola vez la petición que recibió `401`, con el token nuevo.
- **Componentes:** `user-identity` (`JwtProvider`), `api-gateway` (`JwtUtil`), `truckcar-frontend`.
- **Estado:** **En progreso.** El backend está en `main` (`User-Identity/src/main/resources/application.yml`:
  `access-token-expiration-ms: 900000` y `refresh-token-expiration-ms: 604800000`). La gestión de sesión en el cliente
  es KAN-29 ("En curso").

#### RF-03 · Control de acceso por rol (RBAC)
- **Descripción:**
  - El `ADMIN` cambia el rol y el estado de un usuario con `PATCH /users/{id}/role` y `PATCH /users/{id}/status`.
  - Cada servicio autoriza con las cabeceras `X-Auth-User` y `X-Auth-Role` que inyecta el gateway.
  - La PWA solo muestra las vistas que permite el rol.
- **Criterios de aceptación:**
  1. Un `CONDUCTOR` que llama a `/loads/{id}/assign` recibe `403`.
  2. Un conductor no puede leer `/fleets-drivers/drivers/{id}` de otro conductor.
  3. En el teléfono, un `ADMIN` o un `COORDINADOR` no puede abrir la vista del conductor.
  4. Las rutas de `/templates/**` solo responden al `ADMIN`.
- **Componentes:** `user-identity`, `api-gateway`, los 8 servicios y `truckcar-frontend` (`js/app.js`, `canUseDriverView`).
- **Estado:** **En progreso.**
  - Implementado: KAN-41, KAN-43, KAN-66 y KAN-106 (Finalizado).
  - En curso: la política de rol de `RoadRestrictionController` (KAN-39) y las guardias de navegación (KAN-30).
  - Por hacer: la librería común `GatewayIdentity` (KAN-42).

#### RF-04 · Gateway como único punto de confianza
- **Descripción:**
  - Toda petición externa entra por `api-gateway`, que valida el JWT y propaga la identidad en cabeceras. Los servicios
    no están expuestos fuera del clúster ni de la red de Docker.
  - En las rutas HTTP, el gateway quita la cabecera `Origin`. En la ruta WebSocket la conserva, para que
    `fleets-drivers` pueda validar el origen.
- **Criterios de aceptación:**
  1. Una petición sin JWT a una ruta protegida responde `401` desde el gateway, sin llegar al servicio.
  2. Una cabecera `X-Auth-*` que mande el cliente se reemplaza por la del token.
  3. Ningún servicio responde por un puerto fuera de la red interna; el CI lo comprueba con `verify-isolation.sh`.
- **Componentes:** `api-gateway`, NetworkPolicies (`k8s/base/network-policies.yaml`).
- **Estado:** **Implementado.** Evidencia: `api-gateway/src/main/resources/application.yaml` (8 rutas HTTP con
  `RemoveRequestHeader=Origin` y la ruta `fleets-drivers-telemetry-ws`) y `GatewayOriginRoutingTest`. Jira: KAN-11
  ("En curso" por el límite de tasa y CORS, que se tratan en RNF-17 y RNF-19).

#### RF-05 · Verificación de cuentas en `PENDING_VERIFICATION`
- **Descripción:** hay que definir quién verifica una cuenta nueva (un `ADMIN` o un `COORDINADOR`) y qué puede hacer
  mientras no esté verificada. Hoy un conductor sin verificar puede iniciar sesión y recibir propuestas.
- **Criterios de aceptación:**
  1. La torre lista las cuentas pendientes y permite aprobarlas o rechazarlas.
  2. Una cuenta pendiente no recibe propuestas de asignación.
  3. El cambio de estado queda auditado: quién lo hizo y cuándo.
- **Componentes:** `user-identity`, `ai-fleet-allocation` (elegibilidad) y `truckcar-frontend`.
- **Estado:** **Pendiente.** Jira: KAN-98 ("Por hacer", sin subtareas).

#### RF-06 · Respuestas claras ante peticiones inválidas
- **Descripción:** todos los servicios responden `400` con un `ProblemDetail` legible ante JSON mal formado, tipos
  incorrectos o validaciones fallidas, y nunca exponen clases de Java ni trazas.
- **Criterios de aceptación:**
  1. Un JSON truncado responde `400`, no `500`.
  2. `?page=abc` en un parámetro entero responde `400`.
  3. Los errores `4xx` propios de Spring conservan su código.
  4. El cuerpo de error no contiene nombres de clases ni mensajes internos.
- **Componentes:** los 9 servicios Spring (`GlobalExceptionHandler`).
- **Estado:** **Implementado.** Evidencia: `ClientErrorHandlingTest` en cada servicio y
  `RoadAlertControllerErrorHandlingTest` en Community-Alerts. Jira: KAN-97 y KAN-144 (Finalizado).

### 2.2 Flota y telemática

#### RF-07 · Estado del conductor y del vehículo
- **Descripción:**
  - `POST /api/v1/fleets-drivers/state` registra o actualiza el estado del conductor: `ACTIVO` o `INACTIVO`,
    sin distinguir mayúsculas.
  - También registra el vehículo (placa única por conductor, tipo, capacidad útil y tara, RUNT vigente, certificación
    de cadena de frío) y las horas conducidas en el día.
  - El servicio calcula las horas restantes (tope de 9 h, configurable con `truckcar.shift.max-daily-driving-hours`) y
    activa una alerta de descanso cuando quedan 2 h o menos.
- **Criterios de aceptación:**
  1. Un estado distinto de `ACTIVO` o `INACTIVO` responde `400`.
  2. Una placa registrada a otro conductor se rechaza.
  3. Con 7,5 h conducidas, la respuesta indica 1,5 h restantes y la alerta de descanso activa.
  4. Cada cambio publica `truckcar.events.vehicle-status`.
- **Componentes:** `fleets-drivers` (`FleetDriverService`, `UpdateDriverVehicleStateRequest`).
- **Estado:** **Implementado.** Evidencia: `DriverStatusValidationTest`. Jira: KAN-94 y KAN-145 (Finalizado).

#### RF-08 · Carga a bordo y peso bruto
- **Descripción:**
  - La carga neta a bordo es la suma de los pesos de las cargas del conductor que están en `IN_TRANSIT`.
  - El peso bruto es la tara más esa carga.
  - Los dos valores se recalculan con los eventos de ciclo de vida de `load-allocation`, no con lo que mande el cliente.
- **Criterios de aceptación:**
  1. Iniciar un viaje de 12 t con una tara de 15 t deja 12 t netas y 27 t brutas.
  2. Entregar esa carga devuelve la carga neta a 0.
  3. Un `POST /state` con otra carga neta no la sobrescribe mientras haya cargas a bordo.
- **Componentes:** `fleets-drivers` (`LoadLifecycleEventListener`), `load-allocation`.
- **Estado:** **Implementado.** Evidencia: `FleetDriverServiceActiveLoadsTest` y `LoadLifecycleEventListenerTest`
  (fleets-drivers #4). Jira: KAN-145 y KAN-146 (Finalizado).

#### RF-09 · Telemetría GPS en vivo y segura
- **Descripción:**
  1. La PWA pide un ticket con `POST /api/v1/telemetry/ws-ticket`, autenticada con el JWT.
  2. El gateway guarda el ticket en Redis con una vida de 30 s.
  3. La PWA abre `wss://.../ws-telemetry?ticket=...`; el gateway canjea el ticket con `GETDEL` y lo retira.
  4. Con señal, la PWA envía la posición cada 3 s.
  5. `fleets-drivers` guarda la última posición en Redis (HSET), acumula el histórico por lotes y publica el agregado en
     `/topic/fleet-locations`.
- **Criterios de aceptación:**
  1. El JWT nunca aparece en la URL del WebSocket.
  2. Un ticket reutilizado o vencido rechaza el handshake.
  3. Un `Origin` no permitido rechaza el handshake.
  4. Con la PWA del conductor transmitiendo, la torre ve el marcador moverse en menos de 5 s.
  5. El handshake responde `101` detrás del ALB y del túnel HTTPS.
- **Componentes:** `api-gateway` (`WsTicketController`, `WsTicketStore`), `fleets-drivers`, Redis, RabbitMQ y
  `truckcar-frontend` (`js/telemetry.js`).
- **Estado:** **Implementado.**
  - Verificado en EKS con un navegador real: "Transmitiendo · GPS del dispositivo ±12 m" y la posición guardada en el
    servidor.
  - Jira: KAN-92, KAN-93 y KAN-122 (Finalizado).
  - Falta la validación en un iPhone real (KAN-107, "Por hacer").

#### RF-10 · Reconexión automática de la telemetría
- **Descripción:** si se cae el WebSocket, la PWA muestra "Reconectando telemática" y reintenta con backoff exponencial
  de 2 a 15 s. Al volver la conexión, la cola offline se vacía (RF-33).
- **Criterios de aceptación:**
  1. El estado de la conexión es visible en todo momento.
  2. Los reintentos llevan jitter, para que los teléfonos no reconecten todos en el mismo segundo tras reiniciar un pod.
  3. Al reconectar no se pierde ninguna posición.
- **Componentes:** `truckcar-frontend` (`js/telemetry.js`, `retryLater`).
- **Estado:** **En progreso.** Los criterios 1 y 3 se cumplen. El 2 no: `retryLater` duplica el retardo sin jitter
  (`truckcar-frontend/js/telemetry.js:89-98`). Jira: KAN-67 ("En curso").

#### RF-11 · Consulta de la flota por la torre de control
- **Descripción:**
  - `GET /fleets-drivers/active` lista los conductores con su posición, y `GET /fleets-drivers/available` los que
    pueden recibir carga.
  - `GET /drivers/{driverId}` y `GET /vehicles/{plate}` dan el detalle, con control de acceso.
- **Criterios de aceptación:**
  1. Solo `COORDINADOR` y `ADMIN` listan la flota completa.
  2. Un conductor solo puede consultar su propio detalle.
  3. Un conductor `INACTIVO` no aparece en `available`.
- **Componentes:** `fleets-drivers`, `truckcar-frontend` (`coordinatorPanel.js`).
- **Estado:** **Implementado.** Jira: KAN-66 (Finalizado).

#### RF-12 · Registro y edición del vehículo desde la torre de control
- **Descripción:** un formulario en la torre registra o edita el vehículo de un conductor (placa, tipo, capacidad,
  tara, altura, RUNT y cadena de frío). Hoy solo se puede hacer por la API.
- **Criterios de aceptación:**
  1. Los campos se validan en el cliente y en el servidor (`400` con el campo).
  2. Al guardar, el vehículo aparece en el perfil del conductor y el motor de asignación lo considera.
- **Componentes:** `truckcar-frontend`, `fleets-drivers`.
- **Estado:** **Pendiente.** Jira: KAN-95 y KAN-119 ("Por hacer").

### 2.3 Cargas y despachos

#### RF-13 · Publicación de cargas
- **Descripción:**
  - El `GENERADOR` publica una carga con `POST /api/v1/loads`, indicando origen, destino, peso, tipo de camión
    requerido y ventana de recogida.
  - La consulta con `GET /loads/mine`; la torre consulta `/published`, `/available` y `/company/{companyId}`.
- **Criterios de aceptación:**
  1. Una carga sin peso, tipo de camión, coordenadas de origen y destino o presupuesto responde `400` con el campo
     (`CreateFreightLoadRequest`).
  2. La carga nace en `AVAILABLE` y publica `truckcar.events.load-allocation`.
  3. "Mis envíos" lista solo las cargas del generador autenticado.
- **Componentes:** `load-allocation`, `truckcar-frontend` (`generatorPanel.js`).
- **Estado:** **En progreso.** El backend está en `main` (Flyway, KAN-45 Finalizado). El panel "Mis envíos" es KAN-46
  ("En curso").

#### RF-14 · Ciclo de vida de la carga y de la propuesta
- **Descripción:**
  - **Carga:** `AVAILABLE → ASSIGNED → IN_TRANSIT → DELIVERED`, con cancelación (`PATCH /{loadId}/cancel`).
  - **Propuesta al conductor:** `PROPOSED → NOTIFIED → ACCEPTED | REJECTED | TIMEOUT`.
  - **Vencimiento:** una propuesta sin respuesta vence a los 5 min (`TRUCKCAR_ASSIGNMENT_RESPONSE_TIMEOUT_MINUTES`) y
    se propone al siguiente candidato, hasta 5 intentos (`TRUCKCAR_ASSIGNMENT_MAX_ATTEMPTS`).
  - **Permisos:** `/assign`, `/notify` y `/timeout` son solo para `COORDINADOR`, `ADMIN` o llamadas internas.
- **Criterios de aceptación:**
  1. Una transición inválida (por ejemplo, cancelar una carga `IN_TRANSIT`) responde `409`.
  2. Dos actualizaciones concurrentes no se pisan: hay bloqueo optimista con `@Version` en `FreightLoad`.
  3. Las horas de inicio y entrega que llegan sin señal se acotan entre el hito anterior y el momento actual.
  4. Cada transición publica su evento por outbox.
- **Componentes:** `load-allocation` (`FreightLoadService`, `AssignmentTimeoutScheduler`), `ai-fleet-allocation`.
- **Estado:** **Implementado.** Jira: KAN-43 (Finalizado). La matriz completa de pruebas de transiciones inválidas
  (KAN-44) está "Por hacer".

#### RF-15 · Respuesta del conductor a la propuesta
- **Descripción:**
  - El conductor acepta o rechaza con `PATCH /{loadId}/assignment/accept|reject`.
  - Inicia el viaje con `/trip/start` y lo cierra con `/trip/deliver`.
  - Ve sus compromisos con `GET /loads/driver-commitments`.
- **Criterios de aceptación:**
  1. Solo el conductor propuesto puede aceptar.
  2. Aceptar una propuesta vencida responde `409`.
  3. La PWA muestra la propuesta en tiempo real con los botones de aceptar y rechazar, y un punto ámbar en la pestaña
     Carga.
- **Componentes:** `load-allocation`, `truckcar-frontend` (`driverApp.js`).
- **Estado:** **En progreso.** Los endpoints y la pestaña Carga están en `main`. La propuesta en tiempo real con
  aceptar y rechazar es KAN-55 ("Por hacer").

#### RF-16 · Prueba de entrega digital (POD)
- **Descripción:**
  1. La PWA pide URLs prefirmadas de subida con `POST /{loadId}/proof-of-delivery/upload-urls` (vigencia de 10 min).
  2. Sube la foto y la firma directo a S3.
  3. Cierra la entrega guardando la clave de S3 y el hash del archivo.
  4. `GET /{loadId}/proof-of-delivery` devuelve URLs de descarga de 10 min.
- **Criterios de aceptación:**
  1. Una foto de más de 5 MiB (`max-photo-bytes: 5242880`) o una firma de más de 512 KiB se rechaza.
  2. Un tipo MIME que no sea de imagen se rechaza.
  3. La base de datos guarda la clave de S3 y el hash, nunca el *data URL*.
  4. El botón "Simular foto" no existe en producción.
- **Componentes:** `load-allocation`, Amazon S3 (en local, LocalStack), `truckcar-frontend`.
- **Estado:** **Implementado.**
  - Verificado en EKS: S3 con el LabRole.
  - Jira: KAN-48, KAN-50 y KAN-78 (Finalizado).
  - El visor del POD en los paneles (KAN-49) y el bucket en LocalStack (KAN-77) están "En curso".

#### RF-17 · Seguimiento público de envíos
- **Descripción:**
  - `POST /{loadId}/public-tracking-link` genera un enlace firmado con HMAC-SHA256.
  - `GET /loads/public-tracking/{token}` lo resuelve sin cuenta, por una ruta pública del gateway.
- **Criterios de aceptación:**
  1. El enlace vence a las 48 h, o 6 h después de la entrega si eso ocurre antes.
  2. Un token alterado responde `404` o `401`, sin revelar si existe la carga.
  3. La vista pública muestra el estado y la posición aproximada, y ningún dato personal del conductor.
- **Componentes:** `load-allocation` (`truckcar.tracking.*`), `api-gateway`, `truckcar-frontend`.
- **Estado:** **Implementado.** Jira: KAN-132, KAN-140 y KAN-141 (Finalizado).

#### RF-18 · Línea de tiempo de la carga en tiempo real
- **Descripción:** el generador y la torre ven los hitos de la carga (publicada, asignada, en tránsito y entregada) a
  medida que ocurren, sin recargar la página.
- **Criterios de aceptación:** un cambio de estado aparece en menos de 5 s en "Mis envíos".
- **Componentes:** `truckcar-frontend`, `load-allocation`.
- **Estado:** **Pendiente.** Jira: KAN-47 ("Por hacer").

### 2.4 Asignación de conductores

#### RF-19 · Motor de asignación por puntaje
- **Descripción:**
  - **API:** `POST /api/v1/fleet-allocation/match/{loadId}` evalúa a los conductores disponibles para una carga;
    `POST /optimize` lo hace con varias cargas a la vez, y `GET /history/{loadId}` devuelve las decisiones con su motivo.
  - **Por eventos:** el servicio también reacciona a `truckcar.events.load-allocation` y publica en
    `truckcar.events.fleet-allocation-results`.
  - **Reintento:** un proceso programado reintenta las cargas que siguen esperando conductor.
  - **Elegibilidad** (`FleetScoringOptimizer.evaluateTruck`). Se descarta, con su motivo, al conductor que:
    - está ocupado;
    - tiene el RUNT vencido;
    - no tiene cadena de frío certificada y la carga es `REFRIGERADO`;
    - no tiene la capacidad registrada, o tiene menos capacidad que el peso de la carga.
  - **Puntaje:** `0,50 · e^(−d/200 km) + 0,30 · (peso / capacidad) + 0,20 · calificación`.
- **Criterios de aceptación:**
  1. Cada candidato descartado trae su motivo en español.
  2. Con dos candidatos iguales salvo la distancia, gana el más cercano.
  3. Si fleets-drivers no responde, el circuit breaker abre y la carga queda en espera, sin error `500`.
  4. Un conductor descartado o que rechazó no se vuelve a proponer para esa carga.
- **Componentes:** `ai-fleet-allocation` (`FleetAllocationService`, `FleetScoringOptimizer`,
  `WaitingLoadsRetryScheduler`), `fleets-drivers`, `load-allocation`.
- **Estado:** **Implementado.** Jira: KAN-16 ("En curso"); KAN-51, KAN-52 y KAN-53 (Finalizado). El modelo de
  calificación del conductor (KAN-54) está "En curso".

#### RF-20 · Asignación asistida por un modelo de lenguaje
- **Descripción:** la épica KAN-6 se llama "Asignación inteligente por IA", pero el motor del RF-19 es un algoritmo
  determinista de pesos fijos. La propuesta es que un modelo de lenguaje reordene a los 3–5 mejores candidatos del
  algoritmo y explique la elección. El algoritmo seguiría como respaldo, con el mismo patrón de resiliencia que el
  RNF-06.
- **Criterios de aceptación:**
  1. El modelo solo reordena candidatos elegibles: nunca vuelve elegible a uno descartado.
  2. Ante fallo, cuota agotada o circuito abierto, se usa el orden del algoritmo y se cuenta en
     `truckcar_ai_fallback_total`.
  3. La explicación queda en `GET /history/{loadId}`.
- **Componentes:** `ai-fleet-allocation` y un proveedor de modelo (Azure OpenAI, ya soportado en `route-ai-agent`).
- **Estado:** **Pendiente: decisión abierta.** No hay ticket en Jira; ver la sección 4.3.

### 2.5 Restricciones de ruta y gálibo

#### RF-21 · Gestión de restricciones viales
- **Descripción:**
  - `POST /api/v1/restrictions` registra un gálibo o un límite de peso con su geometría.
  - `GET /restrictions` y `GET /restrictions/{id}` las consultan.
  - `PATCH /{id}/deactivate` desactiva una restricción.
  - Cada cambio publica `truckcar.events.road-restrictions`.
- **Criterios de aceptación:**
  1. Solo `COORDINADOR` y `ADMIN` crean o desactivan restricciones.
  2. Una restricción desactivada deja de afectar las validaciones.
  3. La torre las gestiona desde un formulario.
- **Componentes:** `routing-restrictions`, `truckcar-frontend` (`coordinatorPanel.js`).
- **Estado:** **En progreso.** La API está en `main`. La política de rol es KAN-39 ("En curso") y la gestión en la torre
  es KAN-60 ("Por hacer").

#### RF-22 · Validación de la ruta contra gálibo y peso
- **Descripción:**
  - `POST /restrictions/validate-route` recibe la geometría real de la ruta (de OSRM) y la altura y el peso bruto del
    vehículo. Devuelve las restricciones que se incumplen y la distancia a cada una.
  - `POST /validate-compatibility` valida un vehículo contra un corredor.
- **Criterios de aceptación:**
  1. Un puente de 3,80 m sobre la ruta de un vehículo de 4,10 m aparece como incumplido, con la distancia desde el
     origen.
  2. Una restricción a más de la tolerancia de la ruta no aparece.
- **Componentes:** `routing-restrictions` (PostGIS).
- **Estado:** **Implementado.** Evidencia: Routing-Restrictions #2 y las pruebas de `validate-compatibility`. Jira:
  KAN-59 y KAN-147 (Finalizado).

#### RF-23 · Avisos de gálibo y peso durante la navegación
- **Descripción:** el HUD muestra "Gálibo de X m en Y km · su vehículo mide Z m" y lo anuncia por voz una sola vez,
  cuando la restricción queda a 3 km o menos.
- **Criterios de aceptación:**
  1. El texto viene de `validate-route`, no es fijo.
  2. El aviso no se repite en la misma maniobra.
  3. Lleva triángulo y texto, no solo color.
- **Componentes:** `truckcar-frontend` (`js/navigation.js`, `driverApp.js`), `routing-restrictions`.
- **Estado:** **Implementado.** Evidencia: `truckcar-frontend/docs/redesign/fase-4/hud-galibo-real.png`. Jira: KAN-137
  (Finalizado).

### 2.6 Navegación del conductor

#### RF-24 · Navegación guiada
- **Descripción:**
  - La PWA calcula la ruta con OSRM y muestra un HUD con la maniobra, la distancia, la calle, la altura y el peso bruto.
  - El marcador del camión gira con el rumbo real; sin rumbo conocido, se muestra un punto.
  - Si el conductor se sale de la ruta, la PWA recalcula desde su posición.
  - Las instrucciones se dan por voz y la barra del viaje muestra la distancia y el tiempo que faltan.
- **Criterios de aceptación:**
  1. Fuera de la ruta aparece "Fuera de la ruta · recalculando desde su posición".
  2. Si OSRM falla, aparece "Guía paso a paso no disponible · siga el mapa" sin bloquear el mapa.
  3. Sin GPS, aparece "Sin posición" y no se inventa una dirección.
- **Componentes:** `truckcar-frontend` (`js/navigation.js`, `css/navigation.css`), servidor público de OSRM.
- **Estado:** **Implementado.** Jira: KAN-130 y KAN-136 (Finalizado). OSRM propio o configurable: KAN-70 ("Por hacer").
  Hoy depende de `router.project-osrm.org`.

### 2.7 Alertas comunitarias, IA vial y SOS

#### RF-25 · Reporte de alertas viales
- **Descripción:**
  - El conductor reporta una novedad (derrumbe, accidente, cierre, retén...) con su posición, con
    `POST /api/v1/alerts`.
  - `GET /alerts/nearby` lista las cercanas.
  - Un reporte del mismo tipo a menos de 500 m y dentro de 30 min se fusiona con el existente.
  - Se guarda el autor.
- **Criterios de aceptación:**
  1. Un reporte duplicado dentro del radio y la ventana no crea una alerta nueva.
  2. La alerta publica `truckcar.events.road-alerts`.
  3. La PWA la muestra en el mapa y en la pestaña Alertas, con sus estados de vacío, carga y error.
- **Componentes:** `community-alerts`, `truckcar-frontend` (`mapController.js`, `speechEngine.js`).
- **Estado:** **En progreso.** El servicio está en `main` (KAN-40 Finalizado). La capa de alertas en Leaflet (KAN-64)
  y el reporte por voz (KAN-65) están "En curso".

#### RF-26 · Confirmación comunitaria
- **Descripción:** otros conductores confirman la alerta con `PATCH /alerts/{alertId}/confirm`. Con 3 confirmaciones
  (`TRUCKCAR_ALERT_VALIDATION_THRESHOLD`) la alerta queda validada.
- **Criterios de aceptación:**
  1. El mismo conductor no puede votar dos veces (`409`).
  2. La tercera confirmación cambia el estado a validada.
- **Componentes:** `community-alerts` (tabla `road_alert_confirmations`).
- **Estado:** **Implementado.** Jira: KAN-61 (Finalizado).

#### RF-27 · Vencimiento de alertas
- **Descripción:** una alerta vence a las 24 h; un derrumbe, a las 6 h. Al vencer se publica `alert.expired` y la
  alerta sale del mapa.
- **Criterios de aceptación:**
  1. Una alerta vencida no aparece en `nearby`.
  2. Se publica el evento de vencimiento.
- **Componentes:** `community-alerts`.
- **Estado:** **En progreso.** Los TTL están configurados (`truckcar.alerts.ttl`). El vencimiento programado y el
  evento son KAN-62 ("En curso").

#### RF-28 · Interpretación de alertas con IA y respaldo por reglas
- **Descripción:**
  - `route-ai-agent` consume `truckcar.events.road-alerts` y clasifica el texto del reporte (tipo, severidad y
    corredor) con un modelo de lenguaje. El proveedor se elige con `TRUCKCAR_AI_PROVIDER` (`azure` por defecto, con
    el despliegue `gpt-4.1-mini`, o `bedrock`).
  - La respuesta se valida contra un esquema JSON.
  - Ante cualquier fallo, la alerta la clasifica `RuleBasedAlertInterpreter`.
  - `POST /api/v1/routes/plan` y `GET /routes/history/{plate}` exponen los planes de ruta.
- **Criterios de aceptación:**
  1. Con el modelo inaccesible (sin clave, caído o sin cuota), la alerta igual se clasifica, por reglas.
  2. Una respuesta del modelo que no cumple el esquema cuenta como fallo.
  3. Cada respaldo incrementa `truckcar_ai_fallback_total{provider,reason}`.
- **Componentes:** `route-ai-agent` (`ModelAlertInterpreter`, `RuleBasedAlertInterpreter`), `community-alerts`.
- **Estado:** **Implementado.** Verificado en EKS con Azure OpenAI: "Alerta 3 interpretada por AZURE_OPENAI" y
  `truckcar_ai_requests_total{provider="azure"}`, sin respaldo. Antes, con Bedrock denegado, se verificó el respaldo
  por reglas. Jira: KAN-91, KAN-142 y KAN-143 (Finalizado).

#### RF-29 · Botón SOS de emergencia
- **Descripción:**
  - El conductor mantiene presionado el SOS 1,5 s. La PWA envía su posición GPS y se publica `truckcar.events.sos`.
  - `notifications` emite la notificación `EMERGENCIA_SOS` con prioridad alta.
  - La torre la atiende con `PATCH /alerts/sos/{sosId}/acknowledge`.
- **Criterios de aceptación:**
  1. Un toque corto no dispara el SOS.
  2. Sin señal, el SOS se encola y se envía al reconectar.
  3. La torre ve el SOS con la posición y puede marcarlo como atendido.
  4. El rojo del SOS no se usa en ninguna otra parte de la interfaz.
- **Componentes:** `community-alerts`, `notifications`, `truckcar-frontend`.
- **Estado:** **Implementado.** Jira: KAN-131, KAN-138 y KAN-139 (Finalizado).

### 2.8 Notificaciones

#### RF-30 · Notificaciones push y por voz
- **Descripción:**
  - `notifications` consume los eventos de asignación, SOS y restricciones. Envía push por Amazon SNS y sintetiza voz
    con Amazon Polly, guardando el audio en S3.
  - `POST /api/v1/notifications/send` envía una notificación manual.
  - Cuando un canal agota sus reintentos, la notificación queda `FAILED` con su causa y se publica
    `truckcar.notifications.failed`.
- **Criterios de aceptación:**
  1. Si Polly falla, la notificación queda `FAILED` y la API no responde `500`.
  2. El push por SNS sale aunque la voz falle.
  3. Cada notificación queda consultable con `GET /notifications/{id}`.
- **Componentes:** `notifications` (`SnsPushNotifier`, `PollyVoiceSynthesizer`), SNS, Polly y S3.
- **Estado:** **Implementado.** Verificado en EKS: push por SNS. Polly está denegado en el laboratorio, y la
  notificación queda `FAILED` como se espera. Jira: KAN-120 (Finalizado); KAN-96 ("En curso").

#### RF-31 · Plantillas de notificación
- **Descripción:** el `ADMIN` gestiona las plantillas de texto por tipo de evento con `/api/v1/templates`, a través del
  gateway.
- **Criterios de aceptación:**
  1. La ruta `/templates/**` existe en el gateway y solo responde al `ADMIN`.
  2. Editar una plantilla cambia el texto de las notificaciones siguientes.
- **Componentes:** `notifications`, `api-gateway`.
- **Estado:** **En progreso.** La API existe en el servicio. La ruta en el gateway es KAN-32 ("En curso") y KAN-84
  ("Por hacer").

#### RF-32 · Bandeja de notificaciones y audio en la PWA
- **Descripción:** el conductor ve sus notificaciones (`GET /notifications/user/{userId}`) y escucha el audio de Polly
  en la app.
- **Criterios de aceptación:**
  1. La bandeja lista las notificaciones del usuario autenticado, de la más reciente a la más antigua.
  2. Una notificación con audio se reproduce con un toque; una `FAILED` muestra solo el texto.
- **Componentes:** `truckcar-frontend`, `notifications`.
- **Estado:** **Pendiente.** Jira: KAN-85 y KAN-86 ("Por hacer").

### 2.9 Operación sin señal

#### RF-33 · Cola offline e ingesta idempotente por lotes
- **Descripción:**
  - Sin señal, la PWA guarda en IndexedDB las posiciones (una cada 15 s), los hitos del viaje, las alertas y el SOS.
  - Al reconectar, envía lotes de hasta 100 eventos a `POST /sync/batch` de cada servicio (`fleets-drivers`,
    `load-allocation` y `community-alerts`).
  - Cada evento lleva un `clientEventId`, y el servidor descarta los repetidos.
- **Criterios de aceptación:**
  1. La cola sobrevive al cierre de la app.
  2. Reenviar un lote completo no duplica ningún evento.
  3. El servidor acepta hasta 200 eventos por lote y rechaza más con `400`.
  4. La pestaña Offline muestra cuántas acciones faltan por enviar.
- **Componentes:** `truckcar-frontend` (`js/offlineQueue.js`), `IngestionLedger` en los tres servicios.
- **Estado:** **Implementado.** Jira: KAN-80 y KAN-148 (Finalizado).

#### RF-34 · Mapa sin señal
- **Descripción:**
  - El Service Worker guarda las teselas que el conductor ya vio, con un tope de 100 MB y el vencimiento que indique el
    proveedor (7 días por defecto).
  - Primero se expulsan las vencidas y después las menos usadas. Nunca se precargan teselas.
- **Criterios de aceptación:**
  1. Una zona ya vista se dibuja sin red.
  2. Una zona no vista queda oscura, sin cuadros rotos.
  3. La pestaña Offline muestra la fecha real del mapa guardado.
- **Componentes:** `truckcar-frontend` (`sw.js`, `js/tileStore.js`).
- **Estado:** **Implementado.** Jira: KAN-80 (Finalizado).

### 2.10 Torre de control

#### RF-35 · Torre de control en tiempo real
- **Descripción:**
  - La torre muestra en el mapa la flota activa, con estado, carga y peso bruto en español.
  - Muestra también las cargas con sus decisiones de asignación y los SOS abiertos.
  - En el teléfono, el encabezado se adapta a 390 px o menos y no hay selector de vistas.
- **Criterios de aceptación:**
  1. Las posiciones llegan por `/topic/fleet-locations` sin consultas periódicas.
  2. "Última sincronización" no se parte en dos líneas.
  3. En el teléfono, un `ADMIN` que intenta abrir la vista del conductor vuelve a la torre.
- **Componentes:** `truckcar-frontend` (`coordinatorPanel.js`, `js/app.js`), `fleets-drivers`, `load-allocation`.
- **Estado:** **Implementado.** Evidencia: `test/roleSwitcher.test.mjs` (frontend #8). Jira: KAN-129 y KAN-106
  (Finalizado).

---

## 3. Requisitos no funcionales (RNF)

Cada RNF tiene una meta medible y el criterio con que se acepta. "Pendiente de medición" significa que el mecanismo
existe, pero falta la prueba que demuestre la meta.

### 3.1 Rendimiento y latencia

| ID | Requisito | Meta | Criterio de aceptación técnica | Estado y evidencia |
|---|---|---|---|---|
| RNF-01 | Latencia del gateway | p95 < 300 ms y errores < 1 % con 40 usuarios de torre y 160 de telemetría | Prueba de k6 con `thresholds: { http_req_duration: ['p(95)<300'], http_req_failed: ['rate<0.01'] }` sobre `GET /fleets-drivers/active` y `POST /sync/batch` | **Pendiente de medición.** El guion está diseñado en [ESCALAMIENTO_Y_ESTABILIDAD.md](../arquitectura/ESCALAMIENTO_Y_ESTABILIDAD.md) §5.2, pero no hay `load-tests/` en el repositorio. |
| RNF-02 | Ingesta por lotes `/sync/batch` | Hasta 100 eventos por petición desde la PWA (el servidor admite 200); sin señal, 1 posición cada 15 s | Un lote de 100 posiciones responde `200` y otro de 201 responde `400`. La cola crece 5 veces más despacio sin señal. | **Implementado:** `truckcar-frontend/js/offlineQueue.js:17`, `fleets-drivers/.../sync/SyncBatchRequest.java:30` y `truckcar-frontend/js/telemetry.js` (muestreo) |
| RNF-03 | Distribución de la telemetría | Posición cada 3 s; la torre recibe un mensaje agregado, no uno por camión | Con N camiones, la torre recibe un solo arreglo por ciclo en `/topic/fleet-locations` | **Implementado:** fleets-drivers #3 y frontend #6; KAN-92 |
| RNF-04 | Timeouts entre servicios | Ninguna llamada síncrona espera más de 4 s | Con el servicio destino detenido, la llamada falla en ≤ 4 s y activa su respaldo | **Parcial.** AI-fleet: 2 s de conexión y 4 s de lectura. Route-AI: TimeLimiter de 4 s. Load-Allocation → fleets-drivers: 2 s. El gateway no tiene timeouts de cliente. |
| RNF-05 | Peso de la PWA | Sin framework ni compilación en el cliente; CSS ≈20 KB | Lighthouse en un perfil móvil sin errores de recursos de terceros que bloqueen el renderizado | **Implementado:** `truckcar-frontend/css/tailwind.css` compilado en el `Dockerfile`, sin `cdn.tailwindcss.com` (rediseño, fase 6) |

### 3.2 Disponibilidad y resiliencia

| ID | Requisito | Meta | Criterio de aceptación técnica | Estado y evidencia |
|---|---|---|---|---|
| RNF-06 | Respaldo por reglas ante fallos de la IA | Ninguna alerta queda sin clasificar | Con el proveedor caído, sin credenciales o con cuota agotada (`429`, `401`, `403` o `400`), la alerta se clasifica por reglas en el mismo flujo y sube `truckcar_ai_fallback_total`. No se reintentan los `4xx` ni el *throttling*. | **Implementado:** `Route-AI-agent/.../ModelAlertInterpreter.java`, `TransientModelFailure.java` y Route-AI #2. Verificado en EKS (Bedrock denegado) y, con Azure OpenAI activo, sin respaldo. |
| RNF-07 | Circuit breaker y reintentos | Una dependencia caída no tumba al que la llama | Resilience4j: reintentos con backoff exponencial y jitter, luego circuit breaker y luego TimeLimiter. El circuito abre tras fallos consecutivos y se recupera solo. | **Parcial.** Hay circuit breaker y reintentos en AI-fleet (`application.yml:57-93`), en Route-AI (`azureOpenAi`, `bedrock`) y en Notifications (`snsPush`, `pollyVoice`). Notifications usa los valores por defecto (500 ms fijos, sin jitter; KAN-121 "Por hacer"). El gateway no tiene circuit breaker. |
| RNF-08 | Cola offline con backoff y jitter | Sin tormentas de reintentos al volver la red | *Equal jitter*: entre la mitad y el total de 2 s × 2ⁿ, con tope de 5 min, y se reinicia al volver la red | **Implementado** en la cola offline (`truckcar-frontend/js/offlineQueue.js:207` y `:299`). **Ausente** en la reconexión del WebSocket (RF-10). |
| RNF-09 | Entrega garantizada de eventos | Ningún cambio de estado se pierde entre la base de datos y Kafka | Outbox transaccional publicado por un solo pod a la vez (`pg_try_advisory_xact_lock`). Los consumidores reintentan 3 veces y después envían a `*.DLT`. | **Implementado** en Load-Allocation, fleets-drivers y Community-Alerts (`OutboxEventRepository.java:23`, `KafkaDeadLetterConfig.java`). Falta en User-Identity (KAN-56). La purga y la métrica de lag (KAN-57 y KAN-58) están "Por hacer". |
| RNF-10 | Idempotencia de los consumidores | Un evento repetido no produce un efecto duplicado | Reenviar el mismo `eventId` no crea una segunda notificación ni una segunda transición | **Parcial.** Load-Allocation la obtiene de su máquina de estados. Notifications no descarta un `eventId` repetido. |
| RNF-11 | Salud y despliegue sin corte | Cero caídas en un despliegue continuo | Probes de arranque, vida y disponibilidad en los 9 servicios; `RollingUpdate` con `maxUnavailable: 0`; PDB `minAvailable: 1` | **Parcial.** Las probes y el rolling update están en todos (`k8s/base/apps/*.yaml`). Los PDB solo están en el gateway, fleets-drivers y el frontend (`k8s/base/autoscaling.yaml`). |

### 3.3 Escalamiento y carga

| ID | Requisito | Meta | Criterio de aceptación técnica | Estado y evidencia |
|---|---|---|---|---|
| RNF-12 | Autoescalado horizontal por CPU | Las cargas de mayor tráfico escalan solas | HPA al 70 % de CPU: gateway de 2 a 6 réplicas, fleets-drivers de 2 a 8 y frontend de 2 a 4 | **Implementado** en EKS: `k8s/base/autoscaling.yaml` y metrics-server, verificado en el clúster |
| RNF-13 | Escalamiento por eventos con KEDA | El escalado responde al tráfico y al lag, no solo a la CPU | `ScaledObject` para el gateway (150 RPS por réplica, de 1 a 6), fleets-drivers (400 sesiones STOMP por réplica, de 1 a 8) y Notifications, Route-AI y AI-fleet (lag de Kafka de 50, 20 y 20; de 1 a 3). Durante la meseta de k6 el gateway pasa de 1 a 2 o más réplicas y vuelve a 1 tras el `cooldownPeriod`. | **Pendiente.** Diseñado en [ESCALAMIENTO_Y_ESTABILIDAD.md](../arquitectura/ESCALAMIENTO_Y_ESTABILIDAD.md) §3. No hay `ScaledObject` en `k8s/`. |
| RNF-14 | Prerrequisitos del escalamiento por eventos | Que escalar sirva | Gauge `truckcar_websocket_sessions_active` en fleets-drivers; candado distribuido en `WaitingLoadsRetryScheduler`; 6 a 12 particiones en `events.load-allocation` y `events.vehicle-status` (hoy hay 3); `preStop` y una ventana de 5 min antes de reducir réplicas de fleets-drivers | **Pendiente:** ESCALAMIENTO_Y_ESTABILIDAD §6, puntos 3 a 6 |
| RNF-15 | Autoescalador de nodos | Los pods que crea el escalado tienen dónde correr | AKS con `--enable-cluster-autoscaler --min-count 1 --max-count 3` (B4ms); en EKS, un nodegroup con mínimo y máximo distintos. Un pod pendiente agrega un nodo en menos de 5 min, y el nodo se retira tras unos 10 min de holgura. | **Pendiente.** Azure no está desplegado. En EKS el nodegroup es fijo, con 2 nodos t3.large. |
| RNF-16 | Conexiones a la base de datos | Escalar réplicas no agota las conexiones de PostgreSQL | Hikari con 5 conexiones por pod, detrás de PgBouncer en modo `transaction` con un pool de 10 por base | **Implementado:** `k8s/base/platform-config.yaml` y `k8s/base/data/pgbouncer.yaml` (KAN-103) |

### 3.4 Seguridad

| ID | Requisito | Meta | Criterio de aceptación técnica | Estado y evidencia |
|---|---|---|---|---|
| RNF-17 | Autenticación con JWT | Tokens de vida corta y validación central | Access token de 15 min y refresh token de 7 días, rotado y de un solo uso; el gateway valida la firma y la expiración | **Implementado con HMAC** (`Keys.hmacShaKeyFor` en `User-Identity/.../JwtProvider.java`). La migración a RS256 con JWKS es KAN-12 y KAN-35 a KAN-38 ("Por hacer"). |
| RNF-18 | Desinfección de prompts contra *prompt injection* | El texto del conductor no puede dar instrucciones al modelo | Se quitan los caracteres de control y las etiquetas `<alert>`, el texto se acota a 600 caracteres y va entre `<alert>…</alert>`. El prompt de sistema lo declara dato no confiable y la respuesta se valida contra el esquema JSON. Un texto con "ignora las instrucciones…" se clasifica como alerta normal. | **Implementado:** `ModelAlertInterpreter.sanitize` y `MAX_ALERT_CHARS = 600` (`Route-AI-agent/.../service/ModelAlertInterpreter.java:40` y `:188`) |
| RNF-19 | Control de admisión en el gateway | Un cliente no puede saturar la plataforma | `RequestRateLimiter` con Redis, por usuario, que responde `429` con `Retry-After`; la PWA espera ese tiempo | **Parcial.** KAN-31 limita `/api/v1/auth/login`, `/register` y `/refresh` por IP (`RequestRateLimiter` con Redis, `429` con `Retry-After`; la PWA lo explica y un `429` al renovar no cierra la sesión). Falta el límite por usuario en el resto de la API. |
| RNF-20 | WebSocket sin credenciales en la URL | El JWT no queda en los registros ni en el historial | Ticket aleatorio de un solo uso, con vida de 30 s (`ws-ticket-ttl`) y canjeado con `GETDEL`; `Origin` validado en el handshake | **Implementado:** api-gateway #2 y #3, KAN-93 y KAN-122 |
| RNF-21 | Aislamiento de red y de datos | Cada servicio solo ve lo que necesita | NetworkPolicies `default-deny` de entrada; el ALB solo llega a `:8000`, `:8080` y `:8090`; un esquema y un rol de base de datos por servicio; `verify-isolation.sh` en el CI | **Implementado:** `k8s/base/network-policies.yaml`, `docker/postgres/init-service-schemas.sql` y KAN-75. Limitar el `:8000` del gateway solo al ALB es KAN-117 ("Por hacer"). |
| RNF-22 | Secretos fuera del repositorio | No hay claves en git | Secret `truckcar-secrets` creado desde `.env` (en `.gitignore`); credenciales de AWS por el LabRole e IMDSv2 en los pods y por los secretos de la organización en el CI | **Implementado:** `k8s/README.md` y KAN-100 |
| RNF-23 | Cifrado en tránsito | HTTPS y WSS para la PWA; TLS hacia los datos gestionados | La PWA se abre por HTTPS (el navegador lo exige para el GPS); PgBouncer → RDS con TLS; Redis gestionado con TLS y contraseña | **Parcial.** HTTPS con el túnel de Cloudflare (KAN-104) y TLS hacia RDS. Falta el HTTPS definitivo con dominio (KAN-118), la redirección de HTTP a HTTPS (KAN-135) y el TLS de Redis (KAN-116). |
| RNF-24 | Dependencias seguras | Sin vulnerabilidades conocidas críticas | Dependabot o Trivy en el CI que falle ante una CVE crítica | **Pendiente:** KAN-76 ("Por hacer") |

### 3.5 Compatibilidad y usabilidad en campo

| ID | Requisito | Meta | Criterio de aceptación técnica | Estado y evidencia |
|---|---|---|---|---|
| RNF-25 | Teléfonos de gama baja y media | La app es fluida en teléfonos con poca memoria y CPU | Sin framework; el mapa oscuro sin efectos; un solo acento; animaciones solo en `transform` y `opacity`; pulsación de 140 ms; se respetan `prefers-reduced-motion`, `prefers-reduced-transparency` y `prefers-contrast` | **Implementado:** rediseño de la PWA, auditoría final de **15/20** (`truckcar-frontend/docs/redesign/AUDITORIA-FINAL.md`, frente a 10/20 al inicio). Falta medirlo en un equipo de gama baja real. |
| RNF-26 | Redes 3G/4G intermitentes | Ninguna acción del conductor se pierde por falta de señal | Con la red desconectada, iniciar el viaje, reportar una alerta y entregar quedan en cola. Al reconectar se envían en lotes, sin duplicados (RF-33 y RNF-08). | **Implementado** el mecanismo. **Pendiente de medición** con una red 3G simulada. |
| RNF-27 | Legibilidad y áreas táctiles | Uso con una mano y en movimiento | Texto de 14 px o más (12 px solo en la barra inferior); áreas táctiles de 44 px o más (56 px en la barra inferior); contraste del texto secundario de 5,6:1; toda advertencia con triángulo y texto, no solo color | **Implementado:** `truckcar-frontend/css/tokens.css` y `docs/redesign/REPORTE.md` §1 y §3 |
| RNF-28 | Navegadores y plataformas | Chrome para Android y Safari para iOS, instalable como PWA | GPS por HTTPS, `viewport-fit=cover` con áreas seguras, sin zoom al enfocar campos (16 px), sin resaltado al tocar, `theme-color` por esquema | **En progreso.** Verificado con la emulación móvil de Chromium y con iPhone en la torre. El GPS del conductor en un iPhone real es KAN-107 ("Por hacer"). |

### 3.6 Observabilidad y mantenibilidad

| ID | Requisito | Meta | Criterio de aceptación técnica | Estado y evidencia |
|---|---|---|---|---|
| RNF-29 | Métricas y trazas | Diagnosticar una petición de punta a punta | Actuator y Micrometer/Prometheus en los 9 servicios; OpenTelemetry con `X-Correlation-Id`; Tempo, Prometheus y Grafana en local | **Implementado en local** (KAN-81 y KAN-82). Grafana y Loki en compose: KAN-83 ("En curso"). En EKS el trazado está apagado (`MANAGEMENT_TRACING_ENABLED: "false"`) porque no hay colector. |
| RNF-30 | Integración continua | Ningún cambio llega a `main` sin pruebas | `mvnw verify` por servicio; imágenes en GHCR y ECR; prueba de humo `docker compose down -v && up` con aislamiento de red | **Implementado:** KAN-71, KAN-74, KAN-75, KAN-101 y KAN-149. `pg_isready` por TCP en el CI de cada servicio: KAN-115 ("En curso"). |
| RNF-31 | Ciclo de vida del entorno de la nube | Montar y desmontar sin recursos huérfanos ni costos ocultos | `scripts/teardown.sh` borra, en orden, el ALB, los discos EBS, la RDS (con su grupo de subredes y su grupo de seguridad) y el clúster | **Implementado:** DI #11 y #13 (19 pruebas del arnés y un *dry-run* contra el laboratorio real). El desmontaje real es KAN-109 ("Por hacer"). |

---

## 4. Matriz de estado y avance del proyecto

### 4.1 Matriz por módulo y requisito

**Método del porcentaje:** por cada historia de Jira, una subtarea "Finalizado" vale 1, una "En curso" vale 0,5 y una
"Por hacer" vale 0. Una historia sin subtareas vale según su propio estado. La columna Estado viene de la sección 2 y
se apoya en el código, no solo en Jira.

| Módulo | Requisito | Estado | Evidencia en el repositorio | Jira | % (Jira) |
|---|---|---|---|---|---|
| Identidad | RF-01 Registro | Implementado | `User-Identity` `/auth/register`, `AdminBootstrap` | KAN-10 | 75 % |
| Identidad | RF-02 Sesión y tokens | En progreso | `JwtProvider`, `/auth/refresh`, `/auth/logout` | KAN-10, KAN-29 | 75 % |
| Identidad | RF-03 RBAC | En progreso | `canUseDriverView` y controles por rol | KAN-13, KAN-30, KAN-42 | 63 % |
| Gateway | RF-04 Punto único de confianza | Implementado | `api-gateway/.../application.yaml`, `GatewayOriginRoutingTest` | KAN-11 | 33 % |
| Identidad | RF-05 Verificación de cuentas | Pendiente | — | KAN-98 | 0 % |
| Transversal | RF-06 Errores 400 | Implementado | `ClientErrorHandlingTest` × 8 | KAN-97, KAN-144 | 100 % |
| Flota | RF-07 Estado del conductor y del vehículo | Implementado | `FleetDriverService`, `DriverStatusValidationTest` | KAN-94, KAN-145 | 100 % |
| Flota | RF-08 Carga a bordo y peso bruto | Implementado | `FleetDriverServiceActiveLoadsTest` | KAN-145, KAN-146 | 100 % |
| Telemática | RF-09 Telemetría en vivo | Implementado | `WsTicketController`, `/topic/fleet-locations` | KAN-20, KAN-92, KAN-93, KAN-122 | 61 % |
| Telemática | RF-10 Reconexión | En progreso | `truckcar-frontend/js/telemetry.js` (sin jitter) | KAN-67 | 50 % |
| Flota | RF-11 Consulta de la flota | Implementado | `/active`, `/available`, `/drivers/{id}` | KAN-66 | 100 % |
| Flota | RF-12 Vehículo desde la torre | Pendiente | — | KAN-95, KAN-119 | 0 % |
| Cargas | RF-13 Publicación | En progreso | `POST /loads`, `generatorPanel.js` | KAN-14, KAN-46 | 50 % |
| Cargas | RF-14 Ciclo de vida | Implementado | `FreightLoadService`, `@Version`, `AssignmentTimeoutScheduler` | KAN-14, KAN-43, KAN-44 | 50 % |
| Cargas | RF-15 Respuesta a la propuesta | En progreso | `/assignment/accept`, `/assignment/reject` | KAN-55 | 0 % |
| Cargas | RF-16 POD | Implementado | `/proof-of-delivery/upload-urls`, límites en `application.yml` | KAN-15, KAN-48, KAN-78 | 83 % |
| Cargas | RF-17 Seguimiento público | Implementado | `truckcar.tracking.*` (HMAC, 48 h / 6 h) | KAN-132 | 100 % |
| Cargas | RF-18 Línea de tiempo | Pendiente | — | KAN-47 | 0 % |
| Asignación | RF-19 Motor por puntaje | Implementado | `FleetScoringOptimizer` | KAN-16, KAN-54 | 70 % |
| Asignación | RF-20 Asignación con modelo de lenguaje | Pendiente | — | *sin ticket* | 0 % |
| Restricciones | RF-21 Gestión | En progreso | `/api/v1/restrictions` | KAN-39, KAN-60 | 67 % |
| Restricciones | RF-22 Validación de ruta | Implementado | `/validate-route` sobre geometría real | KAN-19, KAN-147 | 67 % |
| Navegación | RF-23 Avisos de gálibo | Implementado | `hud-galibo-real.png` | KAN-137 | 100 % |
| Navegación | RF-24 Navegación guiada | Implementado | `js/navigation.js`, HUD | KAN-130, KAN-70 | 100 % |
| Alertas | RF-25 Reporte | En progreso | `POST /alerts`, deduplicación 500 m / 30 min | KAN-18, KAN-64, KAN-65 | 70 % |
| Alertas | RF-26 Confirmación | Implementado | `road_alert_confirmations`, `409` | KAN-61 | 100 % |
| Alertas | RF-27 Vencimiento | En progreso | `truckcar.alerts.ttl` | KAN-62 | 50 % |
| IA vial | RF-28 Interpretación con respaldo | Implementado | `ModelAlertInterpreter`, `RuleBasedAlertInterpreter` | KAN-91 | 100 % |
| Alertas | RF-29 SOS | Implementado | `/alerts/sos`, `EMERGENCIA_SOS` | KAN-131 | 100 % |
| Notificaciones | RF-30 Push y voz | Implementado | `SnsPushNotifier`, `PollyVoiceSynthesizer`, `FAILED` | KAN-96, KAN-120 | 50 % |
| Notificaciones | RF-31 Plantillas | En progreso | `/api/v1/templates` en el servicio | KAN-32, KAN-84 | 25 % |
| Notificaciones | RF-32 Bandeja y audio | Pendiente | — | KAN-85, KAN-86 | 0 % |
| Offline | RF-33 Cola e ingesta | Implementado | `offlineQueue.js`, `IngestionLedger` | KAN-23, KAN-80, KAN-148 | 90 % |
| Offline | RF-34 Mapa sin señal | Implementado | `sw.js`, `tileStore.js` | KAN-80 | 100 % |
| Torre | RF-35 Torre en tiempo real | Implementado | `coordinatorPanel.js`, `roleSwitcher.test.mjs` | KAN-129, KAN-106 | 100 % |
| Nube | Despliegue en AWS EKS | Implementado | `k8s/overlays/aws-eks-lab`, `scripts/teardown.sh` | KAN-87 | 92 % |
| Nube | HTTPS para la PWA | En progreso | `k8s/overlays/aws-eks-lab/optional/cloudflare-tunnel.yaml` | KAN-128 | 60 % |
| Nube | Operación segura (red, TLS, CI) | En progreso | — | KAN-90 | 17 % |
| Nube | Runbooks del Learner Lab | Pendiente | `k8s/README.md` (parcial) | KAN-89 | 0 % |
| Nube | Cierre del laboratorio y datos de demostración | Pendiente | — | KAN-88 | 0 % |
| Nube | Escalamiento por eventos (RNF-13 a RNF-15) | Pendiente | `docs/arquitectura/ESCALAMIENTO_Y_ESTABILIDAD.md` (diseño) | *sin ticket* | 0 % |

### 4.2 Resumen del avance global

**Requisitos de este documento:**

| | Implementado | En progreso | Pendiente | Total |
|---|---|---|---|---|
| Funcionales (RF) | 21 | 9 | 5 | 35 |
| No funcionales (RNF) | 19 | 6 | 6 | 31 |

En los RNF, "Parcial" cuenta como En progreso. "Pendiente de medición" cuenta como Implementado cuando el mecanismo
existe (RNF-26) y como Pendiente cuando tampoco existe (RNF-01).

**Jira (proyecto KAN, 149 tickets):**

| Tipo | Total | Finalizado | En curso | Por hacer |
|---|---|---|---|---|
| Épicas | 6 | 0 | 0 | 6 |
| Historias | 32 | 7 | 21 | 4 |
| Subtareas | 110 | 58 | 19 | 33 |

**Avance ponderado de las subtareas:** (58 + 0,5 × 19) / 110 ≈ **61 %**.

| Épica | Historias | Subtareas | Avance |
|---|---|---|---|
| KAN-4 Autenticación, seguridad y gateway | 6 | 18 | 50 % |
| KAN-5 Ciclo de vida de cargas y POD | 3 | 10 | 70 % |
| KAN-6 Asignación inteligente e inteligencia vial | 6 | 20 | 65 % |
| KAN-7 Telemática GPS y mapa | 4 | 14 | 68 % |
| KAN-8 Orquestación, red, DevOps y PWA offline | 10 | 42 | 67 % |
| KAN-9 Notificaciones multicanal | 2 | 5 | 20 % |

**Repositorio:** a la fecha de corte, todos los PRs de los servicios y de la PWA están fusionados en `main`. Solo queda
abierto el PR #16 de Deployment-Infrastructure (diagramas de arquitectura).

**Lectura del avance:**
- **El flujo principal funciona de punta a punta y está desplegado en AWS EKS:** publicar, asignar, navegar con
  gálibo, transmitir el GPS, reportar alertas, SOS, entregar con POD y hacer el seguimiento público.
- **Lo que falta se concentra en tres frentes:**
  - las pantallas que todavía no consumen APIs existentes (RF-12, RF-15, RF-18, RF-21 y RF-32);
  - el endurecimiento (RS256, límite de tasa, TLS de Redis, HTTPS definitivo y escaneo de dependencias);
  - el escalamiento por eventos y su prueba de carga (RNF-01 y RNF-13 a RNF-15).

### 4.3 Inconsistencias entre Jira y el repositorio

| # | Hallazgo | Acción sugerida |
|---|---|---|
| 1 | Las 6 épicas están "Por hacer", aunque 7 historias y 58 subtareas están finalizadas | Pasar las épicas a "En curso" |
| 2 | ~~KAN-31 (límite de tasa en `/api/v1/auth/**`) está "En curso", pero no hay `RequestRateLimiter` en el gateway de `main`~~ | Resuelto: `RequestRateLimiter` por IP en login, register y refresh (rama `feat/kan-31-rate-limiter`) |
| 3 | KAN-67 (reconexión con backoff) está "En curso": el backoff existe, el jitter no | Dejar en la descripción que lo pendiente es el jitter |
| 4 | El nombre de la épica KAN-6 promete "asignación inteligente por IA", pero el motor es determinista y no hay ticket para un modelo (RF-20) | Crear la historia del RF-20 con la decisión del equipo, o renombrar la épica |
| 5 | No hay tickets para el escalamiento por eventos (KEDA, gauge de sesiones, candado del reintento, particiones, prueba de k6) | Crear la historia con las subtareas de ESCALAMIENTO_Y_ESTABILIDAD §6 |
| 6 | KAN-1, KAN-2 y KAN-3 son tickets de plantilla ("Task 1", "Task 2", "Subtask 2.1"); KAN-2 está "En curso" | Archivarlos o borrarlos: alteran los conteos |
| 7 | El objetivo de nube del curso menciona Azure (`azure-students`), pero el despliegue real y verificado es AWS EKS; Azure está preparado y sin desplegar | Decidir si Azure se despliega además de AWS y reflejarlo en KAN-87 o en una historia aparte |
| 8 | KAN-12 (RS256 con JWKS) figura como "Sprint 6", pero sigue "Por hacer" y el código firma con HMAC | Replanificar o mover al backlog |

---

## Anexo A · Trazabilidad de los eventos de Kafka

| Tópico (`truckcar.events.*`) | Productor | Consumidores | Requisitos |
|---|---|---|---|
| `load-allocation` | load-allocation | fleets-drivers, ai-fleet-allocation, notifications | RF-08, RF-14, RF-19 |
| `vehicle-status` | fleets-drivers | ai-fleet-allocation | RF-07, RF-19 |
| `fleet-allocation-results` | ai-fleet-allocation | load-allocation | RF-14, RF-19 |
| `assignment-notifications` | load-allocation | notifications | RF-15, RF-30 |
| `road-alerts` | community-alerts | route-ai-agent | RF-25, RF-28 |
| `sos` | community-alerts | notifications (alta prioridad) | RF-29 |
| `road-restrictions` | routing-restrictions | route-ai-agent, notifications | RF-21 |
| `route-plans` | route-ai-agent | — | RF-28 |
| `user-events` | user-identity | — (falta su outbox, KAN-56) | RF-01 |

Todos los tópicos tienen 3 particiones y su tópico `*.DLT`.
