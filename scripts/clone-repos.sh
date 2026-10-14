#!/usr/bin/env bash
# Clona (o actualiza) los repositorios de TruckCar como carpetas hermanas dentro de este repo.
# Uso: bash scripts/clone-repos.sh        (desde la raíz de Deployment-Infrastructure)
set -euo pipefail
cd "$(dirname "$0")/.."
REPOS=(User-Identity api-gateway fleets-drivers Community-Alerts Load-Allocation
       AI-powered-fleet-allocation Route-AI-agent Routing-Restrictions Notifications truckcar-frontend)
for repo in "${REPOS[@]}"; do
  if [ -d "$repo/.git" ]; then
    echo "== $repo: actualizando main"
    git -C "$repo" pull --ff-only origin main
  else
    echo "== $repo: clonando"
    git clone "https://github.com/TRUCKCAR-APP/$repo.git" "$repo"
  fi
done
