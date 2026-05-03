#!/bin/bash
set -euo pipefail

# Creates a full workstream: Supabase stack + Vercel env merge + .env.local activation
#
# Usage: ./scripts/init-workstream.sh <workstream-name> [project-dir]
#
# Example:
#   ./scripts/init-workstream.sh feature-auth ~/projects/my-app

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${SCRIPT_DIR}/.."
source "${INFRA_DIR}/.env"

WORKSTREAM_NAME="${1:?Usage: init-workstream.sh <workstream-name> [project-dir]}"
if [[ ! "$WORKSTREAM_NAME" =~ ^[a-z0-9]([a-z0-9-]{0,54}[a-z0-9])?$ ]]; then
  echo "Invalid workstream name: ${WORKSTREAM_NAME}" >&2
  echo "Use a DNS-safe name up to 56 characters: lowercase letters, numbers, and dashes; no leading or trailing dash." >&2
  exit 1
fi

PROJECT_DIR="${2:-.}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

WORKSTREAM_DIR="${PROJECT_DIR}/.workstreams/${WORKSTREAM_NAME}"
mkdir -p "$WORKSTREAM_DIR"

echo "═══════════════════════════════════════════"
echo "  Initializing workstream: ${WORKSTREAM_NAME}"
echo "  Project: ${PROJECT_DIR}"
echo "═══════════════════════════════════════════"
echo ""

# ── Step 1: Pull Vercel dev env as baseline ──
echo "📥 Pulling Vercel dev environment..."
if command -v vercel &>/dev/null; then
  (cd "$PROJECT_DIR" && vercel env pull "${WORKSTREAM_DIR}/vercel-base.env" --environment=development 2>/dev/null) || {
    echo "⚠️  Vercel env pull failed — continuing without baseline"
    touch "${WORKSTREAM_DIR}/vercel-base.env"
  }
else
  echo "⚠️  Vercel CLI not found — skipping baseline pull"
  touch "${WORKSTREAM_DIR}/vercel-base.env"
fi

# ── Step 2: Create Supabase stack on Hetzner ──
echo ""
echo "🚀 Creating Supabase stack..."
"${INFRA_DIR}/scripts/stack.sh" create "$WORKSTREAM_NAME"

# ── Step 3: Fetch env vars from the stack ──
echo ""
echo "📝 Fetching stack credentials..."
"${INFRA_DIR}/scripts/stack.sh" env "$WORKSTREAM_NAME" > "${WORKSTREAM_DIR}/supabase-overlay.env"

# ── Step 4: Merge envs — Vercel base + Supabase overlay ──
echo "🔀 Merging environments..."

merge_env_files() {
  local base="$1" overlay="$2" output="$3"

  declare -A env_map
  declare -a key_order=()

  # Load base
  while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    local key="${line%%=*}"
    local value="${line#*=}"
    if [[ -z "${env_map[$key]+x}" ]]; then
      key_order+=("$key")
    fi
    env_map["$key"]="$value"
  done < "$base"

  # Apply overlay (wins on conflict)
  while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    local key="${line%%=*}"
    local value="${line#*=}"
    if [[ -z "${env_map[$key]+x}" ]]; then
      key_order+=("$key")
    fi
    env_map["$key"]="$value"
  done < "$overlay"

  {
    echo "# Workstream: ${WORKSTREAM_NAME}"
    echo "# Merged: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "# Base: Vercel dev | Overlay: Supabase stack"
    echo ""
    for key in "${key_order[@]}"; do
      echo "${key}=${env_map[$key]}"
    done
  } > "$output"
}

merge_env_files \
  "${WORKSTREAM_DIR}/vercel-base.env" \
  "${WORKSTREAM_DIR}/supabase-overlay.env" \
  "${WORKSTREAM_DIR}/merged.env"

# ── Step 5: Save metadata ──
cat > "${WORKSTREAM_DIR}/metadata.json" <<EOF
{
  "name": "${WORKSTREAM_NAME}",
  "project_dir": "${PROJECT_DIR}",
  "infra_dir": "${INFRA_DIR}",
  "created_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

# ── Step 6: Activate ──
ln -sf ".workstreams/${WORKSTREAM_NAME}/merged.env" "${PROJECT_DIR}/.env.local"

echo ""
echo "═══════════════════════════════════════════"
echo "  ✅ Workstream '${WORKSTREAM_NAME}' is ready"
echo "═══════════════════════════════════════════"
echo ""
echo "  .env.local → .workstreams/${WORKSTREAM_NAME}/merged.env"
echo ""
echo "  To switch workstreams:"
echo "    ${INFRA_DIR}/scripts/switch-workstream.sh ${WORKSTREAM_NAME} ${PROJECT_DIR}"
echo ""
echo "  To tear down:"
echo "    ${INFRA_DIR}/scripts/teardown-workstream.sh ${WORKSTREAM_NAME} ${PROJECT_DIR}"
echo ""
