#!/usr/bin/env node
// Deja el entorno desplegado (EKS del Learner Lab) listo para la demostración de punta a punta.
//
// Qué hace, siempre por la API pública del gateway y con la cuenta ADMIN:
//   1. Crea o actualiza las cuentas de la demo (coordinador, generador y tres conductores), activas y con su rol.
//   2. Registra el vehículo, el estado ACTIVO y la posición de tres conductores de ejemplo, en Medellín, Cali y
//      Bucaramanga (cualquier conductor nuevo lo hace desde la pestaña Vehículo de la app).
//   3. Cierra lo que quedó abierto: cancela las cargas sin viaje, entrega las que siguen en tránsito con un conductor
//      de la demo o de prueba y atiende los SOS pendientes.
//   4. Publica el puente de gálibo de la demo sobre la ruta real (OSRM), a 8 km del origen.
//
// No imprime contraseñas ni tokens. Lee TRUCKCAR_ADMIN_PASSWORD de .env y genera TRUCKCAR_DEMO_PASSWORD en .env si
// no existe. Se puede correr las veces que haga falta: es idempotente.
//
// Uso, desde la raíz del proyecto:
//   node scripts/demo-lab/preparar-demo.mjs <url-del-gateway>
//   node scripts/demo-lab/preparar-demo.mjs http://<alb>.elb.amazonaws.com
// Variables opcionales: DEMO_ORIGIN="lat,lon" y DEMO_DESTINATION="lat,lon" (por defecto, Bogotá y Tunja, la ruta del
// guion en docs/demo/GUION_DEMO_EKS.md).

import { randomBytes } from 'node:crypto';
import { appendFileSync, existsSync, readFileSync } from 'node:fs';

const BASE = (process.argv[2] || '').replace(/\/+$/, '');
if (!/^https?:\/\//.test(BASE)) {
  console.error('Uso: node scripts/demo-lab/preparar-demo.mjs <url-del-gateway>');
  process.exit(2);
}

const ENV_FILE = '.env';
const env = readEnv();
if (!env.TRUCKCAR_ADMIN_PASSWORD) fail('Falta TRUCKCAR_ADMIN_PASSWORD en .env');
if (!env.TRUCKCAR_DEMO_PASSWORD) {
  env.TRUCKCAR_DEMO_PASSWORD = randomBytes(18).toString('base64').replace(/[^A-Za-z0-9]/g, '').slice(0, 14);
  appendFileSync(ENV_FILE, `\nTRUCKCAR_DEMO_PASSWORD=${env.TRUCKCAR_DEMO_PASSWORD}\n`);
  console.log('Contraseña de la demo generada en .env (TRUCKCAR_DEMO_PASSWORD).');
}
const PASSWORD = env.TRUCKCAR_DEMO_PASSWORD;

// Las coordenadas de Bogotá y Tunja del catálogo de ciudades del formulario del generador
// (truckcar-frontend/js/views/generatorPanel.js): la carga que se publique en la demo parte exactamente de aquí.
const ORIGIN = coords(process.env.DEMO_ORIGIN, [4.6097, -74.0817]);
const DESTINATION = coords(process.env.DEMO_DESTINATION, [5.5353, -73.3678]);

const DEMO = {
  coordinator: { email: 'torre@truckcar.demo', firstName: 'Tomás', lastName: 'Torre', role: 'COORDINADOR' },
  generator: { email: 'generador@truckcar.demo', firstName: 'Gabriela', lastName: 'Castro', role: 'GENERADOR' },
  drivers: [
    // Lejos de Bogotá a propósito: en una carga que sale de Bogotá gana el conductor que se registre allí (el
    // profesor) y estos aparecen detrás, con su distancia en vacío. En una carga que sale de su ciudad, ganan ellos.
    { email: 'conductor1@truckcar.demo', firstName: 'Andrés', lastName: 'Rojas', plate: 'DEM-410', type: 'TRACTOMULA_3S3',
      model: 'Kenworth T800', height: 4.1, payload: 34, tare: 15, rating: 4.8, trips: 126, at: [6.2442, -75.5812] },  // Medellín
    { email: 'conductor2@truckcar.demo', firstName: 'Laura', lastName: 'Méndez', plate: 'DEM-238', type: 'TRACTOMULA_3S3',
      model: 'International ProStar', height: 4.0, payload: 34, tare: 14.5, rating: 4.5, trips: 88, at: [3.4516, -76.5320] }, // Cali
    // Un Turbo: en una carga de tractomula aparece descartado con su motivo.
    { email: 'conductor3@truckcar.demo', firstName: 'Jorge', lastName: 'Pardo', plate: 'DEM-527', type: 'TURBO',
      model: 'Chevrolet NPR', height: 3.4, payload: 4.5, tare: 3.5, rating: 4.9, trips: 240, at: [7.1193, -73.1227] }        // Bucaramanga
  ]
};
// Cuentas de pruebas anteriores con contraseña conocida: si dejaron un viaje en tránsito, se cierra con ellas.
const KNOWN_TEST_DRIVERS = [{ email: 'conductor.prueba@truckcar.lab', password: env.TRUCKCAR_TEST_DRIVER_PASSWORD }];
const RESTRICTION_PREFIX = 'DEMO-GALIBO';

