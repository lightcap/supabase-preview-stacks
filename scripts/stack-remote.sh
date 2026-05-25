#!/bin/bash
set -euo pipefail

# This script runs ON the Hetzner server.
# It's uploaded by bootstrap.sh and called by the local stack.sh wrapper.

STACKS_DIR="/opt/supabase/stacks"
SCRIPTS_DIR="/opt/supabase/scripts"
NGINX_SITES="/opt/supabase/nginx/sites-enabled"
PORT_BASE="${SUPABASE_PORT_BASE:-54320}"
PORT_BLOCK="${SUPABASE_PORT_BLOCK:-20}"
DEV_DOMAIN="${DEV_DOMAIN:-dev.example.com}"

# ── Helpers ──

generate_jwt_secret() {
  openssl rand -hex 32
}

generate_password() {
  openssl rand -base64 24 | tr -d '/+=' | head -c 32
}

validate_name() {
  local name="$1"
  if [[ ! "$name" =~ ^[a-z0-9]([a-z0-9-]{0,54}[a-z0-9])?$ ]]; then
    echo "Invalid stack name: ${name}" >&2
    echo "Use a DNS-safe name up to 56 characters: lowercase letters, numbers, and dashes; no leading or trailing dash." >&2
    exit 1
  fi
}

# Generate Supabase JWT tokens (anon + service_role)
generate_jwt() {
  local secret="$1"
  local role="$2"
  local now
  now=$(date +%s)
  local exp=$((now + 31536000))  # 1 year

  local header
  header=$(echo -n '{"alg":"HS256","typ":"JWT"}' | base64 -w0 | tr '+/' '-_' | tr -d '=')
  local payload
  payload=$(echo -n "{\"role\":\"${role}\",\"iss\":\"supabase\",\"iat\":${now},\"exp\":${exp}}" | base64 -w0 | tr '+/' '-_' | tr -d '=')
  local signature
  signature=$(echo -n "${header}.${payload}" | openssl dgst -sha256 -hmac "${secret}" -binary | base64 -w0 | tr '+/' '-_' | tr -d '=')

  echo "${header}.${payload}.${signature}"
}

