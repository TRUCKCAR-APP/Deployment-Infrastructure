# TruckCar · Guía para probar la plataforma

TruckCar conecta a los generadores de carga con conductores de carga pesada y acompaña el viaje de punta a punta:

publicación → asignación automática → aceptación → navegación → alertas y SOS → entrega con evidencia → seguimiento del envío

Todo se hace desde la app: no hacen falta scripts ni llamadas a la API.

- **La primera parte (§1 a §3)** es para quien prueba.
- **El anexo** es para el equipo, que enciende el entorno antes de la ventana de prueba.

## 1. Acceso

| | |
|---|---|
| **Dirección** | `https://<dirección-de-la-sesión>.trycloudflare.com` (el equipo la envía al inicio de la ventana de prueba; cambia en cada sesión) |
| **Navegador** | Chrome, Edge o Safari, en el computador o en el teléfono |
| **Herramientas de prueba** | Agregue `?demo=1` al final de la dirección para ver "Simular GPS", "Simular foto" y "Simular pérdida de señal". Sirven para recorrer una ruta sin moverse del escritorio. |

**Cada rol necesita su propia sesión.** Un navegador guarda una sola sesión para todas sus pestañas. Para tener dos
roles abiertos a la vez, use un navegador distinto, una ventana de incógnito o el teléfono.

**Cuentas.** Las del generador y el conductor se crean en la pantalla de inicio, con **Crear cuenta**. Las de la torre
las entrega el equipo:

| Rol | Cuenta | Qué puede hacer |
|---|---|---|
| Generador de carga | Créela con **Crear cuenta → Generador de carga** | Publicar cargas, ver la prueba de entrega y compartir el seguimiento |
| Conductor | Créela con **Crear cuenta → Conductor** | Registrar su camión, recibir y aceptar cargas, navegar, reportar alertas, activar el SOS y entregar |
| Coordinador (torre de control) | `torre@truckcar.demo` | Flota en vivo, decisiones del motor, SOS y restricciones viales |
| Administrador | La entrega el equipo | Todo lo del coordinador, más **Usuarios**: cambiar roles y activar, verificar o suspender cuentas |

**Ya hay tres conductores de ejemplo** en Medellín, Cali y Bucaramanga. Por eso, en una carga que salga de Bogotá el
motor elige al conductor que usted registre en Bogotá. A ellos los verá detrás, en la lista de candidatos.

## 2. Recorrido sugerido (unos 20 minutos)

### Paso 1 · El conductor registra su camión

1. En el **teléfono** (o en una ventana con `?demo=1`): **Crear cuenta → Conductor**.
2. En la pestaña **Vehículo**, toque **Registrar mi vehículo**. Por ejemplo:

   | Campo | Valor |
   |---|---|
   | Placa | ABC-123 |
   | Tipo de vehículo | Tractocamión 3S3 |
   | Altura total | 4,10 m |
   | Capacidad de carga | 34 t |
   | Tara | 15 t |
   | Dónde está ahora | "GPS de este dispositivo" en el teléfono, o **Bogotá** en un computador |

3. **Esperado:** "Vehículo registrado: ya puede recibir cargas" y el interruptor **Disponible para cargas** encendido.
4. **Para comprobar las validaciones:**
   - una placa mal escrita o una altura de 7 m se rechazan en el formulario;
   - una placa que ya tiene otro conductor se rechaza al guardar.

### Paso 2 · El generador publica una carga

1. En otra sesión: **Crear cuenta → Generador de carga**.
2. Pulse **Publicar nueva carga** y llene el formulario. Por ejemplo:
   - 25 t de cemento, **Tractomula 3S3**;
   - **Bogotá → Tunja** (en esa ruta ya hay un puente de gálibo registrado: ver el paso 4);
   - presupuesto de 4.500.000.
3. **Esperado:** la carga aparece en "Mis envíos" y en unos segundos pasa a **Propuesta**, sin que nadie intervenga.

### Paso 3 · La torre ve la decisión del motor

1. En otra sesión, entre con `torre@truckcar.demo`.
2. En **Evaluación de despacho**, la carga dice "Propuesta" con el nombre de su conductor.
3. En **Decisiones del motor** aparecen los candidatos:
   - **su conductor primero**, con el puntaje más alto;
   - **los de ejemplo detrás**, con su distancia en vacío;
   - **el Turbo descartado**: "Tipo de vehículo no coincide".
4. **Cómo decide el motor:**
   - **Primero filtra:** conductor ocupado, RUNT vencido, cadena de frío, tipo de camión y capacidad.
   - **Después puntúa:** 50 % cercanía al origen, 30 % aprovechamiento de la capacidad y 20 % calificación.
   - Si nadie cumple, la carga queda en espera y el motor reintenta cada 2 minutos.
   - **Ejecutar matching con IA** lo fuerza.

### Paso 4 · El conductor acepta, viaja y recibe el aviso de gálibo

1. **Aceptar la carga.** En la pestaña **Carga** (con un punto ámbar), toque **Aceptar carga y ver ruta**. Hágalo
   antes de 5 minutos: si no responde, la propuesta vence y el motor la ofrece al siguiente candidato.
2. **Iniciar el viaje** con **Iniciar viaje y navegación**.
   - **Esperado:** en la pestaña Vehículo, el peso bruto pasa a 40 t (15 de tara más 25 de carga).
   - **Esperado:** en la torre, el conductor aparece "En tránsito".
