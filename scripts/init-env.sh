#!/usr/bin/env bash
# Genera .env a partir de .env.example: cada variable vacía marcada [secreto] recibe un valor aleatorio
# (TRUCKCAR_JWT_SECRET: Base64 de 384 bits; el resto, 32 caracteres hexadecimales).
# Con un .env existente no cambia nada de lo que ya tiene: solo agrega las variables que le falten.
# Las contraseñas de base de datos se aplican al crear cada rol: con un volumen postgis_data anterior, copie en .env
# las que ya usa ese volumen en lugar de las generadas.
set -euo pipefail
cd "$(dirname "$0")/.."

random_hex() { head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
random_b64() { head -c 48 /dev/urandom | base64 | tr -d '\n'; }

created=0
if [ ! -f .env ]; then
  : > .env
  created=1
fi

added=()
secret_next=0
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  if [[ "$line" =~ ^#.*\[secreto\] ]]; then
    secret_next=1
  fi
  if [[ "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
    key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
    if [ "$created" -eq 1 ] || ! grep -q "^${key}=" .env; then
      if [ "$secret_next" -eq 1 ] && [ -z "$value" ]; then
        if [ "$key" = "TRUCKCAR_JWT_SECRET" ]; then value="$(random_b64)"; else value="$(random_hex)"; fi
      fi
      if [ "$created" -eq 1 ]; then echo "${key}=${value}" >> .env; else added+=("${key}=${value}"); fi
    fi
    secret_next=0
  elif [ "$created" -eq 1 ]; then
    echo "$line" >> .env
  fi
done < .env.example

if [ "$created" -eq 1 ]; then
  echo ".env creado con secretos aleatorios."
elif [ "${#added[@]}" -gt 0 ]; then
  { echo; echo "# Agregadas por scripts/init-env.sh"; printf '%s\n' "${added[@]}"; } >> .env
  echo "Variables agregadas a .env: $(printf '%s ' "${added[@]%%=*}")"
else
  echo ".env ya tiene todas las variables de .env.example; no se modifica."
fi