const admin = await login('admin@truckcar.lab', env.TRUCKCAR_ADMIN_PASSWORD);

console.log('\n1. Cuentas');
const users = {};
for (const account of [DEMO.coordinator, DEMO.generator, ...DEMO.drivers]) {
  users[account.email] = await ensureUser(account);
}

console.log('\n2. Vehículos y posición de los conductores');
for (const d of DEMO.drivers) {
  const [lat, lon] = d.at;
  await api('POST', '/fleets-drivers/state', {
    token: admin,
    body: {
      driverId: users[d.email].id, driverName: `${d.firstName} ${d.lastName}`, licenseCategory: 'C3', rating: d.rating,
      totalTrips: d.trips, vehiclePlate: d.plate, vehicleModel: d.model, vehicleType: d.type, maxHeightMeters: d.height,
      netCargoWeightTons: 0, maxPayloadTons: d.payload, tareWeightTons: d.tare, drivingHoursToday: 1.5,
      hazmatAuthorized: false, coldChainCertified: false, runtValid: true, electronicTollTagActive: true,
      currentLatitude: lat, currentLongitude: lon, currentSpeedKmH: 0, status: 'ACTIVO'
    }
  });
  console.log(`   ${d.firstName} ${d.lastName}: ${d.plate} ${d.type}, ${d.height} m, ${d.payload} t, ACTIVO`);
}

console.log('\n3. Cargas y SOS abiertos');
const tokens = new Map();
for (const d of DEMO.drivers) tokens.set(users[d.email].id, () => login(d.email, PASSWORD));
for (const t of KNOWN_TEST_DRIVERS.filter(t => t.password)) {
  const found = await findUser(t.email);
  if (found) tokens.set(found.id, () => login(t.email, t.password));
}
const loads = list(await api('GET', '/loads', { token: admin }));
let closed = 0;
for (const load of loads) {
  if (['AVAILABLE', 'ASSIGNED'].includes(load.status)) {
    await api('PATCH', `/loads/${load.id}/cancel`, { token: admin, body: { reason: 'Limpieza antes de la demostración' } });
    console.log(`   carga ${load.id} (${load.status}) cancelada`);
    closed++;
  } else if (load.status === 'IN_TRANSIT') {
    const driverLogin = tokens.get(load.assignedDriverId);
    if (!driverLogin) {
      console.log(`   carga ${load.id} en tránsito con un conductor ajeno a la demo: se deja como está`);
      continue;
    }
    await api('PATCH', `/loads/${load.id}/trip/deliver`, {
      token: await driverLogin(), body: { receiverName: 'Cierre de datos de prueba', notes: 'Preparación de la demostración' }
    });
    console.log(`   carga ${load.id} en tránsito entregada`);
    closed++;
  }
}
const sos = list(await api('GET', '/alerts/sos', { token: admin }));
for (const s of sos) await api('PATCH', `/alerts/sos/${s.id}/acknowledge`, { token: admin });
console.log(`   ${closed} cargas cerradas, ${sos.length} SOS atendidos`);

console.log('\n4. Puente de gálibo sobre la ruta');
for (const r of list(await api('GET', '/restrictions', { token: admin }))) {
  if (String(r.restrictionCode || '').startsWith(RESTRICTION_PREFIX) && r.isActive !== false) {
    await api('PATCH', `/restrictions/${r.id}/deactivate`, { token: admin });
  }
}
// A 8 km: con "Simular GPS" (1,2 km cada 3 s) el aviso aparece a los ~12 s, al quedar a 3 km, y da tiempo de leerlo.
const BRIDGE_KM = 8;
const bridge = await pointAlongRoute(ORIGIN, DESTINATION, BRIDGE_KM);
await api('POST', '/restrictions', {
  token: admin,
  body: {
    restrictionCode: `${RESTRICTION_PREFIX}-${Date.now().toString(36).toUpperCase()}`,
    title: 'Puente peatonal de gálibo reducido', description: 'Restricción de la demostración: gálibo de 3,80 m.',
    restrictionType: 'GALIBO_ALTURA', severity: 'PRECAUCION', roadCorridor: 'Bogotá - Tunja',
    department: 'Cundinamarca', maxClearanceMeters: 3.8, latitude: bridge[0], longitude: bridge[1]
  }
});
console.log(`   gálibo de 3,80 m en ${bridge[0].toFixed(5)}, ${bridge[1].toFixed(5)} (a ${BRIDGE_KM} km del origen por la ruta)`);

console.log('\nListo. Contraseña de las cuentas de la demo: TRUCKCAR_DEMO_PASSWORD en .env');
for (const [email, u] of Object.entries(users)) console.log(`   ${u.role.padEnd(11)} ${email}`);
console.log(`Origen de la carga: ${ORIGIN.join(', ')} · destino: ${DESTINATION.join(', ')}`);

