#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../.env"

if [[ ! -f "${SCRIPT_DIR}/../.server-ip" ]]; then
  echo "No .server-ip file. Run provision.sh first." >&2
  exit 1
fi

SERVER_IP=$(cat "${SCRIPT_DIR}/../.server-ip")

validate_name() {
  local name="$1"
  if [[ ! "$name" =~ ^[a-z0-9]([a-z0-9-]{0,54}[a-z0-9])?$ ]]; then
    echo "Invalid stack name: ${name}" >&2
    echo "Use a DNS-safe name up to 56 characters: lowercase letters, numbers, and dashes; no leading or trailing dash." >&2
    exit 1
  fi
}

# ── Resolve SSH key path ──
SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
[[ -f "$SSH_KEY_PATH" ]] && SSH_OPTS="$SSH_OPTS -i $SSH_KEY_PATH"

COMMAND="${1:-help}"
NAME="${2:-}"
EXTRA="${3:-}"

case "$COMMAND" in
  create|destroy|env|studio|list|status|restart|help) ;;
  *)
    echo "Unknown command: ${COMMAND}" >&2
    echo "Usage: stack.sh <create|destroy|env|studio|list|status|restart> [name]" >&2
    exit 1
    ;;
esac

if [[ -n "$NAME" ]]; then
  validate_name "$NAME"
fi

if [[ "$COMMAND" == "destroy" && -n "$EXTRA" && "$EXTRA" != "--force" ]]; then
  echo "Unknown destroy option: ${EXTRA}" >&2
  echo "Usage: stack.sh destroy <name> [--force]" >&2
  exit 1
fi

# Pass config as env vars to the remote script
REMOTE_ENV="DEV_DOMAIN=${DEV_DOMAIN} SUPABASE_PORT_BASE=${SUPABASE_PORT_BASE} SUPABASE_PORT_BLOCK=${SUPABASE_PORT_BLOCK}"

# shellcheck disable=SC2086
case "$COMMAND" in
  env)
    ssh -q $SSH_OPTS root@"${SERVER_IP}" "${REMOTE_ENV} /opt/supabase/scripts/stack.sh env ${NAME}"
    ;;
  studio)
    ssh -q $SSH_OPTS root@"${SERVER_IP}" "${REMOTE_ENV} /opt/supabase/scripts/stack.sh studio ${NAME}"
    ;;
  create)
    ssh $SSH_OPTS root@"${SERVER_IP}" "${REMOTE_ENV} /opt/supabase/scripts/stack.sh create ${NAME}"
    ;;
  destroy)
    ssh $SSH_OPTS root@"${SERVER_IP}" "${REMOTE_ENV} /opt/supabase/scripts/stack.sh destroy ${NAME} ${EXTRA}"
    ;;
  list)
    ssh $SSH_OPTS root@"${SERVER_IP}" "${REMOTE_ENV} /opt/supabase/scripts/stack.sh list"
    ;;
  status|restart)
    ssh $SSH_OPTS root@"${SERVER_IP}" "${REMOTE_ENV} /opt/supabase/scripts/stack.sh ${COMMAND} ${NAME}"
    ;;
  help)
    ssh $SSH_OPTS root@"${SERVER_IP}" "${REMOTE_ENV} /opt/supabase/scripts/stack.sh help"
    ;;
  *)
    echo "Unknown command: ${COMMAND}" >&2
    exit 1
    ;;
esac
