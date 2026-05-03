#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FORCE=""
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --force|-f) FORCE="--force" ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done

WORKSTREAM_NAME="${POSITIONAL[0]:?Usage: teardown-workstream.sh <name> [project-dir] [--force]}"
if [[ ! "$WORKSTREAM_NAME" =~ ^[a-z0-9]([a-z0-9-]{0,54}[a-z0-9])?$ ]]; then
  echo "Invalid workstream name: ${WORKSTREAM_NAME}" >&2
  echo "Use a DNS-safe name up to 56 characters: lowercase letters, numbers, and dashes; no leading or trailing dash." >&2
  exit 1
fi

PROJECT_DIR="${POSITIONAL[1]:-.}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

WORKSTREAM_DIR="${PROJECT_DIR}/.workstreams/${WORKSTREAM_NAME}"

if [[ ! -d "$WORKSTREAM_DIR" ]]; then
  echo "❌ Workstream '${WORKSTREAM_NAME}' not found"
  exit 1
fi

# Read the infra dir from metadata to find the stack.sh script
INFRA_DIR="${SCRIPT_DIR}/.."
if [[ -f "${WORKSTREAM_DIR}/metadata.json" ]]; then
  STORED_INFRA=$(jq -r '.infra_dir // empty' "${WORKSTREAM_DIR}/metadata.json")
  [[ -n "$STORED_INFRA" ]] && INFRA_DIR="$STORED_INFRA"
fi

if [[ "$FORCE" != "--force" ]]; then
  echo "⚠️  Tearing down workstream: ${WORKSTREAM_NAME}"
  echo "   This will destroy the Supabase stack and all its data."
  read -p "   Continue? [y/N] " -n 1 -r
  echo

  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
  fi
fi

# ── Destroy the remote stack ──
echo "🗑️  Destroying Supabase stack..."
"${INFRA_DIR}/scripts/stack.sh" destroy "$WORKSTREAM_NAME" --force || {
  echo "⚠️  Remote stack destruction failed — cleaning up local files anyway"
}

# ── Clean up local files ──
rm -rf "$WORKSTREAM_DIR"

# Clean up .env.local symlink if it points to this workstream
if [[ -L "${PROJECT_DIR}/.env.local" ]]; then
  LINK_TARGET=$(readlink "${PROJECT_DIR}/.env.local")
  if [[ "$LINK_TARGET" == *"${WORKSTREAM_NAME}"* ]]; then
    rm "${PROJECT_DIR}/.env.local"
    echo "🔗 Removed .env.local symlink"

    # Point to another workstream if one exists
    if [[ -d "${PROJECT_DIR}/.workstreams" ]]; then
      for d in "${PROJECT_DIR}/.workstreams"/*/; do
        if [[ -d "$d" && -f "${d}/merged.env" ]]; then
          OTHER=$(basename "$d")
          ln -sf ".workstreams/${OTHER}/merged.env" "${PROJECT_DIR}/.env.local"
          echo "🔄 .env.local now points to workstream '${OTHER}'"
          break
        fi
      done
    fi
  fi
fi

echo "✅ Workstream '${WORKSTREAM_NAME}' torn down"