// ── Utilidades ──────────────────────────────────────────────────────────────────────────────────────────────────

async function ensureUser(account) {
  // El registro público solo admite CONDUCTOR y GENERADOR: el coordinador se registra como generador y el ADMIN le
  // cambia el rol.
  const role = account.role || 'CONDUCTOR';
  const registerRole = role === 'COORDINADOR' ? 'GENERADOR' : role;
  const res = await api('POST', '/auth/register', {
    body: { email: account.email, password: PASSWORD, firstName: account.firstName, lastName: account.lastName, role: registerRole },
    accept: [409]
  });
  const user = await findUser(account.email);
  if (!user) fail(`No se encontró la cuenta ${account.email} después de registrarla`);
  if (user.role !== role) await api('PATCH', `/users/${user.id}/role`, { token: admin, body: { role } });
  if (user.status !== 'ACTIVE') await api('PATCH', `/users/${user.id}/status`, { token: admin, body: { status: 'ACTIVE' } });
  // Comprueba la contraseña: una cuenta creada antes con otra contraseña no serviría en la demo.
  await login(account.email, PASSWORD);
  console.log(`   ${role.padEnd(11)} ${account.email} ${res.status === 409 ? '(ya existía)' : '(creada)'}`);
  return { ...user, role };
}

async function findUser(email) {
  return list(await api('GET', '/users?size=500', { token: admin })).find(u => u.email === email);
}

async function login(email, password) {
  const res = await api('POST', '/auth/login', { body: { email, password }, accept: [401] });
  if (res.status !== 200) fail(`No se pudo iniciar sesión con ${email} (${res.status})`);
  return res.json.accessToken || res.json.token;
}

async function api(method, path, { token, body, accept = [] } = {}) {
  let res;
  for (let attempt = 1; ; attempt++) {
    res = await fetch(`${BASE}/api/v1${path}`, {
      method,
      headers: { ...(body ? { 'Content-Type': 'application/json' } : {}), ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      body: body ? JSON.stringify(body) : undefined
    });
    // El gateway limita los intentos en /api/v1/auth (KAN-31): con 429 se espera lo que pide Retry-After y se reintenta.
    if (res.status !== 429 || attempt >= 8) break;
    await res.text();
    const seconds = Number.parseInt(res.headers.get('retry-after'), 10);
    await new Promise(resolve => setTimeout(resolve, (Number.isFinite(seconds) ? seconds : 1) * 1000 + 100));
  }
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { json = text; }
  if (!res.ok && !accept.includes(res.status)) {
    const detail = json && (json.detail || json.message || json.error) || String(text).slice(0, 200);
    fail(`${method} ${path} respondió ${res.status}: ${detail}`);
  }
  return { status: res.status, json };
}

function list({ json }) {
  return Array.isArray(json) ? json : (json && Array.isArray(json.content) ? json.content : []);
}

// Punto a `km` kilómetros del origen sobre la ruta real de OSRM (el mismo servidor que usa la PWA).
async function pointAlongRoute(from, to, km) {
  const url = `https://router.project-osrm.org/route/v1/driving/${from[1]},${from[0]};${to[1]},${to[0]}?overview=full&geometries=geojson`;
  const res = await fetch(url);
  if (!res.ok) fail(`OSRM respondió ${res.status}`);
  const path = (await res.json()).routes[0].geometry.coordinates.map(([lon, lat]) => [lat, lon]);
  let travelled = 0;
  for (let i = 1; i < path.length; i++) {
    const step = haversineKm(path[i - 1], path[i]);
    if (travelled + step >= km) {
      const f = (km - travelled) / step;
      return [path[i - 1][0] + (path[i][0] - path[i - 1][0]) * f, path[i - 1][1] + (path[i][1] - path[i - 1][1]) * f];
    }
    travelled += step;
  }
  return path[path.length - 1];
}

function haversineKm([lat1, lon1], [lat2, lon2]) {
  const r = Math.PI / 180;
  const a = Math.sin((lat2 - lat1) * r / 2) ** 2 + Math.cos(lat1 * r) * Math.cos(lat2 * r) * Math.sin((lon2 - lon1) * r / 2) ** 2;
  return 12742 * Math.asin(Math.sqrt(a));
}


function coords(value, fallback) {
  if (!value) return fallback;
  const parts = value.split(',').map(Number);
  if (parts.length !== 2 || parts.some(Number.isNaN)) fail(`Coordenadas inválidas: ${value} (use "lat,lon")`);
  return parts;
}

function readEnv() {
  if (!existsSync(ENV_FILE)) fail('No hay .env en la carpeta actual: corra el script desde la raíz del proyecto');
  return Object.fromEntries(readFileSync(ENV_FILE, 'utf8').split(/\r?\n/)
    .map(l => l.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/)).filter(Boolean).map(m => [m[1], m[2].replace(/^["']|["']$/g, '')]));
}

function fail(message) {
  console.error(`Error: ${message}`);
  process.exit(1);
}
