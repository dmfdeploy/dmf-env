#!/usr/bin/env bash
# rotate-approle-secret-id.sh — workstation-side wrapper.
#
# Reads ops_admin from the OpenBao break-glass JSON, SSHes to the control
# node, asks `cluster-rotate-approle-secret-id.sh` to mint a fresh
# AppRole secret_id, and lands the value in macOS Keychain. Mirrors the
# `bin/get-admin-cred.sh` pattern (skill: dmf-cluster-access §5.1).
#
# Usage:
#   bin/rotate-approle-secret-id.sh <ENV_NAME> <approle> <keychain-service> [keychain-account=secret-id]
#
# Example (post-rename cutover, 2026-05-07):
#   bin/rotate-approle-secret-id.sh <env-name> k3s-infra-lab openbao-approle-dmf-infra
#
# What it prints:
#   role_id (informational, non-secret) on stderr
#   "✓ keychain updated" on stdout
# What it does NOT print: the secret_id. Operator never sees it; it flows
# pod stdout → ssh → local subshell var → `security add` argv → Keychain.

set -euo pipefail

# Resolve script + repo dir so this works from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# ── Inventory parsers (mirror get-admin-cred.sh) ──────────────────────────
parse_yaml_scalar() {
    local file="$1" key="$2"
    [ -r "$file" ] || return 1
    grep -E "^${key}:" "$file" | head -1 | \
        sed -E "s/^${key}:[[:space:]]*//; s/[[:space:]]*#.*\$//; s/^[\"']//; s/[\"']\$//"
}

parse_yaml_scalar_anywhere() {
    # Same as parse_yaml_scalar but searches every *.yml under group_vars/all/
    local dir="$1" key="$2"
    [ -d "$dir" ] || return 1
    grep -hE "^${key}:" "$dir"/*.yml 2>/dev/null | head -1 | \
        sed -E "s/^${key}:[[:space:]]*//; s/[[:space:]]*#.*\$//; s/^[\"']//; s/[\"']\$//"
}

parse_inventory_ssh_target() {
    local hosts_ini="$1"
    [ -r "$hosts_ini" ] || return 1
    local ctl
    ctl="$(awk '
        /^\[k3s_control\]/ { in_ctl=1; next }
        /^\[/              { in_ctl=0 }
        in_ctl && NF>0 && $1 !~ /^#/ { print $1; exit }
    ' "$hosts_ini")"
    [ -n "$ctl" ] || return 1
    awk -v h="$ctl" '
        /^\[k3s\]/ { in_k3s=1; next }
        /^\[/      { in_k3s=0 }
        in_k3s && $1==h {
            user=""; ip="";
            for (i=2; i<=NF; i++) {
                if ($i ~ /^ansible_host=/) { ip=$i;   sub(/^ansible_host=/, "", ip) }
                if ($i ~ /^ansible_user=/) { user=$i; sub(/^ansible_user=/, "", user) }
            }
            if (user!="" && ip!="") { print user "@" ip; exit }
        }
    ' "$hosts_ini"
}

expand_local_path() {
    case "$1" in
        "~/"*) printf '%s/%s' "$HOME" "${1#"~/"}" ;;
        *) printf '%s' "$1" ;;
    esac
}

# shellcheck source=lib/_resolve_env_paths.sh
. "$SCRIPT_DIR/lib/_resolve_env_paths.sh"
dmf_source_operator_config

