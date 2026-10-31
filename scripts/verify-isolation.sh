#!/usr/bin/env bash
# Comprueba el aislamiento de red: los microservicios no responden desde el host, el gateway solo sirve la API (su
# actuator y el de los servicios no se alcanzan desde fuera), Prometheus sí los alcanza dentro de truckcar-network y
# las herramientas de observabilidad solo escuchan en 127.0.0.1.
# Uso: bash scripts/verify-isolation.sh   (con el stack levantado: docker compose up -d)
set -uo pipefail
FAILED=0
ok()   { echo "  OK    $1"; }
fail() { echo "  FALLA $1"; FAILED=1; }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@"; }
internal() { docker run --rm --network truckcar-network curlimages/curl:8.10.1 -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null; }

declare -A SERVICES=([8080]=user-identity [8081]=fleets-drivers [8082]=community-alerts [8083]=load-allocation
                     [8084]=routing-restrictions [8085]=ai-fleet-allocation [8086]=route-ai-agent [8087]=notifications)
echo "== Puertos internos desde el host (deben estar cerrados)"
for port in $(printf '%s\n' "${!SERVICES[@]}" | sort) 8090 6432 4318 3200 9127; do
  if curl -s -o /dev/null --max-time 3 "http://localhost:$port/"; then fail ":$port (${SERVICES[$port]:-infraestructura}) responde desde el host"
  else ok ":$port (${SERVICES[$port]:-infraestructura}) cerrado"; fi
done

echo "== Puertas de entrada públicas"
c=$(code http://localhost:8000/api/v1/loads); [ "$c" = "401" ] && ok "api-gateway :8000 exige JWT (/api/v1/loads -> 401)" || fail "api-gateway /api/v1/loads -> $c (se esperaba 401)"
c=$(code http://localhost:5500/index.html); [ "$c" = "200" ] && ok "frontend :5500 -> 200" || fail "frontend :5500 -> $c"

echo "== El actuator no se alcanza a través del gateway"
for path in /actuator/health /actuator/prometheus /api/v1/loads/%2e%2e/%2e%2e/%2e%2e/actuator/prometheus; do
  c=$(code "http://localhost:8000$path")
  if [ "$c" = "200" ]; then fail "$path -> 200 (expuesto)"; else ok "$path -> $c"; fi
done
c=$(code --path-as-is http://localhost:8000/api/v1/loads/../../../actuator/prometheus)
[ "$c" = "200" ] && fail "traversal a /actuator/prometheus -> 200" || ok "traversal a /actuator/prometheus -> $c"

echo "== Dentro de truckcar-network (Prometheus)"
for target in http://load-allocation:8083/actuator/health http://load-allocation:8083/actuator/prometheus \
              http://api-gateway:8090/actuator/prometheus http://pgbouncer-exporter:9127/metrics; do
  c=$(internal "$target"); [ "$c" = "200" ] && ok "$target -> 200" || fail "$target -> $c"
done

echo "== Observabilidad solo en 127.0.0.1 del host"
for svc in truckcar-grafana truckcar-prometheus; do
  bind=$(docker port "$svc" 2>/dev/null | head -1)
  case "$bind" in *"127.0.0.1:"*) ok "$svc -> $bind" ;; *) fail "$svc publicado como '$bind'" ;; esac
done
exit $FAILED