next_port_base() {
  local max_port=$PORT_BASE
  if [[ -d "$STACKS_DIR" ]]; then
    for meta in "$STACKS_DIR"/*/metadata.json; do
      [[ -f "$meta" ]] || continue
      local p
      p=$(jq -r '.port_base' "$meta" 2>/dev/null || echo "0")
      if (( p >= max_port )); then
        max_port=$((p + PORT_BLOCK))
      fi
    done
  fi
  echo "$max_port"
}

# ── Commands ──

cmd_create() {
  local name="$1"
  local stack_dir="${STACKS_DIR}/${name}"
  local domain="${name}.${DEV_DOMAIN}"

  if [[ -d "$stack_dir" ]]; then
    echo "❌ Stack '${name}' already exists"
    exit 1
  fi

  local port_base
  port_base=$(next_port_base)
  local port_end=$((port_base + PORT_BLOCK - 1))

  echo "═══════════════════════════════════════════"
  echo "  Creating stack: ${name}"
  echo "  Ports: ${port_base}-${port_end}"
  echo "  API: https://${domain}"
  echo "═══════════════════════════════════════════"

  mkdir -p "$stack_dir"

  # Generate secrets
  local jwt_secret db_password anon_key service_key
  jwt_secret=$(generate_jwt_secret)
  db_password=$(generate_password)
  anon_key=$(generate_jwt "$jwt_secret" "anon")
  service_key=$(generate_jwt "$jwt_secret" "service_role")

  # Port assignments
  local port_db=$((port_base + 0))
  local port_kong=$((port_base + 1))
  local port_kong_ssl=$((port_base + 2))
  local port_auth=$((port_base + 3))
  local port_rest=$((port_base + 4))
  local port_storage=$((port_base + 5))

  # ── Generate docker-compose.yml ──
  sed \
    -e "s|__PROJECT_NAME__|${name}|g" \
    -e "s|__DEV_DOMAIN__|${DEV_DOMAIN}|g" \
    -e "s|__PORT_BASE__|${port_base}|g" \
    -e "s|__PORT_END__|${port_end}|g" \
    -e "s|__PORT_DB__|${port_db}|g" \
    -e "s|__PORT_KONG__|${port_kong}|g" \
    -e "s|__PORT_KONG_SSL__|${port_kong_ssl}|g" \
    -e "s|__PORT_AUTH__|${port_auth}|g" \
    -e "s|__PORT_REST__|${port_rest}|g" \
    -e "s|__PORT_STORAGE__|${port_storage}|g" \
    -e "s|__DB_PASSWORD__|${db_password}|g" \
    -e "s|__JWT_SECRET__|${jwt_secret}|g" \
    -e "s|__ANON_KEY__|${anon_key}|g" \
    -e "s|__SERVICE_KEY__|${service_key}|g" \
    -e "s|__TIMESTAMP__|$(date -u +"%Y-%m-%dT%H:%M:%SZ")|g" \
    "${SCRIPTS_DIR}/docker-compose.yml.tpl" > "${stack_dir}/docker-compose.yml"

  # ── Generate kong.yml ──
  sed \
    -e "s|__PROJECT_NAME__|${name}|g" \
    -e "s|__ANON_KEY__|${anon_key}|g" \
    -e "s|__SERVICE_KEY__|${service_key}|g" \
    "${SCRIPTS_DIR}/kong.yml.tpl" > "${stack_dir}/kong.yml"

  # ── Generate nginx site config ──
  sed \
    -e "s|__PROJECT_NAME__|${name}|g" \
    -e "s|__DEV_DOMAIN__|${DEV_DOMAIN}|g" \
    -e "s|__PORT_KONG__|${port_kong}|g" \
    -e "s|__TIMESTAMP__|$(date -u +"%Y-%m-%dT%H:%M:%SZ")|g" \
    "${SCRIPTS_DIR}/nginx-site.conf.tpl" > "${NGINX_SITES}/${name}.conf"

  # ── Save metadata ──
  cat > "${stack_dir}/metadata.json" <<EOF
{
  "name": "${name}",
  "port_base": ${port_base},
  "port_end": ${port_end},
  "domain": "${domain}",
  "created_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "jwt_secret": "${jwt_secret}",
  "db_password": "${db_password}",
  "anon_key": "${anon_key}",
  "service_key": "${service_key}",
  "ports": {
    "db": ${port_db},
    "kong": ${port_kong},
    "kong_ssl": ${port_kong_ssl},
    "auth": ${port_auth},
    "rest": ${port_rest},
    "storage": ${port_storage}
  }
}
EOF

  # ── Start the database first ──
  echo "🚀 Starting database..."
  (cd "$stack_dir" && docker compose up -d db)

  echo "⏳ Waiting for database to be healthy..."
  for _ in $(seq 1 30); do
    if docker inspect --format='{{.State.Health.Status}}' "${name}-db" 2>/dev/null | grep -q healthy; then
      break
    fi
    sleep 2
  done

  # ── Set service role passwords ──
  # The supabase/postgres image creates roles (supabase_auth_admin,
  # supabase_storage_admin, authenticator) with default passwords.
  # We must set them to match the generated db_password before
  # the other services try to connect.
  echo "🔑 Configuring database role passwords..."
  docker exec -e PGPASSWORD="${db_password}" "${name}-db" \
    psql -U supabase_admin -d postgres -c "\
      ALTER ROLE supabase_auth_admin WITH PASSWORD '${db_password}'; \
      ALTER ROLE supabase_storage_admin WITH PASSWORD '${db_password}'; \
      ALTER ROLE authenticator WITH PASSWORD '${db_password}';"

  # ── Start the remaining services ──
  echo "🚀 Starting services..."
  (cd "$stack_dir" && docker compose up -d)

  # ── Reload nginx ──
  nginx -t && systemctl reload nginx

  echo ""
  echo "═══════════════════════════════════════════"
  echo "  ✅ Stack '${name}' is running"
  echo "═══════════════════════════════════════════"
  echo ""
  echo "  API:     https://${domain}"
  echo "  DB:      postgresql://postgres:${db_password}@${DEV_DOMAIN}:${port_db}/postgres"
  echo ""
  echo "  SUPABASE_URL=https://${domain}"
  echo "  SUPABASE_ANON_KEY=${anon_key}"
  echo "  SUPABASE_SERVICE_ROLE_KEY=${service_key}"
  echo ""
}

cmd_destroy() {
  local name="$1"
  local force="${2:-}"
  local stack_dir="${STACKS_DIR}/${name}"

  if [[ ! -d "$stack_dir" ]]; then
    echo "❌ Stack '${name}' not found"
    exit 1
  fi

  if [[ "$force" != "--force" ]]; then
    echo "⚠️  Destroying stack: ${name}"
    echo "   This will delete all data (database, storage)."
    read -p "   Are you sure? [y/N] " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Cancelled."
      exit 0
    fi
  fi

  (cd "$stack_dir" && docker compose down -v)
  rm -f "${NGINX_SITES}/${name}.conf"
  rm -rf "$stack_dir"
  nginx -t && systemctl reload nginx

  echo "🗑️  Stack '${name}' destroyed"
}

cmd_list() {
  echo "═══════════════════════════════════════════"
  echo "  Active Supabase Stacks"
  echo "═══════════════════════════════════════════"

  if [[ ! -d "$STACKS_DIR" ]] || [[ -z "$(ls -A "$STACKS_DIR" 2>/dev/null)" ]]; then
    echo "  (none)"
    return
  fi

  printf "  %-20s %-35s %-15s\n" "NAME" "URL" "STATUS"
  printf "  %-20s %-35s %-15s\n" "----" "---" "------"

  for meta in "$STACKS_DIR"/*/metadata.json; do
    [[ -f "$meta" ]] || continue
    local name domain stack_dir
    name=$(jq -r '.name' "$meta")
    domain=$(jq -r '.domain' "$meta")
    stack_dir="${STACKS_DIR}/${name}"

    local status="unknown"
    local running
    running=$(cd "$stack_dir" && docker compose ps --status running -q 2>/dev/null | wc -l)
    local total
    total=$(cd "$stack_dir" && docker compose ps -q 2>/dev/null | wc -l)

    if (( running == total && total > 0 )); then
      status="✅ ${running}/${total}"
    elif (( running > 0 )); then
      status="⚠️  ${running}/${total}"
    else
      status="❌ stopped"
    fi

    printf "  %-20s %-35s %-15s\n" "$name" "https://${domain}" "$status"
  done
}