# ── Argument parsing — ENV_NAME is the required first positional arg ────
if [ $# -gt 0 ] && dmf_env_exists "$1"; then
    ENV_NAME="$1"
    shift
    dmf_resolve_env_paths "$ENV_NAME"
else
    echo "ERROR: <ENV_NAME> is required as the first positional arg." >&2
    echo "Available envs:" >&2
    while IFS= read -r env; do
        [ -n "$env" ] && echo "  $env" >&2
    done < <(dmf_list_known_envs)
    echo "(current live env id is in the umbrella's STATUS.md)" >&2
    exit 1
fi

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    cat >&2 <<'USAGE'
Usage: rotate-approle-secret-id.sh <ENV_NAME> <approle> <keychain-service> [keychain-account=secret-id]

  ENV_NAME          — inventory environment (required; current id in umbrella STATUS.md)
  approle           — OpenBao AppRole name
  keychain-service  — macOS Keychain service name
  keychain-account  — Keychain account; defaults to "secret-id"

Generates a fresh OpenBao AppRole secret_id on the control node and stores
it in macOS Keychain under the given service+account. The secret_id is
never echoed to the terminal or to stdout.
USAGE
    exit 1
fi

APPROLE="$1"
KEYCHAIN_SERVICE="$2"
KEYCHAIN_ACCOUNT="${3:-secret-id}"

INVENTORY_DIR="$DMF_ENV_INVENTORY_DIR"
GROUP_VARS_DIR="$INVENTORY_DIR/group_vars/all"
HOSTS_INI="$INVENTORY_DIR/hosts.ini"

# Derive defaults from inventory; env vars override below.
DERIVED_KEY_PATH="$(parse_yaml_scalar "$GROUP_VARS_DIR/openbao.yml" openbao_key_path 2>/dev/null || true)"
DERIVED_BREAKGLASS=""
[ -n "$DERIVED_KEY_PATH" ] && DERIVED_BREAKGLASS="$(expand_local_path "${DERIVED_KEY_PATH}").json"

DERIVED_SSH_TARGET="$(parse_inventory_ssh_target "$HOSTS_INI" 2>/dev/null || true)"

DERIVED_SSH_KEY="$(parse_yaml_scalar_anywhere "$GROUP_VARS_DIR" ansible_ssh_private_key_file 2>/dev/null || true)"
[ -n "$DERIVED_SSH_KEY" ] && DERIVED_SSH_KEY="$(expand_local_path "$DERIVED_SSH_KEY")"

# ── Configuration (all overridable via env) ──────────────────────────────
BREAKGLASS_FILE="${OPENBAO_BREAKGLASS_FILE:-${DERIVED_BREAKGLASS:-}}"
[ -n "$BREAKGLASS_FILE" ] || { echo "error: break-glass file not resolvable for '$ENV_NAME' — set OPENBAO_BREAKGLASS_FILE or ensure the env inventory sets openbao_key_path" >&2; exit 1; }
SSH_TARGET="${OPENBAO_SSH_TARGET:-${DERIVED_SSH_TARGET:-}}"
if [ -z "$SSH_TARGET" ]; then
    echo "error: SSH target not resolvable for env '${ENV_NAME}'" >&2
    echo "       set OPENBAO_SSH_TARGET=k3s-admin@<control-node-ip> or" >&2
    echo "       ensure $HOSTS_INI yields a parseable ansible_host" >&2
    exit 2
fi
SSH_KEY="${OPENBAO_SSH_KEY:-${DERIVED_SSH_KEY:-}}"
CLUSTER_SCRIPT="${CLUSTER_SCRIPT:-./cluster-rotate-approle-secret-id.sh}"

if [ ! -r "$BREAKGLASS_FILE" ]; then
    echo "error: break-glass file not readable: $BREAKGLASS_FILE" >&2
    exit 2
fi

OPS_PASS="$(jq -re '.ops_admin_password' "$BREAKGLASS_FILE" 2>/dev/null || true)"
if [ -z "${OPS_PASS}" ]; then
    echo "error: ops_admin_password missing from $BREAKGLASS_FILE" >&2
    exit 3
fi

# Build SSH args with optional key
ssh_args=(-q)
[ -n "$SSH_KEY" ] && ssh_args+=(-i "$SSH_KEY")

# Capture only stdout (secret_id) into a shell variable. stderr (role_id +
# progress) flows through to the operator's terminal so they see what's
# happening without it being piped.
SECRET_ID="$(
    printf '%s\n' "$OPS_PASS" \
    | ssh "${ssh_args[@]}" "$SSH_TARGET" "$CLUSTER_SCRIPT" "$APPROLE"
)"

unset OPS_PASS

if [ -z "$SECRET_ID" ]; then
    echo "error: cluster script returned no secret_id" >&2
    exit 4
fi

# Replace any prior keychain entry under this service+account, then insert
# the fresh value. `-w "$SECRET_ID"` is briefly argv-visible to `ps` on this
# host — acceptable for dev creds on the operator's own workstation per
# the skill's §0 risk note.
security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1 || true
security add-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w "$SECRET_ID"
unset SECRET_ID

echo "✓ keychain updated: service='$KEYCHAIN_SERVICE' account='$KEYCHAIN_ACCOUNT'"
