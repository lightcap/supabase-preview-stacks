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
MAX_RUNNING_STACKS="${MAX_RUNNING_STACKS:-12}"
if [[ ! "$MAX_RUNNING_STACKS" =~ ^[1-9][0-9]*$ ]]; then
  echo "❌ MAX_RUNNING_STACKS must be a positive integer (got '${MAX_RUNNING_STACKS}')" >&2
  exit 1
fi

# ── Helpers ──

generate_jwt_secret() {
  openssl rand -hex 32
}

generate_password() {
  openssl rand -base64 24 | tr -d '/+=' | head -c 32
}

# A stack counts as "running" when any of its containers is running —
# the cap bounds memory, and partial stacks (db down, others up) still
# consume it. Containers are matched by the <name>- prefix.
stack_running() {
  local name="$1"
  docker ps -q --filter "name=^/${name}-" | grep -q .
}

touch_last_active() {
  touch "${STACKS_DIR}/$1/.last-active"
}

# LRU sort key: .last-active mtime, falling back to metadata.json mtime
# for stacks created before this feature existed.
last_active_epoch() {
  local dir="${STACKS_DIR}/$1"
  if [[ -f "${dir}/.last-active" ]]; then
    stat -c %Y "${dir}/.last-active"
  else
    stat -c %Y "${dir}/metadata.json"
  fi
}

# Start any exited <name>-* sidecar containers (e.g. <name>-dtu) that
# hibernation stopped — compose only manages the stack's own services.
start_sidecars() {
  local name="$1"
  local sidecars
  sidecars=$(docker ps -a --filter "name=^/${name}-" --filter "status=exited" -q)
  if [[ -n "$sidecars" ]]; then
    # shellcheck disable=SC2086
    docker start $sidecars > /dev/null
  fi
}

# The <name>-* container filters are only safe when no stack name is a
# dash-prefix of another. New conflicts are blocked at create; this guards
# against pre-existing ones before any cross-stack docker stop/start.
require_no_name_conflicts() {
  local name="$1"
  local dir other
  for dir in "$STACKS_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    other=$(basename "$dir")
    [[ "$other" == "$name" ]] && continue
    if [[ "$other" == "$name"-* || "$name" == "$other"-* ]]; then
      echo "❌ Stack name '${name}' conflicts with existing stack '${other}'; resolve before hibernate/wake" >&2
      exit 1
    fi
  done
}

# Hibernate least-recently-active running stacks until a slot is free.
# $1 = stack name to exclude from eviction (the one being created/woken).
# Callers (preview-db.sh, stack.sh) hold the server-side flock, so this is race-free.
ensure_capacity() {
  local exclude="${1:-}"
  while :; do
    local running=()
    local meta name
    # Derive the name from the directory, not metadata.json, so a corrupt
    # metadata file can't brick capacity enforcement for every create/wake.
    for meta in "$STACKS_DIR"/*/metadata.json; do
      [[ -f "$meta" ]] || continue
      name=$(basename "$(dirname "$meta")")
      [[ "$name" == "$exclude" ]] && continue
      stack_running "$name" && running+=("$name")
    done
    (( ${#running[@]} < MAX_RUNNING_STACKS )) && break

    local lru="" lru_epoch=0 epoch
    for name in "${running[@]}"; do
      epoch=$(last_active_epoch "$name")
      if [[ -z "$lru" ]] || (( epoch < lru_epoch )); then
        lru="$name"
        lru_epoch="$epoch"
      fi
    done
    if [[ -z "$lru" ]]; then
      echo "⚠️  At capacity but found no hibernation candidate; continuing anyway"
      break
    fi
    echo "📉 At capacity (${#running[@]}/${MAX_RUNNING_STACKS} running) — hibernating least-recently-active stack '${lru}'"
    cmd_hibernate "$lru"
  done
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

  # Container cleanup filters match "<name>-*", so no stack name may be a
  # dash-prefix of another (e.g. "pr-1" and "pr-1-hotfix" would collide).
  local existing_dir existing
  for existing_dir in "$STACKS_DIR"/*/; do
    [[ -d "$existing_dir" ]] || continue
    existing=$(basename "$existing_dir")
    if [[ "$existing" == "$name"-* || "$name" == "$existing"-* ]]; then
      echo "❌ Stack name '${name}' conflicts with existing stack '${existing}' (stack names must not be dash-prefixes of each other)"
      exit 1
    fi
  done

  ensure_capacity "$name"

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

  touch_last_active "$name"

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
      status="💤 hibernated"
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

  require_no_name_conflicts "$name"

  echo "🔄 Restarting stack: ${name}"
  ensure_capacity "$name"
  (cd "$stack_dir" && docker compose restart)
  start_sidecars "$name"
  touch_last_active "$name"
  echo "✅ Restarted"
}

cmd_hibernate() {
  local name="$1"
  local stack_dir="${STACKS_DIR}/${name}"

  if [[ ! -d "$stack_dir" ]]; then
    echo "❌ Stack '${name}' not found"
    exit 1
  fi

  require_no_name_conflicts "$name"

  echo "💤 Hibernating stack: ${name}"
  # The trailing dash keeps pr-1 from matching pr-19-db. Also catches
  # consumer sidecars (e.g. pr-42-dtu) that aren't in the compose file.
  local containers
  containers=$(docker ps --filter "name=^/${name}-" -q)
  if [[ -n "$containers" ]]; then
    # shellcheck disable=SC2086
    docker stop $containers > /dev/null
  fi
  echo "💤 Stack '${name}' hibernated (data preserved; wake with: stack.sh wake ${name})"
}

cmd_wake() {
  local name="$1"
  local stack_dir="${STACKS_DIR}/${name}"

  if [[ ! -d "$stack_dir" ]]; then
    echo "❌ Stack '${name}' not found"
    exit 1
  fi

  require_no_name_conflicts "$name"

  ensure_capacity "$name"

  echo "⏰ Waking stack: ${name}"
  # "up -d" rather than "start": idempotent, and also recovers stacks whose
  # containers were removed entirely (cmd_list labels those hibernated too).
  (cd "$stack_dir" && docker compose up -d)

  start_sidecars "$name"

  touch_last_active "$name"
  echo "✅ Stack '${name}' awake"
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
  hibernate)
    [[ -z "$NAME" ]] && { echo "Usage: stack.sh hibernate <name>"; exit 1; }
    validate_name "$NAME"
    cmd_hibernate "$NAME"
    ;;
  wake)
    [[ -z "$NAME" ]] && { echo "Usage: stack.sh wake <name>"; exit 1; }
    validate_name "$NAME"
    cmd_wake "$NAME"
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
    echo "  hibernate <name> Stop a stack's containers, keeping data (auto-evicted LRU at capacity)"
    echo "  wake    <name>   Restart a hibernated stack's containers"
    echo "  env     <name>   Print env vars for a stack"
    ;;
esac
