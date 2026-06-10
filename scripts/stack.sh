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
  create|destroy|env|list|status|restart|hibernate|wake|help) ;;
  *)
    echo "Unknown command: ${COMMAND}" >&2
    echo "Usage: stack.sh <create|destroy|env|list|status|restart|hibernate|wake> [name]" >&2
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

# Pass config as env vars to the remote script (%q-quoted: .env values are
# untrusted input to the remote shell)
printf -v REMOTE_ENV 'DEV_DOMAIN=%q SUPABASE_PORT_BASE=%q SUPABASE_PORT_BLOCK=%q' "$DEV_DOMAIN" "$SUPABASE_PORT_BASE" "$SUPABASE_PORT_BLOCK"
if [[ -n "${MAX_RUNNING_STACKS:-}" ]]; then
  printf -v REMOTE_ENV '%s MAX_RUNNING_STACKS=%q' "$REMOTE_ENV" "$MAX_RUNNING_STACKS"
fi

# Run the remote stack script under the server-side lock so concurrent
# invocations (CI, other shells) serialize. Pass -q first to silence ssh.
remote_stack() {
  local quiet=""
  if [[ "${1:-}" == "-q" ]]; then
    quiet="-q"
    shift
  fi
  local remote_cmd="${REMOTE_ENV} /opt/supabase/scripts/stack.sh"
  local arg quoted_arg
  for arg in "$@"; do
    printf -v quoted_arg '%q' "$arg"
    remote_cmd="${remote_cmd} ${quoted_arg}"
  done
  local locked_cmd
  printf -v locked_cmd 'flock /opt/supabase/scripts/.stack.lock bash -lc %q' "$remote_cmd"
  # shellcheck disable=SC2086
  ssh $quiet $SSH_OPTS root@"${SERVER_IP}" "$locked_cmd"
}

case "$COMMAND" in
  env)
    remote_stack -q env "${NAME}"
    ;;
  create)
    remote_stack create "${NAME}"
    ;;
  destroy)
    remote_stack destroy "${NAME}" "${EXTRA}"
    ;;
  list)
    remote_stack list
    ;;
  status|restart|hibernate|wake)
    remote_stack "${COMMAND}" "${NAME}"
    ;;
  help)
    remote_stack help
    ;;
  *)
    echo "Unknown command: ${COMMAND}" >&2
    exit 1
    ;;
esac
