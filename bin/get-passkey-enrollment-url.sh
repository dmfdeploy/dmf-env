#!/usr/bin/env bash
# get-passkey-enrollment-url.sh — retrieve the DMF passkey enrollment URL and
# the operator's confirmed-passkey count.
#
# The enrollment URL is sourced from the OpenBao cache (written by the
# Authentik role). The confirmed-passkey COUNT and the cached invitation's
# liveness are both read LIVE from Authentik. When the cached invitation is
# gone from the live DB (expired, revoked, or wiped) and the
# passkey requirement is not yet met, the script self-heals by invoking the
# sanctioned mini-playbook `111-authentik-passkey-ensure.yml` through
# `bin/run-playbook.sh` (ADR-0010) — minting a fresh invitation and refreshing
# the cache — then re-reads the URL. Pass `--read-only` to skip self-heal.
#
# Usage:
#   bin/get-passkey-enrollment-url.sh [--read-only] ENV_NAME
#
# ENV_NAME is a known env id, resolved via bin/lib/_resolve_env_paths.sh
# (operator-local envs under ~/.dmfdeploy/envs/<env-id>/).
# $OPENBAO_BREAKGLASS_FILE, $OPENBAO_SSH_TARGET,
# and the SSH key are derived from the env inventory (matching get-admin-cred.sh
# pattern); each can be overridden by the corresponding env var. $DMF_INFRA_REPO
# overrides the sibling-checkout default (../dmf-infra) used to resolve the
# mini-playbook.
#
# Examples:
#   bin/get-passkey-enrollment-url.sh <env-id>
#   bin/get-passkey-enrollment-url.sh --read-only <env-id>
#
# Output:
#   Prints the enrollment URL, confirmed passkey count, and expiration to stdout.
#   Returns non-zero if the URL is empty after a self-heal attempt or if
#   OpenBao / Authentik are unreachable.
#
# ADR-0028 D8 gate:
#   The script suppresses the URL once the LIVE confirmed-passkey count meets
#   the required count (`required_webauthn_count` from the cached secret;
#   default 2, the floor enforced by the Authentik role's
#   `authentik_bootstrap_passkey_min_confirmed_devices`). Self-heal is
#   skipped in that case (no URL needed).
#
# Prerequisites:
#   - OpenBao operator userpass credentials in the break-glass file.
#   - SSH access to the cluster node (derived from inventory or $OPENBAO_SSH_TARGET).
#   - OpenBao pod in $OPENBAO_NAMESPACE (default: openbao) + Authentik server
#     deploy in $AUTHENTIK_NAMESPACE (default: authentik).
#   - For self-heal: ../dmf-infra checkout (or $DMF_INFRA_REPO) reachable from
#     this repo, with playbooks/vertical-security/111-authentik-passkey-ensure.yml.

set -euo pipefail

# Resolve script + repo dir so this works from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck source=lib/_resolve_env_paths.sh
. "$SCRIPT_DIR/lib/_resolve_env_paths.sh"
dmf_source_operator_config

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

# ── Argument parsing — ENV_NAME is required ───────────────────────────────
READ_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --read-only) READ_ONLY=1; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
            exit 0 ;;
        --) shift; break ;;
        -*)
            echo "error: unknown flag: $1" >&2
            exit 2 ;;
        *) break ;;
    esac
