#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../.env"

# ── Parse flags ──
FORCE_DNS=false
for arg in "$@"; do
  case "$arg" in
    --force-dns) FORCE_DNS=true ;;
  esac
done

# ── Resolve SSH key path ──
SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
[[ -f "$SSH_KEY_PATH" ]] && SSH_OPTS="$SSH_OPTS -i $SSH_KEY_PATH"

echo "═══════════════════════════════════════════"
echo "  Provisioning Hetzner Server"
echo "═══════════════════════════════════════════"
echo ""
echo "  Name:     ${HETZNER_SERVER_NAME}"
echo "  Type:     ${HETZNER_SERVER_TYPE}"
echo "  Location: ${HETZNER_LOCATION}"
echo ""

# ── Check hcloud auth ──
if ! hcloud server-type list &>/dev/null; then
  echo "❌ hcloud is not authenticated. Run: hcloud context create dev-infra"
  exit 1
fi

# ── SSH Key ──
SSH_KEY_ARG=""
if [[ "${HETZNER_SSH_KEY_NAME}" != "none" ]]; then
  if hcloud ssh-key describe "${HETZNER_SSH_KEY_NAME}" &>/dev/null; then
    SSH_KEY_ARG="--ssh-key ${HETZNER_SSH_KEY_NAME}"
    echo "🔑 Using SSH key: ${HETZNER_SSH_KEY_NAME}"
  else
    # Auto-upload the public key from SSH_KEY_PATH
    PUB_KEY_FILE="${SSH_KEY_PATH}.pub"
    if [[ ! -f "$PUB_KEY_FILE" ]]; then
      echo "❌ SSH key '${HETZNER_SSH_KEY_NAME}' not found in Hetzner and no public key at ${PUB_KEY_FILE}"
      exit 1
    fi
    echo "📤 Uploading SSH key from ${PUB_KEY_FILE}..."
    hcloud ssh-key create --name "${HETZNER_SSH_KEY_NAME}" --public-key-from-file "$PUB_KEY_FILE"
    SSH_KEY_ARG="--ssh-key ${HETZNER_SSH_KEY_NAME}"
    echo "✅ SSH key uploaded"
  fi
fi

# ── Create or reuse server ──
if hcloud server describe "${HETZNER_SERVER_NAME}" &>/dev/null; then
  echo "ℹ️  Server '${HETZNER_SERVER_NAME}' already exists, reusing"
  SERVER_IP=$(hcloud server describe "${HETZNER_SERVER_NAME}" -o format='{{.PublicNet.IPv4.IP}}')
else
  echo "🚀 Creating server..."
  # shellcheck disable=SC2086
  hcloud server create \
    --name "${HETZNER_SERVER_NAME}" \
    --type "${HETZNER_SERVER_TYPE}" \
    --location "${HETZNER_LOCATION}" \
    --image ubuntu-24.04 \
    ${SSH_KEY_ARG}

  SERVER_IP=$(hcloud server describe "${HETZNER_SERVER_NAME}" -o format='{{.PublicNet.IPv4.IP}}')
  echo "✅ Server created: ${SERVER_IP}"
fi

# ── Wait for SSH to be ready ──
echo "⏳ Waiting for SSH..."
for _ in $(seq 1 30); do
  # shellcheck disable=SC2086
  if ssh $SSH_OPTS root@"${SERVER_IP}" "echo ok" &>/dev/null; then
    echo "✅ SSH is ready"
    break
  fi
  sleep 5
done

# ── Firewall ──
FIREWALL_NAME="${HETZNER_SERVER_NAME}-fw"
if ! hcloud firewall describe "${FIREWALL_NAME}" &>/dev/null; then
  echo "🔒 Creating firewall..."
  hcloud firewall create --name "${FIREWALL_NAME}"

  hcloud firewall add-rule "${FIREWALL_NAME}" \
    --direction in --protocol tcp --port 22 \
    --source-ips 0.0.0.0/0 --source-ips ::/0 \
    --description "SSH"

  hcloud firewall add-rule "${FIREWALL_NAME}" \
    --direction in --protocol tcp --port 80 \
    --source-ips 0.0.0.0/0 --source-ips ::/0 \
    --description "HTTP"

  hcloud firewall add-rule "${FIREWALL_NAME}" \
    --direction in --protocol tcp --port 443 \
    --source-ips 0.0.0.0/0 --source-ips ::/0 \
    --description "HTTPS"

  hcloud firewall apply-to-resource "${FIREWALL_NAME}" \
    --type server --server "${HETZNER_SERVER_NAME}"

  echo "✅ Firewall configured (SSH + HTTP/HTTPS only)"
else
  echo "🔒 Firewall '${FIREWALL_NAME}' already exists"
fi

