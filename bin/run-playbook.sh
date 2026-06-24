#!/usr/bin/env bash
# run-playbook.sh — wrapper for ansible-playbook that exports OpenBao secrets to a
# temp vars file before execution.
#
# Usage:
#   bin/run-playbook.sh <ENV_NAME> <playbook> [ansible-playbook args...]
#
# ENV_NAME is required and maps to the env's inventory directory under
# ~/.dmfdeploy/envs/<ENV_NAME>/inventory/. The wrapper used to default to a
# baked-in env name; that default was removed (env ids rotate as we cut new
# test clusters, so a static default just enabled drift).
# Look up the current env id in the umbrella's STATUS.md.
#
# Examples:
#   bin/run-playbook.sh <env-name> ../dmf-infra/k3s-lab-bootstrap/playbooks/600-landing-page.yml
#   bin/run-playbook.sh <env-name> playbooks/610-netbox.yml --check
#   bin/run-playbook.sh <env-name> playbooks/300-k3s.yml --tags k3s_server
#
# Secret metadata lives in the env's bundle (resolved via the env path resolver).
# The wrapper authenticates to OpenBao with AppRole, fetches the kv-v2 document,
# and passes a generated temp vars file into ansible-playbook with -e @file.

set -euo pipefail

# Resolve script directory so this works from any cwd
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck source=lib/_resolve_env_paths.sh
. "$SCRIPT_DIR/lib/_resolve_env_paths.sh"
dmf_source_operator_config

# Ensure we run from repo root
cd "$REPO_DIR"

# Default the sops age-key location when the operator hasn't set it. sops's
# macOS default (~/Library/Application Support/...) differs from where the DMF
# age key lives (~/.config/sops/age/keys.txt); without this, an unset
# SOPS_AGE_KEY_FILE silently decrypts the env bundle to empty and the downstream
# json.load crashes. Guarded on file existence so it is a no-op when the key is
# absent or the operator set their own. (umbrella #125)
if [ -z "${SOPS_AGE_KEY_FILE:-}" ] && [ -f "$HOME/.config/sops/age/keys.txt" ]; then
  export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
fi

print_envs_and_die() {
  local msg="$1"
  echo "$msg" >&2
  echo "" >&2
  echo "Usage: bin/run-playbook.sh <ENV_NAME> <playbook> [ansible-playbook args...]" >&2
  echo "" >&2
  echo "Available environments:" >&2
  local env
  while IFS= read -r env; do
    [ -n "$env" ] && echo "  $env" >&2
  done < <(dmf_list_known_envs)
  echo "" >&2
  echo "Current live env id is in the umbrella's STATUS.md." >&2
  exit 1
}

