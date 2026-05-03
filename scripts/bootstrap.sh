#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../.env"

if [[ ! -f "${SCRIPT_DIR}/../.server-ip" ]]; then
  echo "❌ No .server-ip file found. Run provision.sh first."
  exit 1
fi

SERVER_IP=$(cat "${SCRIPT_DIR}/../.server-ip")

# ── Resolve SSH key path ──
SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
[[ -f "$SSH_KEY_PATH" ]] && SSH_OPTS="$SSH_OPTS -i $SSH_KEY_PATH"
# shellcheck disable=SC2086
remote() { ssh $SSH_OPTS root@"${SERVER_IP}" "$@"; }
# shellcheck disable=SC2086
remote_copy() { scp $SSH_OPTS "$@"; }

echo "═══════════════════════════════════════════"
echo "  Bootstrapping: root@${SERVER_IP}"
echo "═══════════════════════════════════════════"

# ── Build the remote setup script ──
cat >/tmp/bootstrap-remote.sh <<'REMOTE_SCRIPT'
#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "📦 Updating system..."
apt-get update -qq
apt-get upgrade -y -qq

# ── Docker ──
echo "🐳 Installing Docker..."
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker
  systemctl start docker
fi

# Docker Compose plugin (comes with modern Docker, but ensure it)
if ! docker compose version &>/dev/null; then
  apt-get install -y -qq docker-compose-plugin
fi

echo "  Docker: $(docker --version)"
echo "  Compose: $(docker compose version)"

# ── jq ──
echo "📦 Installing jq..."
apt-get install -y -qq jq

# ── nginx ──
echo "🌐 Installing nginx..."
apt-get install -y -qq nginx
systemctl enable nginx

# ── Certbot via snap (avoids pip/venv issues on Ubuntu 24.04) ──
echo "🔐 Installing certbot..."
# Remove apt certbot if present to avoid conflicts
apt-get remove -y -qq certbot python3-certbot-nginx 2>/dev/null || true
snap install --classic certbot 2>/dev/null || true
ln -sf /snap/bin/certbot /usr/bin/certbot

DNS_PROVIDER="__DNS_PROVIDER__"
snap set certbot trust-plugin-with-root=ok
case "$DNS_PROVIDER" in
  dnsimple)
    snap install certbot-dns-dnsimple 2>/dev/null || true
    ;;
  route53)
    snap install certbot-dns-route53 2>/dev/null || true
    ;;
  *)
    echo "❌ Unknown DNS provider: $DNS_PROVIDER"
    exit 1
    ;;
esac

# ── Project directories ──
mkdir -p /opt/supabase/{stacks,nginx,certs,scripts}
mkdir -p /opt/supabase/nginx/sites-enabled

# ── Disable Ubuntu default nginx site ──
rm -f /etc/nginx/sites-enabled/default

echo "✅ Base setup complete"
REMOTE_SCRIPT

# ── Inject DNS provider (portable sed — works on both macOS and Linux) ──
if [[ "$(uname)" == "Darwin" ]]; then
  sed -i '' "s/__DNS_PROVIDER__/${DNS_PROVIDER}/" /tmp/bootstrap-remote.sh
else
  sed -i "s/__DNS_PROVIDER__/${DNS_PROVIDER}/" /tmp/bootstrap-remote.sh
fi

# ── Upload and run ──
echo "📤 Uploading bootstrap script..."
remote_copy /tmp/bootstrap-remote.sh root@"${SERVER_IP}":/tmp/bootstrap-remote.sh

echo "🔧 Running bootstrap (this may take a few minutes)..."
remote "chmod +x /tmp/bootstrap-remote.sh && /tmp/bootstrap-remote.sh"
echo "✅ Bootstrap packages installed"

# ── Setup certbot credentials ──
echo ""
echo "🔐 Configuring DNS credentials for cert generation..."

if [[ "$DNS_PROVIDER" == "dnsimple" ]]; then
  if [[ -z "${DNSIMPLE_TOKEN:-}" ]]; then
    echo "❌ DNSIMPLE_TOKEN not set in .env"
    exit 1
  fi

  remote bash <<EOF