# ── DNS records via DNSimple ──
if [[ "${DNS_PROVIDER}" == "dnsimple" && -n "${DNSIMPLE_TOKEN:-}" ]]; then
  echo "🌐 Configuring DNS records..."

  # Extract zone and subdomain from DEV_DOMAIN
  # e.g. sb.dev.example.com → zone=example.com, subdomain=sb.dev
  ZONE=$(echo "${DEV_DOMAIN}" | awk -F. '{print $(NF-1)"."$NF}')
  SUBDOMAIN=$(echo "${DEV_DOMAIN}" | sed "s/\.${ZONE}$//")

  # Get account ID (handles both user tokens and account tokens)
  DNSIMPLE_AUTH="Authorization: Bearer ${DNSIMPLE_TOKEN}"
  ACCOUNT_ID=$(curl -s -H "$DNSIMPLE_AUTH" https://api.dnsimple.com/v2/whoami | \
    python3 -c "import sys,json; d=json.load(sys.stdin)['data']; a=d.get('account'); print(a['id'] if a else '')")
  if [[ -z "$ACCOUNT_ID" ]]; then
    # User token — get account ID from /v2/accounts
    ACCOUNT_ID=$(curl -s -H "$DNSIMPLE_AUTH" https://api.dnsimple.com/v2/accounts | \
      python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])")
  fi

  DNSIMPLE_API="https://api.dnsimple.com/v2/${ACCOUNT_ID}/zones/${ZONE}/records"

  # ── DNS clobbering protection ──
  # Check if records already point to a different IP
  EXISTING_IP=$(curl -s -H "$DNSIMPLE_AUTH" "${DNSIMPLE_API}?name=${SUBDOMAIN}&type=A" | \
    python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(d[0]['content'] if d else '')" 2>/dev/null || echo "")

  if [[ -n "$EXISTING_IP" && "$EXISTING_IP" != "$SERVER_IP" ]]; then
    echo ""
    echo "  ⚠️  DNS CLOBBERING WARNING"
    echo "  ${DEV_DOMAIN} currently points to ${EXISTING_IP}"
    echo "  This server's IP is ${SERVER_IP}"
    echo ""
    echo "  Updating DNS will break any stacks running on ${EXISTING_IP}."
    if [[ "$FORCE_DNS" != "true" ]]; then
      echo "  To proceed anyway, re-run with --force-dns"
      echo ""
      echo "  DNS records were NOT updated. Everything else succeeded."
      echo ""
      echo "═══════════════════════════════════════════"
      echo "  Server Ready (DNS skipped)"
      echo "═══════════════════════════════════════════"
      echo ""
      echo "  IP:  ${SERVER_IP}"
      echo ""
      echo "  Next: ./scripts/bootstrap.sh"
      echo ""
      echo "${SERVER_IP}" > "${SCRIPT_DIR}/../.server-ip"
      exit 0
    fi
    echo "  --force-dns passed, updating DNS records..."
  fi

  # Create/update A record for base domain
  EXISTING=$(curl -s -H "$DNSIMPLE_AUTH" "${DNSIMPLE_API}?name=${SUBDOMAIN}&type=A" | \
    python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(d[0]['id'] if d else '')" 2>/dev/null || echo "")

  if [[ -n "$EXISTING" ]]; then
    curl -s -X PATCH -H "$DNSIMPLE_AUTH" -H "Content-Type: application/json" \
      -d "{\"content\":\"${SERVER_IP}\"}" "${DNSIMPLE_API}/${EXISTING}" >/dev/null
    echo "  ✅ Updated A record: ${DEV_DOMAIN} → ${SERVER_IP}"
  else
    curl -s -X POST -H "$DNSIMPLE_AUTH" -H "Content-Type: application/json" \
      -d "{\"name\":\"${SUBDOMAIN}\",\"type\":\"A\",\"content\":\"${SERVER_IP}\",\"ttl\":60}" \
      "${DNSIMPLE_API}" >/dev/null
    echo "  ✅ Created A record: ${DEV_DOMAIN} → ${SERVER_IP}"
  fi

  # Create/update wildcard A record
  WILDCARD_NAME="*.${SUBDOMAIN}"
  EXISTING=$(curl -s -H "$DNSIMPLE_AUTH" "${DNSIMPLE_API}?name=${WILDCARD_NAME}&type=A" | \
    python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(d[0]['id'] if d else '')" 2>/dev/null || echo "")

  if [[ -n "$EXISTING" ]]; then
    curl -s -X PATCH -H "$DNSIMPLE_AUTH" -H "Content-Type: application/json" \
      -d "{\"content\":\"${SERVER_IP}\"}" "${DNSIMPLE_API}/${EXISTING}" >/dev/null
    echo "  ✅ Updated A record: *.${DEV_DOMAIN} → ${SERVER_IP}"
  else
    curl -s -X POST -H "$DNSIMPLE_AUTH" -H "Content-Type: application/json" \
      -d "{\"name\":\"${WILDCARD_NAME}\",\"type\":\"A\",\"content\":\"${SERVER_IP}\",\"ttl\":60}" \
      "${DNSIMPLE_API}" >/dev/null
    echo "  ✅ Created A record: *.${DEV_DOMAIN} → ${SERVER_IP}"
  fi
else
  echo ""
  echo "  ⚠️  DNS: Add these records manually:"
  echo "     A    ${DEV_DOMAIN}    → ${SERVER_IP}"
  echo "     A    *.${DEV_DOMAIN}  → ${SERVER_IP}"
fi

echo ""
echo "═══════════════════════════════════════════"
echo "  Server Ready"
echo "═══════════════════════════════════════════"
echo ""
echo "  IP:  ${SERVER_IP}"
echo ""
echo "  Next: ./scripts/bootstrap.sh"
echo ""

# ── Save server IP for other scripts ──
echo "${SERVER_IP}" > "${SCRIPT_DIR}/../.server-ip"
