#!/usr/bin/env bash
# get-admin-cred.sh — retrieve an app's admin credential from OpenBao via
# the operator userpass path (Phase 5 of the Authentik baseline plan).
#
# Usage:
#   bin/get-admin-cred.sh <ENV_NAME> <app>           # prints full KV response JSON
#   bin/get-admin-cred.sh <env-name> authentik | jq .data.data
#
# ENV_NAME is required; the wrapper used to default to a baked-in env name
# but env ids rotate as we cut new test clusters, so a static default just
# enabled drift. Look up the current env id in the umbrella's STATUS.md.
# When supplied, $OPENBAO_BREAKGLASS_FILE,
# $OPENBAO_SSH_TARGET, and the SSH key are derived from the env's inventory:
#   ~/.dmfdeploy/envs/<env>/inventory/group_vars/all/*.yml → openbao_key_path
#   ~/.dmfdeploy/envs/<env>/inventory/hosts.ini            → [k3s_control] host
# Each derived value can still be overridden via the matching env var.
#
# Mechanism: pipe a sh script via SSH → kubectl exec -i, so the password is
# never in argv on the bastion. bao login writes the token to ~/.bao-token
# inside the pod's ephemeral session; the following bao kv get reuses it.

set -euo pipefail

# Resolve script + repo dir so this works from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# ── Inventory parsers (mirror unseal-openbao.sh) ─────────────────────────
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

if [ $# -ne 1 ]; then
    echo "Usage: $(basename "$0") <ENV_NAME> <app>" >&2
    echo "  e.g. $(basename "$0") <env-name> authentik" >&2
    exit 1
fi

APP="$1"

INVENTORY_DIR="$DMF_ENV_INVENTORY_DIR"
GROUP_VARS_DIR="$INVENTORY_DIR/group_vars/all"
HOSTS_INI="$INVENTORY_DIR/hosts.ini"

# Derive defaults from inventory; env vars override below.
DERIVED_KEY_PATH="$(parse_yaml_scalar_anywhere "$GROUP_VARS_DIR" openbao_key_path 2>/dev/null || true)"
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
OPENBAO_NAMESPACE="${OPENBAO_NAMESPACE:-openbao}"
OPENBAO_POD="${OPENBAO_POD:-openbao-0}"

if [ ! -r "$BREAKGLASS_FILE" ]; then
    echo "error: break-glass file not readable: $BREAKGLASS_FILE" >&2
    exit 2
fi

USERNAME="$(jq -re '.ops_admin_username' "$BREAKGLASS_FILE" 2>/dev/null || true)"
PASSWORD="$(jq -re '.ops_admin_password' "$BREAKGLASS_FILE" 2>/dev/null || true)"

if [ -z "${USERNAME}" ] || [ -z "${PASSWORD}" ]; then
    echo "error: ops_admin_username / ops_admin_password missing from $BREAKGLASS_FILE" >&2
    echo "       run the openbao role to seed the operator userpass path" >&2
    exit 3
fi

# Pre-flight info to stderr (so caller's | jq pipeline still sees only JSON)
{
    echo "env:           $ENV_NAME"
    echo "ssh target:    $SSH_TARGET"
    echo "breakglass:    $BREAKGLASS_FILE"
    echo "app:           $APP"
} >&2

# Generated password charset is ascii_letters+digits — no shell metacharacters,
# safe for single-quoted inlining in the heredoc below.
ssh_args=(-o LogLevel=ERROR)
[ -n "$SSH_KEY" ] && ssh_args+=(-i "$SSH_KEY")

ssh "${ssh_args[@]}" "$SSH_TARGET" \
    sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
        -n "$OPENBAO_NAMESPACE" exec -i "$OPENBAO_POD" -- sh <<EOF
set -e
TOKEN=\$(bao login -no-store -format=json -method=userpass \
  username='${USERNAME}' password='${PASSWORD}' 2>/dev/null \
  | sed -n 's/.*"client_token"[ ]*:[ ]*"\([^"]*\)".*/\1/p')
[ -n "\$TOKEN" ] || { echo "userpass login produced no token" >&2; exit 4; }
BAO_TOKEN=\$TOKEN bao kv get -format=json 'secret/apps/${APP}/admin'
EOF