done
if [ $# -lt 1 ]; then
    echo "usage: $(basename "$0") [--read-only] <env-id>" >&2
    echo "       <env-id> is a known env (~/.dmfdeploy/envs/<env-id>/); current id is in the umbrella STATUS.md." >&2
    echo "       available: $(dmf_list_known_envs | tr '\n' ' ')" >&2
    exit 2
fi
ENV_NAME="$1"
shift

# Resolve env paths (~/.dmfdeploy/envs/<env>/). Placeholders are set on miss;
# the not-found guard below surfaces it.
dmf_resolve_env_paths "$ENV_NAME" || true
INVENTORY_DIR="$DMF_ENV_INVENTORY_DIR"
GROUP_VARS_DIR="$INVENTORY_DIR/group_vars/all"
HOSTS_INI="$INVENTORY_DIR/hosts.ini"

if [ ! -d "$INVENTORY_DIR" ]; then
    echo "error: inventory directory not found: $INVENTORY_DIR" >&2
    exit 2
fi
if [ ! -r "$HOSTS_INI" ]; then
    echo "error: hosts.ini not readable in $INVENTORY_DIR" >&2
    echo "       (retired inventories missing hosts.ini are not supported)" >&2
    exit 2
fi

# Derive defaults from inventory; env vars override below.
DERIVED_KEY_PATH="$(parse_yaml_scalar_anywhere "$GROUP_VARS_DIR" openbao_key_path 2>/dev/null || true)"
DERIVED_BREAKGLASS=""
[ -n "$DERIVED_KEY_PATH" ] && DERIVED_BREAKGLASS="$(expand_local_path "${DERIVED_KEY_PATH}").json"

DERIVED_SSH_TARGET="$(parse_inventory_ssh_target "$HOSTS_INI" 2>/dev/null || true)"

DERIVED_SSH_KEY="$(parse_yaml_scalar_anywhere "$GROUP_VARS_DIR" ansible_ssh_private_key_file 2>/dev/null || true)"
[ -n "$DERIVED_SSH_KEY" ] && DERIVED_SSH_KEY="$(expand_local_path "$DERIVED_SSH_KEY")"

# ── Configuration (env vars override inventory-derived values) ────────────
BREAKGLASS_FILE="${OPENBAO_BREAKGLASS_FILE:-${DERIVED_BREAKGLASS:-}}"
SSH_TARGET="${OPENBAO_SSH_TARGET:-${DERIVED_SSH_TARGET:-}}"
SSH_KEY="${OPENBAO_SSH_KEY:-${DERIVED_SSH_KEY:-}}"
OPENBAO_NAMESPACE="${OPENBAO_NAMESPACE:-openbao}"
OPENBAO_POD="${OPENBAO_POD:-openbao-0}"
SECRET_PATH="secret/apps/authentik/bootstrap-passkey"
# Authentik (for the LIVE confirmed-passkey count — see below).
AUTHENTIK_NAMESPACE="${AUTHENTIK_NAMESPACE:-authentik}"
AUTHENTIK_RELEASE="${AUTHENTIK_RELEASE:-authentik}"

if [ -z "$BREAKGLASS_FILE" ]; then
    echo "error: could not derive break-glass file from $GROUP_VARS_DIR (no openbao_key_path)" >&2
    echo "       set OPENBAO_BREAKGLASS_FILE to override" >&2
    exit 2
fi
if [ -z "$SSH_TARGET" ]; then
    echo "error: could not derive SSH target from $HOSTS_INI" >&2
    echo "       set OPENBAO_SSH_TARGET to override (user@host)" >&2
    exit 2
fi

if [ ! -r "$BREAKGLASS_FILE" ]; then
  echo "error: break-glass file not readable: $BREAKGLASS_FILE" >&2
  echo "       run the openbao playbook to seed the operator userpass path" >&2
  exit 2
fi

USERNAME="$(jq -re '.ops_admin_username' "$BREAKGLASS_FILE" 2>/dev/null || true)"
PASSWORD="$(jq -re '.ops_admin_password' "$BREAKGLASS_FILE" 2>/dev/null || true)"

if [ -z "${USERNAME}" ] || [ -z "${PASSWORD}" ]; then
  echo "error: ops_admin_username / ops_admin_password missing from $BREAKGLASS_FILE" >&2
  exit 3
fi

# Pre-flight info to stderr
{
    echo "env:           $ENV_NAME"
    echo "ssh target:    $SSH_TARGET"
    echo "breakglass:    $BREAKGLASS_FILE"
} >&2

# Build SSH args with optional key
ssh_args=(-o LogLevel=ERROR)
[ -n "$SSH_KEY" ] && ssh_args+=(-i "$SSH_KEY")

RESULT="$(ssh "${ssh_args[@]}" "$SSH_TARGET" \
  sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
    -n "$OPENBAO_NAMESPACE" exec -i "$OPENBAO_POD" -- sh <<EOF
set -e
TOKEN=\$(bao login -no-store -format=json -method=userpass \
  username='${USERNAME}' password='${PASSWORD}' 2>/dev/null \
  | sed -n 's/.*"client_token"[ ]*:[ ]*"\([^"]*\)".*/\1/p')
[ -n "\$TOKEN" ] || { echo "userpass login produced no token" >&2; exit 4; }
BAO_TOKEN=\$TOKEN bao kv get -format=json '${SECRET_PATH}'
EOF
)"

