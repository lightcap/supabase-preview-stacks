#!/bin/bash
set -euo pipefail

WORKSTREAM_NAME="${1:?Usage: switch-workstream.sh <name> [project-dir]}"
if [[ ! "$WORKSTREAM_NAME" =~ ^[a-z0-9]([a-z0-9-]{0,54}[a-z0-9])?$ ]]; then
  echo "Invalid workstream name: ${WORKSTREAM_NAME}" >&2
  echo "Use a DNS-safe name up to 56 characters: lowercase letters, numbers, and dashes; no leading or trailing dash." >&2
  exit 1
fi

PROJECT_DIR="${2:-.}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

WORKSTREAM_DIR="${PROJECT_DIR}/.workstreams/${WORKSTREAM_NAME}"

if [[ ! -d "$WORKSTREAM_DIR" ]]; then
  echo "❌ Workstream '${WORKSTREAM_NAME}' not found"
  echo ""
  echo "Available workstreams:"
  if [[ -d "${PROJECT_DIR}/.workstreams" ]]; then
    for d in "${PROJECT_DIR}/.workstreams"/*/; do
      [[ -d "$d" ]] && echo "  $(basename "$d")"
    done
  else
    echo "  (none)"
  fi
  exit 1
fi

ln -sf ".workstreams/${WORKSTREAM_NAME}/merged.env" "${PROJECT_DIR}/.env.local"

echo "🔄 Switched to workstream '${WORKSTREAM_NAME}'"
echo "   .env.local → .workstreams/${WORKSTREAM_NAME}/merged.env"