# Parse first argument: it must be a known env id. The old default-env
# behaviour is gone (env ids rotate, baking one in caused drift).
if [ $# -eq 0 ]; then
  print_envs_and_die "ERROR: no ENV_NAME passed."
fi

if ! dmf_resolve_env_paths "$1"; then
  print_envs_and_die "ERROR: '$1' is not a known env (no ~/.dmfdeploy/envs/$1/)."
fi

ENV_NAME="$1"
shift

INVENTORY="${DMF_ENV_INVENTORY_DIR}"

if [ $# -eq 0 ]; then
  print_envs_and_die "ERROR: no playbook path passed (env '$ENV_NAME' is valid)."
fi

PLAYBOOK="$1"
shift

# Auto-discover ansible.cfg from the playbook's directory tree.
# The playbook path is typically ../dmf-infra/k3s-lab-bootstrap/playbooks/<name>.yml,
# and ansible.cfg lives in the parent directory (k3s-lab-bootstrap/).
if [ -z "${ANSIBLE_CONFIG:-}" ]; then
  PLAYBOOK_DIR="$(cd "$(dirname "$PLAYBOOK")" && pwd)"
  # Walk up to 3 levels looking for ansible.cfg, starting with the playbook's own directory
  for candidate in "$PLAYBOOK_DIR/ansible.cfg" \
                   "$PLAYBOOK_DIR/../ansible.cfg" \
                   "$PLAYBOOK_DIR/../../ansible.cfg" \
                   "$PLAYBOOK_DIR/../../../ansible.cfg"; do
    if [ -f "$candidate" ]; then
      export ANSIBLE_CONFIG="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"
      break
    fi
  done
  if [ -z "${ANSIBLE_CONFIG:-}" ]; then
    echo "WARNING: No ansible.cfg found near playbook path '$PLAYBOOK'" >&2
    echo "  Roles may not resolve correctly if roles_path is not set." >&2
  fi
fi

# BSD/macOS `mktemp` does not support GNU-style suffix templates like
# `name.XXXXXX.json`; use a plain unique filename instead.
TMP_VARS_FILE="$(mktemp "${TMPDIR:-/tmp}/openbao-vars-${ENV_NAME}.XXXXXX")"
MATERIALIZED_KEY_FILES=()

cleanup() {
  rm -f "$TMP_VARS_FILE"
  local f
  for f in ${MATERIALIZED_KEY_FILES[@]+"${MATERIALIZED_KEY_FILES[@]}"}; do
    [ -f "$f" ] && { shred -u "$f" 2>/dev/null || rm -f "$f"; }
  done
}
trap cleanup EXIT

# Materialize the per-env SSH private keys from the sops bundle to 0600 files
# (new-layout envs). The privkeys are stored base64 (single line) — a raw
# multi-line PEM in a YAML scalar gets its newlines folded to spaces (→ corrupt
# key). One decrypt; python writes each key straight to its 0600 file via
# os.open, so the raw key never enters a shell variable, argv, or stdout.
materialize_ssh_privkeys() {
  if [ -z "${DMF_ENV_BUNDLE_FILE:-}" ] || [ ! -f "$DMF_ENV_BUNDLE_FILE" ] \
     || [ -z "${DMF_ENV_SSH_DIR:-}" ]; then
    return 0
  fi
  install -d -m 0700 "${DMF_ENV_SSH_DIR}"
  MATERIALIZED_KEY_FILES=("${DMF_ENV_SSH_DIR}/operator.key" "${DMF_ENV_SSH_DIR}/awx-control-node.key")
  sops --decrypt --output-type json "$DMF_ENV_BUNDLE_FILE" 2>/dev/null \
    | DMF_ENV_SSH_DIR="$DMF_ENV_SSH_DIR" python3 -c '
import json, sys, base64, os
ssh = json.load(sys.stdin).get("ssh", {})
ssh_dir = os.environ["DMF_ENV_SSH_DIR"]
for field, name in (("operator_private_key_b64", "operator.key"),
                    ("awx_control_node_private_key_b64", "awx-control-node.key")):
    v = ssh.get(field, "")
    if not v:
        continue
    fd = os.open(os.path.join(ssh_dir, name), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, base64.b64decode(v))
    finally:
        os.close(fd)
'
}

"$SCRIPT_DIR/bootstrap-secrets.sh" export-vars "$ENV_NAME" "$TMP_VARS_FILE"

# Materialize per-env SSH privkeys (operator + AWX control-node) from the bundle
materialize_ssh_privkeys

# Log + timeout guardrails (see docs/run-playbook.md).
# - Every run is captured to /tmp/dmf-playbook-logs/<name>-<ts>.log.
# - Hard cap runtime to RUNBOOK_TIMEOUT seconds so ControlMaster mux hangs
#   cannot wedge the session indefinitely.
# - Default cap depends on the target:
#     * ordinary playbooks:   900s
#     * lifecycle-*.yml:      1800s
#     * site.yml:             7200s
# - Output is tee'd: operators still see progress live in the terminal.
LOG_DIR="/tmp/dmf-playbook-logs"
mkdir -p "$LOG_DIR"
PLAYBOOK_BASENAME="$(basename "$PLAYBOOK")"
PLAYBOOK_BASENAME="${PLAYBOOK_BASENAME%.yml}"
PLAYBOOK_BASENAME="${PLAYBOOK_BASENAME%.yaml}"
LOG_FILE="$LOG_DIR/${PLAYBOOK_BASENAME}-$(date +%Y%m%d-%H%M%S).log"
if [ -n "${RUNBOOK_TIMEOUT:-}" ]; then
  TIMEOUT_SEC="$RUNBOOK_TIMEOUT"
else
  case "$(basename "$PLAYBOOK")" in
    site.yml|site.yaml)
      TIMEOUT_SEC=7200
      ;;
    lifecycle-*.yml|lifecycle-*.yaml)
      TIMEOUT_SEC=1800
      ;;
    *)
      TIMEOUT_SEC=900
      ;;
  esac
fi

echo "==> Logging to: $LOG_FILE" >&2
echo "==> Timeout:    ${TIMEOUT_SEC}s (override via RUNBOOK_TIMEOUT=<sec>)" >&2
echo "==> Stream with: $SCRIPT_DIR/monitor-playbook.sh $LOG_FILE" >&2
echo >&2

set +e
# Inject dmf_inventory_env_name so consumers (notably dmf-born-inventory)
# can use the inventory directory name as the fallback identifier on
# legacy envs that pre-date the dmf_env_id schema. New envs override this
# with a stronger signal (dmf_env_id from group_vars/all/main.yml).
timeout "$TIMEOUT_SEC" ansible-playbook \
  -i "$INVENTORY" \
  -e "@${TMP_VARS_FILE}" \
  -e "dmf_inventory_env_name=${ENV_NAME}" \
  "$PLAYBOOK" \
  "$@" 2>&1 | tee "$LOG_FILE"
RC=${PIPESTATUS[0]}
set -e

if [ "$RC" -eq 124 ]; then
  echo >&2
  echo "==> ERROR: playbook exceeded ${TIMEOUT_SEC}s cap and was killed." >&2
  echo "==> Likely a ControlMaster mux hang. Recovery:" >&2
  echo "      pkill -f 'ansible-playbook.*${PLAYBOOK_BASENAME}'" >&2
  echo "      rm -f /Users/\$(whoami)/.ansible/cp/*" >&2
  echo "      # then re-run the playbook" >&2
fi

exit "$RC"