# Stable values from the cached bootstrap-passkey secret (set by the Authentik
# role; the username/required-count/URL don't change between role runs).
URL="$(echo "$RESULT" | jq -re '.data.data.enrollment_url // empty')"
EXPIRES="$(echo "$RESULT" | jq -re '.data.data.expires // empty')"
USERNAME_CACHED="$(echo "$RESULT" | jq -re '.data.data.username // empty')"
REQUIRED_WEBAUTHN_COUNT="$(echo "$RESULT" | jq -re '.data.data.required_webauthn_count // 2')"

if [ -z "$USERNAME_CACHED" ]; then
  echo "error: no operator username at ${SECRET_PATH}" >&2
  echo "       run vertical-security/110-authentik.yml once to seed it" >&2
  exit 1
fi

# Extract the invitation token from the cached URL so we can check liveness
# against Authentik DB in the same round-trip as the webauthn-count query.
# UUID format is 8-4-4-4-12 hex with dashes; empty if URL is unset.
ITOKEN="$(printf '%s' "$URL" | sed -n 's/.*itoken=\([0-9a-fA-F][0-9a-fA-F-]*\).*/\1/p')"

# LIVE Authentik read (the source of truth):
#   - confirmed-passkey COUNT (the cached webauthn_count goes stale the moment
#     a device is enrolled);
#   - whether the cached invitation `itoken` is still present in the DB
#     (invitations are reusable within TTL; expired/revoked ones are
#     pruned — either way the cached URL is no longer usable).
# Read-only: queries only. Mutation happens in the self-heal path below, which
# delegates to the sanctioned mini-playbook.
# shellcheck disable=SC2087  # ${USERNAME_CACHED} / ${ITOKEN} are baked into
# the python client-side on purpose (same pattern as the OpenBao read above);
# both come from controlled OpenBao state, not arbitrary input.
LIVE_PROBE_RAW="$(ssh "${ssh_args[@]}" "$SSH_TARGET" \
  sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
    -n "$AUTHENTIK_NAMESPACE" exec -i "deploy/${AUTHENTIK_RELEASE}-server" -- ak shell 2>/dev/null <<PYEOF
from authentik.core.models import User
from authentik.stages.authenticator_webauthn.models import WebAuthnDevice
from authentik.stages.invitation.models import Invitation
u = User.objects.filter(username="${USERNAME_CACHED}").first()
devices = list(WebAuthnDevice.objects.filter(user=u, confirmed=True).values_list("name", "aaguid")) if u else []
print("WEBAUTHN_COUNT=" + str(len(devices) if u else -1))
itoken = "${ITOKEN}"
print("INVITATION_LIVE=" + ("true" if itoken and Invitation.objects.filter(invite_uuid=itoken).exists() else "false"))
# Per-device line for diversity hints (ADR-0028 D8). Separator is '|'
# because device names may contain spaces but never a literal pipe in
# practice; aaguid is a UUID.
for name, aaguid in devices:
    print("DEVICE: " + (name or "(unnamed)") + "|" + str(aaguid or ""))
PYEOF
)"
WEBAUTHN_COUNT="$(printf '%s\n' "$LIVE_PROBE_RAW" | sed -nE 's/^WEBAUTHN_COUNT=(-?[0-9]+)$/\1/p' | tail -1)"
INVITATION_LIVE="$(printf '%s\n' "$LIVE_PROBE_RAW" | sed -nE 's/^INVITATION_LIVE=(true|false)$/\1/p' | tail -1)"
# Newline-separated list of "name|aaguid" for each confirmed device.
DEVICES_RAW="$(printf '%s\n' "$LIVE_PROBE_RAW" | sed -nE 's/^DEVICE: (.*)$/\1/p')"

