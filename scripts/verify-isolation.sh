#!/usr/bin/env bash
# Comprueba el aislamiento: los microservicios no responden desde el host y el gateway sí.
# Uso: bash scripts/verify-isolation.sh   (con el stack levantado: docker compose up -d)
set -uo pipefail
FAILED=0
declare -A SERVICES=([8080]=user-identity [8081]=fleets-drivers [8082]=community-alerts [8083]=load-allocation
                     [8084]=routing-restrictions [8085]=ai-fleet-allocation [8086]=route-ai-agent [8087]=notifications)
echo "== Puertos internos desde el host (deben estar cerrados)"
for port in $(printf '%s\n' "${!SERVICES[@]}" | sort); do
  if curl -s -o /dev/null --max-time 3 "http://localhost:$port/actuator/health"; then
    echo "  FALLA :$port (${SERVICES[$port]}) responde desde el host"; FAILED=1
  else
    echo "  OK    :$port (${SERVICES[$port]}) cerrado"
  fi
done
echo "== Puertas de entrada publicas"
for url in http://localhost:8000/actuator/health http://localhost:5500/index.html; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url")"
  if [ "$code" = "200" ]; then echo "  OK    $url -> 200"; else echo "  FALLA $url -> $code"; FAILED=1; fi
done
echo "== Resolucion interna por nombre (dentro de truckcar-network)"
code="$(docker run --rm --network truckcar-network curlimages/curl:8.10.1 -s -o /dev/null -w '%{http_code}' \
  http://load-allocation:8083/actuator/health 2>/dev/null)"
if [ "$code" = "200" ]; then echo "  OK    load-allocation:8083 -> 200"; else echo "  FALLA load-allocation:8083 -> $code"; FAILED=1; fi
exit $FAILED