set -euo pipefail
mkdir -p /opt/supabase/certs
cat > /opt/supabase/certs/dnsimple.ini <<CREDS
dns_dnsimple_token = ${DNSIMPLE_TOKEN}
CREDS
chmod 600 /opt/supabase/certs/dnsimple.ini
EOF

  echo "🔐 Requesting wildcard certificate..."
  remote bash <<EOF
set -euo pipefail
certbot certonly \
  --dns-dnsimple \
  --dns-dnsimple-credentials /opt/supabase/certs/dnsimple.ini \
  --dns-dnsimple-propagation-seconds 30 \
  -d "*.${DEV_DOMAIN}" \
  -d "${DEV_DOMAIN}" \
  --email "${LETSENCRYPT_EMAIL}" \
  --agree-tos \
  --non-interactive

# Symlink certs to a stable path
ln -sf /etc/letsencrypt/live/${DEV_DOMAIN}/fullchain.pem /opt/supabase/certs/fullchain.pem
ln -sf /etc/letsencrypt/live/${DEV_DOMAIN}/privkey.pem /opt/supabase/certs/privkey.pem
EOF

elif [[ "$DNS_PROVIDER" == "route53" ]]; then
  remote bash <<EOF
set -euo pipefail
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"

certbot certonly \
  --dns-route53 \
  -d "*.${DEV_DOMAIN}" \
  -d "${DEV_DOMAIN}" \
  --email "${LETSENCRYPT_EMAIL}" \
  --agree-tos \
  --non-interactive

ln -sf /etc/letsencrypt/live/${DEV_DOMAIN}/fullchain.pem /opt/supabase/certs/fullchain.pem
ln -sf /etc/letsencrypt/live/${DEV_DOMAIN}/privkey.pem /opt/supabase/certs/privkey.pem
EOF
fi

# ── Write nginx config ──
# Done here (after certs exist) rather than in the remote script,
# because the default_server block references the SSL cert files.
echo "🌐 Configuring nginx..."
remote bash <<'NGINX_SETUP'
set -euo pipefail
cat > /etc/nginx/nginx.conf <<'NGINX_CONF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    sendfile on;
    keepalive_timeout 65;
    client_max_body_size 100m;

    # Logging
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent"';
    access_log /var/log/nginx/access.log main;

    # Include per-project site configs
    include /opt/supabase/nginx/sites-enabled/*.conf;

    # Default server — reject unknown hosts
    server {
        listen 80 default_server;
        listen 443 ssl default_server;
        ssl_certificate /opt/supabase/certs/fullchain.pem;
        ssl_certificate_key /opt/supabase/certs/privkey.pem;
        server_name _;
        return 444;
    }
}
NGINX_CONF

# Remove Ubuntu default site (in case it was re-created by an upgrade)
rm -f /etc/nginx/sites-enabled/default
NGINX_SETUP

# ── Restart nginx ──
remote "nginx -t && systemctl restart nginx"

# ── Upload the stack management script ──
echo "📤 Uploading stack management tools..."
remote_copy "${SCRIPT_DIR}/../templates/docker-compose.yml.tpl" root@"${SERVER_IP}":/opt/supabase/scripts/
remote_copy "${SCRIPT_DIR}/../templates/nginx-site.conf.tpl" root@"${SERVER_IP}":/opt/supabase/scripts/
remote_copy "${SCRIPT_DIR}/../templates/kong.yml.tpl" root@"${SERVER_IP}":/opt/supabase/scripts/
remote_copy "${SCRIPT_DIR}/../scripts/stack-remote.sh" root@"${SERVER_IP}":/opt/supabase/scripts/stack.sh
remote "chmod +x /opt/supabase/scripts/stack.sh"

# ── Setup certbot auto-renewal ──
remote bash <<'EOF'
set -euo pipefail
cat > /etc/cron.d/certbot-renew <<CRON
0 3 * * * root certbot renew --quiet --post-hook "systemctl reload nginx"
CRON
EOF

echo ""
echo "═══════════════════════════════════════════"
echo "  Bootstrap Complete"
echo "═══════════════════════════════════════════"
echo ""
echo "  Server: root@${SERVER_IP}"
echo "  Domain: *.${DEV_DOMAIN}"
echo "  SSL:    ✅ Wildcard cert active"
echo ""
echo "  Next: ./scripts/stack.sh create <project-name>"
echo ""