cmd_status() {
  local name="$1"
  local stack_dir="${STACKS_DIR}/${name}"

  if [[ ! -d "$stack_dir" ]]; then
    echo "❌ Stack '${name}' not found"
    exit 1
  fi

  echo "Stack: ${name}"
  echo "URL: https://$(jq -r '.domain' "${stack_dir}/metadata.json")"
  echo ""
  (cd "$stack_dir" && docker compose ps)
}

cmd_restart() {
  local name="$1"
  local stack_dir="${STACKS_DIR}/${name}"

  if [[ ! -d "$stack_dir" ]]; then
    echo "❌ Stack '${name}' not found"
    exit 1
  fi

  echo "🔄 Restarting stack: ${name}"
  (cd "$stack_dir" && docker compose restart)
  echo "✅ Restarted"
}

cmd_env() {
  local name="$1"
  local stack_dir="${STACKS_DIR}/${name}"

  if [[ ! -d "$stack_dir" ]]; then
    echo "❌ Stack '${name}' not found"
    exit 1
  fi

  local meta="${stack_dir}/metadata.json"
  local domain anon_key service_key db_password port_db

  domain=$(jq -r '.domain' "$meta")
  anon_key=$(jq -r '.anon_key' "$meta")
  service_key=$(jq -r '.service_key' "$meta")
  db_password=$(jq -r '.db_password' "$meta")
  port_db=$(jq -r '.ports.db' "$meta")

  cat <<EOF
SUPABASE_URL=https://${domain}
SUPABASE_ANON_KEY=${anon_key}
SUPABASE_SERVICE_ROLE_KEY=${service_key}
NEXT_PUBLIC_SUPABASE_URL=https://${domain}
NEXT_PUBLIC_SUPABASE_ANON_KEY=${anon_key}
DATABASE_URL=postgresql://postgres:${db_password}@$(hostname -I | awk '{print $1}'):${port_db}/postgres
EOF
}

# ── Main ──

COMMAND="${1:-help}"
NAME="${2:-}"

case "$COMMAND" in
  create)
    [[ -z "$NAME" ]] && { echo "Usage: stack.sh create <name>"; exit 1; }
    validate_name "$NAME"
    cmd_create "$NAME"
    ;;
  destroy)
    [[ -z "$NAME" ]] && { echo "Usage: stack.sh destroy <name> [--force]"; exit 1; }
    validate_name "$NAME"
    cmd_destroy "$NAME" "${3:-}"
    ;;
  list)
    cmd_list
    ;;
  status)
    [[ -z "$NAME" ]] && { echo "Usage: stack.sh status <name>"; exit 1; }
    validate_name "$NAME"
    cmd_status "$NAME"
    ;;
  restart)
    [[ -z "$NAME" ]] && { echo "Usage: stack.sh restart <name>"; exit 1; }
    validate_name "$NAME"
    cmd_restart "$NAME"
    ;;
  env)
    [[ -z "$NAME" ]] && { echo "Usage: stack.sh env <name>"; exit 1; }
    validate_name "$NAME"
    cmd_env "$NAME"
    ;;
  *)
    echo "Usage: stack.sh <command> [name]"
    echo ""
    echo "Commands:"
    echo "  create  <name>   Create and start a new Supabase stack"
    echo "  destroy <name>   Stop and delete a stack (with data)"
    echo "  list             List all active stacks"
    echo "  status  <name>   Show container status for a stack"
    echo "  restart <name>   Restart a stack"
    echo "  env     <name>   Print env vars for a stack"
    ;;
esac
