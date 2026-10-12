#!/usr/bin/env bash
# Crea .env a partir de .env.example con un TRUCKDAR_JWT_SECRET aleatorio (Base64, 384 bits).
# No sobrescribe un .env existente: borrarlo primero para regenerarlo.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -f .env ]; then
  echo ".env ya existe; no se modifica."
  exit 0
fi
secret="$(head -c 48 /dev/urandom | base64 | tr -d '\n')"
sed "s|^TRUCKDAR_JWT_SECRET=.*|TRUCKDAR_JWT_SECRET=$secret|" .env.example > .env
echo ".env creado con un TRUCKDAR_JWT_SECRET nuevo."