# Resolve a Console URL for the second-passkey hint (R2). Falls back to
# console.<base-domain> if dmf_cms_host isn't explicit in inventory.
CONSOLE_HOST="$(parse_yaml_scalar_anywhere "$GROUP_VARS_DIR" dmf_cms_host 2>/dev/null || true)"
if [ -z "$CONSOLE_HOST" ]; then
    _base_dom="$(parse_yaml_scalar_anywhere "$GROUP_VARS_DIR" dmf_sandbox_base_domain 2>/dev/null || true)"
    [ -z "$_base_dom" ] && _base_dom="$(parse_yaml_scalar_anywhere "$GROUP_VARS_DIR" cert_manager_cluster_domain 2>/dev/null || true)"
    [ -n "$_base_dom" ] && CONSOLE_HOST="console.${_base_dom}"
fi
CONSOLE_URL=""
[ -n "$CONSOLE_HOST" ] && CONSOLE_URL="https://${CONSOLE_HOST}/"

# Render confirmed-device list to stdout. Called from the print path.
render_existing_devices() {
    if [ -z "$DEVICES_RAW" ]; then
        return
    fi
    echo "existing devices:"
    while IFS='|' read -r _name _aaguid; do
        if [ -n "$_aaguid" ]; then
            echo "  - $_name (aaguid=$_aaguid)"
        else
            echo "  - $_name"
        fi
    done <<EOF_DEVICES
$DEVICES_RAW
EOF_DEVICES
}

if [ -z "$WEBAUTHN_COUNT" ]; then
  echo "error: could not read live passkey count from Authentik (deploy/${AUTHENTIK_RELEASE}-server in ns ${AUTHENTIK_NAMESPACE})" >&2
  exit 4
fi
if [ "$WEBAUTHN_COUNT" -lt 0 ]; then
  echo "error: operator user '${USERNAME_CACHED}' not found in Authentik" >&2
  echo "       run vertical-security/110-authentik.yml to seed it" >&2
  exit 1
fi

if [ "$WEBAUTHN_COUNT" -ge "$REQUIRED_WEBAUTHN_COUNT" ]; then
  echo "passkey requirement met for user: ${USERNAME_CACHED}"
  echo "confirmed passkeys: ${WEBAUTHN_COUNT}/${REQUIRED_WEBAUTHN_COUNT} (ADR-0028 D8, live)"
  render_existing_devices
  echo "no new enrollment URL needed"
  exit 0
fi

# ── Self-heal: cached URL doesn't match a live invitation ──────────────────
# Delegate mint + cache-refresh to the sanctioned mini-playbook (ADR-0010),
# then re-read the freshly-written cache so the URL we print is the live one.
# Skipped in --read-only mode (operator may want to inspect cache without
# triggering side effects).
FRESHLY_MINTED=0
if [ -z "${URL}" ] || [ "${INVITATION_LIVE}" != "true" ]; then
  if [ "$READ_ONLY" -eq 1 ]; then
    if [ -z "${URL}" ]; then
      echo "error: no enrollment URL cached at ${SECRET_PATH} and --read-only blocks self-heal" >&2
    else
      echo "error: cached invitation is not live in Authentik (--read-only blocks self-heal)" >&2
      echo "       cached itoken: ${ITOKEN}" >&2
    fi
    exit 1
  fi

  DMF_INFRA_REPO="${DMF_INFRA_REPO:-${REPO_DIR}/../dmf-infra}"
  ENSURE_PLAYBOOK="${DMF_INFRA_REPO}/k3s-lab-bootstrap/playbooks/vertical-security/111-authentik-passkey-ensure.yml"
  RUN_PLAYBOOK="${REPO_DIR}/bin/run-playbook.sh"

  if [ ! -r "$ENSURE_PLAYBOOK" ]; then
    echo "error: self-heal playbook not found: $ENSURE_PLAYBOOK" >&2
    echo "       set DMF_INFRA_REPO to override the sibling-checkout default" >&2
    exit 4
  fi
  if [ ! -x "$RUN_PLAYBOOK" ]; then
    echo "error: sanctioned wrapper not found or not executable: $RUN_PLAYBOOK" >&2
    exit 4
  fi

  echo "no live invitation in Authentik — minting fresh via ${ENSURE_PLAYBOOK##*/} (ADR-0010 wrapper)…" >&2
  RUNBOOK_TIMEOUT="${RUNBOOK_TIMEOUT:-300}" "$RUN_PLAYBOOK" "$ENV_NAME" "$ENSURE_PLAYBOOK" >&2

  # Re-read the freshly-written cache.
  RESULT="$(ssh "${ssh_args[@]}" "$SSH_TARGET" \
    sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
      -n "$OPENBAO_NAMESPACE" exec -i "$OPENBAO_POD" -- sh <<EOF
