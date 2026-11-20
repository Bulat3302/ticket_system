#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Единый запуск стека (локально и на сервере). Различия — только в .env.
# Запуск:  sudo bash infra/up.sh   (из корня репозитория)

if [[ ! -f .env ]]; then
  echo "Создайте .env в корне репозитория (см. .env.example)" >&2
  exit 1
fi

env_value() {
  local key=$1
  local line
  line="$(grep -E "^${key}=" .env | tail -n 1 || true)"
  printf '%s' "${line#*=}"
}

write_env_key() {
  local key=$1
  local value=$2
  if grep -qE "^${key}=" .env; then
    grep -vE "^${key}=" .env > .env.tmp
    mv .env.tmp .env
  fi
  printf '%s=%s\n' "$key" "$value" >> .env
}

detect_public_ipv4() {
  local ip=""
  ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s' "$ip"; return 0
  fi
  ip="$(curl -4 -fsS --max-time 5 https://ifconfig.me/ip 2>/dev/null || true)"
  ip="${ip//$'\n'/}"
  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s' "$ip"; return 0
  fi
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s' "$ip"; return 0
  fi
  return 1
}

origin_host() {
  local origin=$1
  origin="${origin#http://}"
  origin="${origin#https://}"
  origin="${origin%%/*}"
  origin="${origin%%:*}"
  printf '%s' "$origin"
}

is_ipv4() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

for key in POSTGRES_PASSWORD REDIS_PASSWORD SESSION_SECRET OIDC_CLIENT_SECRET KC_BOOTSTRAP_ADMIN_PASSWORD; do
  if [[ -z "$(env_value "$key")" ]]; then
    echo "В .env пусто или нет ${key}" >&2
    exit 1
  fi
done

NODE_ENV="$(env_value NODE_ENV)"
NODE_ENV="${NODE_ENV:-production}"
export NODE_ENV

PUBLIC_ORIGIN="$(env_value PUBLIC_ORIGIN)"
PUBLIC_ORIGIN="${PUBLIC_ORIGIN%/}"

if [[ -z "$PUBLIC_ORIGIN" || "$PUBLIC_ORIGIN" == "https://queue.example.ru" || "$PUBLIC_ORIGIN" == "http://queue.example.ru" ]]; then
  if [[ "$NODE_ENV" == "development" ]]; then
    PUBLIC_ORIGIN="http://localhost:18080"
  else
    detected_ip="$(detect_public_ipv4)" || {
      echo "Не удалось определить публичный IPv4 сервера. Задайте PUBLIC_ORIGIN вручную." >&2
      exit 1
    }
    PUBLIC_ORIGIN="https://${detected_ip}"
  fi
  echo "PUBLIC_ORIGIN=${PUBLIC_ORIGIN}"
else
  echo "PUBLIC_ORIGIN=${PUBLIC_ORIGIN} (из .env)"
fi

write_env_key PUBLIC_ORIGIN "$PUBLIC_ORIGIN"

OIDC_ISSUER="${PUBLIC_ORIGIN}/realms/ticket-system"
OIDC_CALLBACK_URL="${PUBLIC_ORIGIN}/api/auth/callback"
STAFF_APP_URL="${PUBLIC_ORIGIN}/staff/"
CLIENT_ORIGIN="${PUBLIC_ORIGIN}"
STAFF_ORIGIN="${PUBLIC_ORIGIN}"

export PUBLIC_ORIGIN OIDC_ISSUER OIDC_CALLBACK_URL STAFF_APP_URL CLIENT_ORIGIN STAFF_ORIGIN
export STAFF_ADMIN_USERNAME="$(env_value STAFF_ADMIN_USERNAME)"
export STAFF_ADMIN_PASSWORD="$(env_value STAFF_ADMIN_PASSWORD)"

if [[ "$NODE_ENV" == "production" ]]; then
  export REMOVE_DEMO_USERS="${REMOVE_DEMO_USERS:-true}"
else
  export REMOVE_DEMO_USERS="${REMOVE_DEMO_USERS:-false}"
fi

# TLS-сертификаты для nginx (443). Если доверенных нет — выпускаем самоподписанный
# на хост из PUBLIC_ORIGIN (IP или домен). Доверенные кладите в infra/certs/.
cert_dir=infra/certs
mkdir -p "$cert_dir"
tls_host="$(origin_host "$PUBLIC_ORIGIN")"
cert_matches=false
if [[ -s "$cert_dir/fullchain.pem" && -s "$cert_dir/privkey.pem" ]]; then
  if openssl x509 -in "$cert_dir/fullchain.pem" -noout -text 2>/dev/null | grep -q "$tls_host"; then
    cert_matches=true
  fi
fi
if [[ "$cert_matches" != true ]]; then
  if is_ipv4 "$tls_host"; then san="IP:${tls_host}"; else san="DNS:${tls_host}"; fi
  openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
    -keyout "$cert_dir/privkey.pem" \
    -out "$cert_dir/fullchain.pem" \
    -subj "/CN=${tls_host}" \
    -addext "subjectAltName=${san}"
  chmod 600 "$cert_dir/privkey.pem"
  chmod 644 "$cert_dir/fullchain.pem"
  echo "Выпущен TLS-сертификат для ${tls_host}"
fi

compose=(docker compose -f infra/docker-compose.yml --env-file .env)

# Сборка по одному образу за раз — параллельная сборка может исчерпать 2 ГБ RAM.
"${compose[@]}" build keycloak
"${compose[@]}" build api
"${compose[@]}" build web
"${compose[@]}" up --no-build -d --wait --force-recreate api keycloak web
"${compose[@]}" exec -T \
  -e OIDC_CALLBACK_URL \
  -e STAFF_APP_URL \
  -e PUBLIC_ORIGIN \
  -e STAFF_ADMIN_USERNAME \
  -e STAFF_ADMIN_PASSWORD \
  -e REMOVE_DEMO_USERS \
  keycloak /opt/keycloak/keycloak-apply.sh
"${compose[@]}" ps