3. **Recorrer la ruta.** Con `?demo=1`, pulse **Simular GPS** y abra **Navegar**.
   - **Esperado:** el HUD con la maniobra, la distancia y la altura del camión.
   - **A los 8 km:** "**Gálibo de 3,80 m … su vehículo mide 4,10 m**", con aviso por voz.
   - **En la torre:** el camión se mueve en vivo.
4. **Probar una restricción propia** (opcional): créela en la torre (paso 7) sobre la ruta y vuelva a navegar.

### Paso 5 · Alertas, sin señal y SOS

1. **Reportar una alerta:** **Reportar en la vía** → elija el tipo → enviar.
   - Otro conductor, o la torre, puede **Confirmarla**.
   - Un mismo conductor no puede confirmar dos veces.
2. **Perder la señal:** pestaña **Offline** → **Simular pérdida de señal**. Después, **mantenga presionado el SOS 1,5
   segundos**.
   - **Esperado:** "Sin señal: el aviso se enviará al recuperar la señal" y un número sobre **Offline**.
3. **Recuperar la señal:** **Terminar la simulación sin señal**.
   - **Esperado:** la cola se envía sola.
   - **Esperado:** la torre muestra la franja del SOS con **Atender**.

### Paso 6 · Entrega con evidencia y seguimiento

1. **Registrar la entrega.** En el conductor: **Carga → Llegué: registrar entrega**.
   - Escriba el nombre de quien recibe y firme.
   - Tome una foto, o use **Simular foto** con `?demo=1`.
   - Pulse **Confirmar entrega**.
2. **Ver la prueba de entrega.** En el generador: **Mis envíos** → la carga **Entregada** → **Ver prueba de entrega
   (POD)**, con quién recibió, la firma y la foto.
3. **Seguimiento público.** Pulse **Generar enlace de seguimiento público** → **Copiar enlace** y ábralo en una ventana
   privada.
   - **Esperado:** el envío sin cuenta ni sesión, con la placa enmascarada y sin datos personales.

### Paso 7 · Administración desde la torre

1. **Restricciones** (coordinador o administrador): **Nueva restricción**.
   - Elija el tipo (gálibo, peso bruto, peso por eje, cierre) y escriba el valor y el corredor.
   - **Toque el punto exacto sobre la vía** en el mapa: la app avisa a las rutas que pasan a menos de 60 m.
   - Para quitarla, use **Desactivar**.
2. **Usuarios** (solo administrador): la lista de cuentas con filtros (pendientes, conductores, generadores, torre).
   - **Cambiar el rol:** el cambio aplica en el próximo inicio de sesión.
   - **Verificar una cuenta pendiente, suspender o reactivar.**
   - Su propia cuenta no se puede modificar, para no quedarse sin acceso.

## 3. Qué hay detrás

| Componente | Qué hace |
|---|---|
| **Despliegue** | Amazon EKS con 10 componentes: 9 microservicios Spring Boot y la PWA. Base de datos RDS PostgreSQL con PostGIS, evidencias en S3, notificaciones push por SNS. |
| **Eventos** | Kafka, con outbox transaccional: publicar, asignar, aceptar y entregar son eventos entre servicios. |
| **Telemetría** | WebSocket seguro abierto con un ticket de un solo uso. El JWT nunca va en la URL. RabbitMQ reparte las posiciones a la torre. |
| **IA vial** | `route-ai-agent` clasifica las alertas con un modelo de lenguaje y desinfecta el texto contra prompt injection. En este laboratorio el modelo no está disponible, así que responde el **respaldo por reglas**, sin perder ninguna alerta. |
| **Sin señal** | Cola en el teléfono, envío por lotes al reconectar y descarte de duplicados en el servidor. |

Diagramas en [docs/arquitectura/ARQUITECTURA.md](../arquitectura/ARQUITECTURA.md).

---

## Anexo · Para el equipo: encender el entorno en la ventana de prueba

El Learner Lab se apaga al terminar cada sesión (como máximo 4 horas) y la dirección del túnel cambia en cada
encendido. Se acuerda con el profesor un horario y se enciende unos 20 minutos antes.

1. **Iniciar la sesión del Learner Lab.** Actualizar `~/.aws/credentials` y los secretos `AWS_*` de la organización
   en GitHub.
2. **Subir los nodos:**

   ```bash
   aws eks update-nodegroup-config --cluster-name truckcar-cluster --nodegroup-name ng-truckcar --region us-east-1 \
     --scaling-config minSize=2,maxSize=2,desiredSize=2
   ```
3. **Esperar a que todos los pods estén 1/1:** `kubectl -n truckcar get pods`.
4. **Obtener la dirección nueva:** `kubectl -n truckcar-tunnel logs deploy/cloudflared | grep trycloudflare`. Poner
   esa URL en los orígenes del overlay local, aplicar y reiniciar los servicios: [k8s/README.md](../../k8s/README.md),
   "HTTPS de prueba en el Learner Lab".
5. **Dejar los datos de ejemplo**, idempotente: crea `torre@truckcar.demo`, los conductores de ejemplo y el puente de
   gálibo Bogotá → Tunja.

   ```bash
   node scripts/demo-lab/preparar-demo.mjs http://<alb>.us-east-1.elb.amazonaws.com
   ```

   La contraseña de las cuentas de ejemplo queda en `TRUCKCAR_DEMO_PASSWORD` del `.env`.
6. **Enviar al profesor la dirección**, la contraseña de `torre@truckcar.demo` y, si se acordó, la del administrador.
7. **Al terminar la ventana**, bajar los nodos a 0 (`minSize=0,desiredSize=0`).
   - La sesión vence a las 4 horas: si la prueba sigue, reinicie la sesión antes y envíe la dirección nueva.