set -e
TOKEN=\$(bao login -no-store -format=json -method=userpass \
  username='${USERNAME}' password='${PASSWORD}' 2>/dev/null \
  | sed -n 's/.*"client_token"[ ]*:[ ]*"\([^"]*\)".*/\1/p')
[ -n "\$TOKEN" ] || { echo "userpass login produced no token" >&2; exit 4; }
BAO_TOKEN=\$TOKEN bao kv get -format=json '${SECRET_PATH}'
EOF
)"
  URL="$(echo "$RESULT" | jq -re '.data.data.enrollment_url // empty')"
  EXPIRES="$(echo "$RESULT" | jq -re '.data.data.expires // empty')"
  FRESHLY_MINTED=1
fi

if [ -z "${URL}" ]; then
  echo "error: enrollment URL still empty after self-heal at ${SECRET_PATH}" >&2
  exit 1
fi

# Print path branches on whether this is the first passkey (count=0) or an
# additional one (0 < count < required). For additional passkeys, ADR-0015
# steers to the DMF Console self-service flow (Settings → "Create new device
# invitation"), and ADR-0028 D8 requires a DIFFERENT authenticator than the
# ones already registered (WebAuthn excludeCredentials enforces this on the
# authenticator side too). See docs/runbooks/passkey-enrollment.md.
echo "confirmed passkeys: ${WEBAUTHN_COUNT}/${REQUIRED_WEBAUTHN_COUNT} (ADR-0028 D8, live)"
render_existing_devices
echo ""
if [ "$WEBAUTHN_COUNT" -eq 0 ]; then
  echo "enrollment_url: ${URL}"
  [ -n "${EXPIRES}" ] && echo "expires:        ${EXPIRES}"
  [ "$FRESHLY_MINTED" -eq 1 ] && echo "source:         freshly minted (cached invitation was missing in live Authentik)"
  echo ""
  echo "First-passkey hint: open the URL in a private/incognito window,"
  echo "pick AUTHENTICATOR A (e.g. iCloud Keychain or your platform's"
  echo "native passkey store). The second passkey will come from the DMF"
  echo "Console after you've signed in with this one."
else
  echo "Next passkey: prefer the DMF Console self-service flow"
  echo "(ADR-0015 — sign in with your existing passkey, then go to"
  echo "Settings → \"Create new device invitation\")."
  if [ -n "$CONSOLE_URL" ]; then
    echo "  ${CONSOLE_URL}"
  fi
  echo ""
  echo "⚠️  Use a DIFFERENT authenticator than the one(s) listed above."
  echo "    WebAuthn excludeCredentials prevents the same authenticator"
  echo "    family from registering a second credential for this user —"
  echo "    the ceremony will silently abort. Hardware key, a different"
  echo "    device, or a different browser-native store all work."
  echo "    See docs/runbooks/passkey-enrollment.md (in the umbrella)."
  echo ""
  echo "Bootstrap URL (also valid; use only with a fresh authenticator):"
  echo "  ${URL}"
  [ -n "${EXPIRES}" ] && echo "  expires: ${EXPIRES}"
  [ "$FRESHLY_MINTED" -eq 1 ] && echo "  source:  freshly minted (cached invitation was missing in live Authentik)"
fi
# The invitation is reusable within its TTL; re-running this script after a
# failed WebAuthn attempt will reuse the same URL until a passkey is confirmed
# or the TTL expires. Self-heal re-mints only after expiry/revocation.
