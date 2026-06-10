#!/usr/bin/env bash
# bootstrap-operator-approle.sh — workstation-side wrapper.
#
# Creates the env-specific operator AppRole + policy in OpenBao (cluster
# side), updates openbao_secrets.yml with the new role_id, and lands the
# secret_id in macOS Keychain — all in one command. Mirrors the
# get-admin-cred.sh / rotate-approle-secret-id.sh patterns.
#
# Use this AFTER a fresh OpenBao bootstrap to set up the operator AppRole
# (the openbao role auto-creates ESO + born-inventory AppRoles, but not the
# narrow-scope one bin/run-playbook.sh consumes).
#
# Usage:
#   bin/bootstrap-operator-approle.sh <ENV_NAME> <approle> <keychain-service> [keychain-account=secret-id] [scope=k3s-hetzner]
#
# Example (post-fresh-rollout; <env-id> is your env, current id in the umbrella STATUS.md):
#   bin/bootstrap-operator-approle.sh <env-id> dmf-infra openbao-approle-dmf-infra
#
# What it prints:
#   role_id (informational; also written to openbao_secrets.yml) on stderr
#   "✓ keychain updated", "✓ openbao_role_id updated" on stdout/stderr
# What it does NOT print: the secret_id.
#
# Pre-reqs:
#   - cluster-bootstrap-operator-approle.sh exists in $HOME on the control node
#     (scp it first; this wrapper assumes it's at ./cluster-bootstrap-operator-approle.sh
#     relative to the control node's $HOME).
#   - The break-glass JSON exists at $OPENBAO_BREAKGLASS_FILE and contains
#     ops_admin_password (re-seeded by the openbao role on bootstrap).

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

if [ $# -lt 2 ] || [ $# -gt 4 ]; then
    cat >&2 <<'USAGE'
Usage: bootstrap-operator-approle.sh <ENV_NAME> <approle> <keychain-service> [keychain-account=secret-id] [scope=k3s-hetzner]

  ENV_NAME          — inventory environment (required; current id in umbrella STATUS.md)
  approle           — name for the OpenBao AppRole AND its matching policy
  keychain-service  — macOS Keychain service name (matches openbao_keychain_service)
  keychain-account  — Keychain account; defaults to "secret-id"
  scope             — first path segment under secret/data/; defaults to "k3s-hetzner"

After fresh OpenBao bootstrap, this:
  1. Creates a narrow policy granting r/c/u on secret/data/<scope>/*
  2. Creates the AppRole bound to that policy (TTLs: 1h/24h/365d)
  3. Mints role_id + secret_id
  4. Writes role_id into ~/.dmfdeploy/envs/<env>/openbao_secrets.yml
  5. Writes secret_id into macOS Keychain
USAGE
    exit 1
fi

APPROLE="$1"
KEYCHAIN_SERVICE="$2"
KEYCHAIN_ACCOUNT="${3:-secret-id}"
SCOPE="${4:-k3s-hetzner}"

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
CLUSTER_SCRIPT="${CLUSTER_SCRIPT:-./cluster-bootstrap-operator-approle.sh}"
SECRETS_YML="${SECRETS_YML:-$GROUP_VARS_DIR/openbao_secrets.yml}"

if [ ! -r "$BREAKGLASS_FILE" ]; then
    echo "error: break-glass file not readable: $BREAKGLASS_FILE" >&2
    exit 2
fi

OPS_PASS="$(jq -re '.ops_admin_password' "$BREAKGLASS_FILE" 2>/dev/null || true)"
if [ -z "$OPS_PASS" ]; then
    echo "error: ops_admin_password missing from $BREAKGLASS_FILE" >&2
    exit 3
fi

# Build SSH args with optional key
ssh_args=(-q)
[ -n "$SSH_KEY" ] && ssh_args+=(-i "$SSH_KEY")

# Run the cluster-side script. stdin = password; stdout = ROLE_ID/SECRET_ID lines;
# stderr passes through to the operator's terminal.
OUTPUT="$(
    printf '%s\n' "$OPS_PASS" \
    | ssh "${ssh_args[@]}" "$SSH_TARGET" "$CLUSTER_SCRIPT" "$APPROLE" "$SCOPE"
)"
unset OPS_PASS

ROLE_ID="$(printf '%s\n' "$OUTPUT" | sed -n 's/^ROLE_ID=//p')"
SECRET_ID="$(printf '%s\n' "$OUTPUT" | sed -n 's/^SECRET_ID=//p')"
unset OUTPUT

if [ -z "$ROLE_ID" ] || [ -z "$SECRET_ID" ]; then
    echo "error: cluster script returned no role_id/secret_id" >&2
    exit 4
fi

# Update openbao_secrets.yml in-place
if [ -f "$SECRETS_YML" ]; then
    sed -i '' "s|^openbao_role_id:.*|openbao_role_id: \"${ROLE_ID}\"|" "$SECRETS_YML"
    echo "✓ openbao_role_id updated in $SECRETS_YML" >&2
else
    echo "warn: $SECRETS_YML not found; update openbao_role_id by hand to: $ROLE_ID" >&2
fi

# Update macOS Keychain (replace any prior entry)
security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1 || true
security add-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w "$SECRET_ID"
unset SECRET_ID

echo "✓ keychain updated: service='$KEYCHAIN_SERVICE' account='$KEYCHAIN_ACCOUNT'"
echo "  role_id: $ROLE_ID"
unset ROLE_ID
