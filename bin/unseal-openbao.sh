#!/usr/bin/env bash
# unseal-openbao.sh — strict, scriptable 3-share Shamir unseal of OpenBao.
#
# Threat-model goal: a Shamir share value never appears in
#   - this script's argv
#   - this script's environment
#   - any /tmp file
#   - this script's stdout
#   - the SSH client argv (local or remote)
#   - the curl argv on the control node
#
# The share traverses: function stdin → jq stdin → ssh stdin → curl request body
# (--data-binary @-). It briefly appears in the OpenBao pod's HTTP request
# handling — bounded to our pod in our namespace. We accept this as the same
# exposure as the pre-2026-06-01 approach when shares ran in bao operator
# unseal argv.
#
# Procedure (3-of-5 quorum, the routine break-glass path):
#   share 1 — JuiceFS  <SHARE_DIR>/share-1.json (.key, base64)
#   share 2 — JuiceFS  <SHARE_DIR>/share-2.json (.key, base64)
#   share 3 — Keychain  service=<SHARE_KEYCHAIN_NAME>, account=share (base64)
#
# Shares 4 and 5 (USB OPENBAO_A) are reserved for re-init / rekey disasters and
# are NOT part of the routine unseal path. This script does not touch them.
#
# Usage:
#   bin/unseal-openbao.sh <ENV_NAME>                # interactive 3-share unseal
#   bin/unseal-openbao.sh <ENV_NAME> --status       # read-only seal status (no secrets touched)
#   bin/unseal-openbao.sh <ENV_NAME> --force-rerun  # feed shares even if already unsealed
#   bin/unseal-openbao.sh <ENV_NAME> --yes          # skip the interactive confirm prompt
#
# ENV_NAME is required and maps to the env under ~/.dmfdeploy/envs/<ENV_NAME>/.
# Current live env id lives in the umbrella's STATUS.md. SHARE_DIR,
# SHARE_KEYCHAIN_NAME, SSH_TARGET, and the OpenBao pod IP are derived from the
# env's inventory and cluster state. SSH_TARGET comes from openbao_key_path /
# openbao_keychain_share3_service in group_vars/all/openbao.yml and the first
# [k3s_control] host in hosts.ini; the pod IP is looked up from the cluster.
# Each can be overridden via env:
#   OPENBAO_SSH_TARGET    (default: derived from inventory)
#   OPENBAO_SSH_KEY       (default: derived from inventory)
#   OPENBAO_API_ADDR      (default: https://<pod-ip>:8200)
#   OPENBAO_CACERT        (default: -k insecure; set to a CA file path for strict TLS)
#   OPENBAO_SHARE_DIR     (default: derived from inventory)
#   OPENBAO_KEYCHAIN_SERVICE (default: derived from inventory)
#   OPENBAO_KEYCHAIN_ACCOUNT (default: share)
#
# Examples:
#   bin/unseal-openbao.sh <env-name>
#   bin/unseal-openbao.sh <env-name> --status
#
# Exit codes:
#   0   unsealed (or already was, in default mode)
#   1   bad arg / config
#   2   already unsealed and --force-rerun not set     (callers may treat as success)
#   3   share source missing
#   4   bao/cluster unreachable
#   5   unseal failed mid-stream
#   6   still sealed after feeding 3 shares

set -euo pipefail

# Resolve script + repo dir so this works from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
# shellcheck source=lib/_resolve_env_paths.sh
. "$SCRIPT_DIR/lib/_resolve_env_paths.sh"
dmf_source_operator_config

# ── Inventory parsers ────────────────────────────────────────────────────
# Read a top-level scalar `key: value` from a YAML file. Strips surrounding
# whitespace, inline comments, and one layer of single/double quotes. Does not
# parse nested structures — sufficient for the flat openbao.yml.
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

expand_local_path() {
    case "$1" in
        ~/*) printf '%s/%s' "$HOME" "${1#~/}" ;;
        *) printf '%s' "$1" ;;
    esac
}

# Resolve <user>@<ip> from an Ansible hosts.ini: first non-comment host under
# [k3s_control], then look that hostname up in [k3s] for ansible_host /
# ansible_user. Echoes nothing on failure (caller falls back).
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

INVENTORY_DIR="$DMF_ENV_INVENTORY_DIR"
GROUP_VARS_DIR="$INVENTORY_DIR/group_vars/all"
# openbao.yml is the cloud-layout group_vars filename; sandbox envs keep their
# OpenBao variables inline in main.yml. parse_yaml_scalar tolerates a missing
# file, so falling through to main.yml when openbao.yml is absent gives us
# unified key resolution across both layouts.
OPENBAO_YML="$INVENTORY_DIR/group_vars/all/openbao.yml"
[ -f "$OPENBAO_YML" ] || OPENBAO_YML="$INVENTORY_DIR/group_vars/all/main.yml"
HOSTS_INI="$INVENTORY_DIR/hosts.ini"

# Derive defaults from inventory; env vars override below.
DERIVED_KEY_PATH="$(parse_yaml_scalar "$OPENBAO_YML" openbao_key_path 2>/dev/null || true)"
DERIVED_SHARE_DIR=""
[ -n "$DERIVED_KEY_PATH" ] && DERIVED_SHARE_DIR="$(dirname "$DERIVED_KEY_PATH")"

DERIVED_KEYCHAIN_SVC="$(parse_yaml_scalar "$OPENBAO_YML" openbao_keychain_share3_service 2>/dev/null || true)"
[ -z "$DERIVED_KEYCHAIN_SVC" ] && DERIVED_KEYCHAIN_SVC="openbao-breakglass-share-3"

DERIVED_SSH_TARGET="$(parse_inventory_ssh_target "$HOSTS_INI" 2>/dev/null || true)"
DERIVED_SSH_KEY="$(parse_yaml_scalar_anywhere "$GROUP_VARS_DIR" ansible_ssh_private_key_file 2>/dev/null || true)"
[ -n "$DERIVED_SSH_KEY" ] && DERIVED_SSH_KEY="$(expand_local_path "$DERIVED_SSH_KEY")"

# ── Helpers ──────────────────────────────────────────────────────────────
# Defined before the Configuration block below so the unresolved-SSH_TARGET
# failure path (and any other config-time error) can call `err` safely.
err()      { printf 'error: %s\n' "$*" >&2; }
info()     { printf '  %s\n' "$*"; }
section()  { printf '\n=== %s ===\n' "$*"; }
require()  { command -v "$1" >/dev/null 2>&1 || { err "required command not found: $1"; exit 1; }; }

# ── Configuration (all overridable via env) ──────────────────────────────
SSH_TARGET="${OPENBAO_SSH_TARGET:-${DERIVED_SSH_TARGET:-}}"
if [ -z "$SSH_TARGET" ]; then
    err "SSH target not resolvable for env '${ENV_NAME}'"
    err "set OPENBAO_SSH_TARGET=k3s-admin@<control-node-ip> or"
    err "ensure $HOSTS_INI yields a parseable ansible_host"
    exit 2
fi
SSH_KEY="${OPENBAO_SSH_KEY:-${DERIVED_SSH_KEY:-}}"
OPENBAO_NAMESPACE="${OPENBAO_NAMESPACE:-openbao}"
OPENBAO_POD="${OPENBAO_POD:-openbao-0}"
SHARE_DIR="${OPENBAO_SHARE_DIR:-${DERIVED_SHARE_DIR:-}}"
[ -n "$SHARE_DIR" ] || { err "share dir not resolvable for '${ENV_NAME}' — set OPENBAO_SHARE_DIR or ensure the env inventory sets openbao_key_path"; exit 1; }
SHARE_KEYCHAIN_NAME="${OPENBAO_KEYCHAIN_SERVICE:-$DERIVED_KEYCHAIN_SVC}"
SHARE_KEYCHAIN_ACCT="${OPENBAO_KEYCHAIN_ACCOUNT:-share}"
SHARE_FIELD="${OPENBAO_SHARE_FIELD:-key}"   # JSON field in share-N.json

OPENBAO_API_ADDR="${OPENBAO_API_ADDR:-}"    # Default: https://<pod-ip>:8200 (resolved below)
OPENBAO_CACERT="${OPENBAO_CACERT:-}"        # Default: -k (insecure, pod cert won't match IP)
ssh_opts=(-o LogLevel=ERROR)
[ -n "$SSH_KEY" ] && ssh_opts+=(-i "$SSH_KEY")
curl_opts=(-sS)
if [ -n "$OPENBAO_CACERT" ]; then
    curl_opts+=(--cacert "$OPENBAO_CACERT")
else
    curl_opts+=(-k)
fi

# Track whether user explicitly set OPENBAO_API_ADDR (vs auto-resolve)
OPENBAO_API_ADDR_USER_SET=0
[ -n "${OPENBAO_API_ADDR}" ] && OPENBAO_API_ADDR_USER_SET=1

remote_bao_status_json() {
    # `bao status` exits 0 unsealed / 2 sealed / 1 error. We don't trust exit
    # codes; we parse JSON. Stderr is suppressed because bao writes a deprecation
    # banner there that would muddy the JSON.
    ssh "${ssh_opts[@]}" "$SSH_TARGET" \
        sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
        -n "$OPENBAO_NAMESPACE" exec "$OPENBAO_POD" -- \
        bao status -format=json 2>/dev/null || true
}

is_sealed() {
    local json
    json="$(remote_bao_status_json)"
    [ -n "$json" ] || return 2
    [ "$(printf '%s' "$json" | jq -r '.sealed // "unknown"')" = "true" ]
}

resolve_openbao_pod_ip() {
    ssh "${ssh_opts[@]}" "$SSH_TARGET" \
        sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
        -n "$OPENBAO_NAMESPACE" get pod "$OPENBAO_POD" \
        -o jsonpath='{.status.podIP}' 2>/dev/null || true
}

# Feed one share into OpenBao via the HTTP /v1/sys/unseal endpoint.
# stdin of THIS function = the share value (one line, no trailing newline).
# The share traverses: function stdin → jq stdin → ssh stdin → curl request body.
# It never lands in argv on the local Mac, SSH wire, or control node.
#
# UNTESTED against a live cluster (none exists as of 2026-06-01); validate
# node→podIP:8200 reachability + TLS on the next env build.
feed_share_via_stdin() {
    local label="$1"
    local pod_ip="$2"
    # Prefer explicit OPENBAO_API_ADDR override; only auto-construct from pod_ip if not set
    local api_addr="${OPENBAO_API_ADDR:-https://${pod_ip}:8200}"
    local status sealed progress

    # jq -R reads the line without trailing newline, emits {"key":"<share>"}.
    # The share stays in stdin the whole way: function stdin → jq → ssh → curl.
    status="$(
        jq -R '{key: .}' | \
        ssh "${ssh_opts[@]}" "$SSH_TARGET" \
            curl "${curl_opts[@]}" --data-binary @- "$api_addr/v1/sys/unseal"
    )" || {
        err "$label: ssh/curl failed"
        return 5
    }

    sealed="$(printf '%s' "$status" | jq -r 'if has("sealed") then (.sealed|tostring) else "?" end' 2>/dev/null || echo "?")"
    progress="$(printf '%s' "$status" | jq -r '.progress // "?"' 2>/dev/null || echo "?")"

    if [ "$sealed" = "?" ]; then
        err "$label: could not parse OpenBao response (pod API responding?)"
        printf '%s\n' "$status" >&2
        return 5
    fi

    info "$label fed → sealed=$sealed progress=$progress"
}

# ── Argument parsing ─────────────────────────────────────────────────────
MODE="unseal"
FORCE_RERUN=0
SKIP_CONFIRM=0
for arg in "$@"; do
    case "$arg" in
        --status)        MODE="status" ;;
        --force-rerun)   FORCE_RERUN=1 ;;
        --yes|-y)        SKIP_CONFIRM=1 ;;
        -h|--help)
            sed -n '/^# unseal/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            err "unknown arg: $arg (try --help)"
            exit 1
            ;;
    esac
done

# ── Local prerequisites ──────────────────────────────────────────────────
require ssh
require jq

# ── Sandbox posture detection ───────────────────────────────────────────
# Sandbox uses Shamir 1/1 self-unseal — no Keychain share-3 needed.
# OPENBAO_PROFILE env (explicit override) is highest precedence.
# Otherwise parse from inventory group_vars (OPENBAO_YML): dmf_provider first,
# then dmf_release_profile as fallback.
OPENBAO_PROFILE="${OPENBAO_PROFILE:-}"
IS_SANDBOX=0
if [ -z "$OPENBAO_PROFILE" ]; then
    OPENBAO_PROFILE="$(parse_yaml_scalar "$OPENBAO_YML" dmf_provider 2>/dev/null || true)"
fi
if [ -z "$OPENBAO_PROFILE" ]; then
    OPENBAO_PROFILE="$(parse_yaml_scalar "$OPENBAO_YML" dmf_release_profile 2>/dev/null || true)"
fi
case "${OPENBAO_PROFILE:-}" in
    sandbox|sandbox-*) IS_SANDBOX=1 ;;
esac

# Unseal-key source: split share files (share-1/2.json — the 3-of-5 break-glass
# layout) OR the single openbao-keys.json that `bao operator init` writes
# (.unseal_keys_hex[]). Prefer split files. The openbao-keys.json fallback is a
# SANDBOX construct (1/1 self-unseal) and is gated on sandbox posture: a
# non-sandbox env missing its split shares must FAIL CLOSED at pre-flight, never
# silently bypass the 3-of-5 + Keychain quorum by reading raw init keys (#130).
# Resolved here (after posture is known); validated in pre-flight.
KEYS_JSON="${OPENBAO_KEYS_JSON:-$SHARE_DIR/openbao-keys.json}"
SHARE_SOURCE=""
if [ -r "$SHARE_DIR/share-1.json" ]; then
    SHARE_SOURCE="share-files"
elif [ "$IS_SANDBOX" -eq 1 ] && [ -r "$KEYS_JSON" ] && jq -e '(.unseal_keys_hex // empty) | type=="array" and length>0' "$KEYS_JSON" >/dev/null 2>&1; then
    SHARE_SOURCE="keys-json"
fi

# macOS Keychain CLI is only needed for non-sandbox (3-of-5 Shamir) profiles.
if [ "$IS_SANDBOX" -ne 1 ]; then
    require security    # macOS Keychain CLI
fi

# ── Resolve pod IP and build TLS options (unseal mode only) ───────────────
if [ "$MODE" != "status" ]; then
    if [ -z "$OPENBAO_API_ADDR" ]; then
        POD_IP="$(resolve_openbao_pod_ip)"
        if [ -z "$POD_IP" ]; then
            err "could not resolve OpenBao pod IP (cluster unreachable or pod not scheduled)"
            exit 4
        fi
        OPENBAO_API_ADDR="https://${POD_IP}:8200"
    fi
fi

# ── Resolved environment ─────────────────────────────────────────────────
section "Environment: $ENV_NAME"
info "ssh target:   $SSH_TARGET"
[ -n "$OPENBAO_API_ADDR" ] && info "pod API addr: $OPENBAO_API_ADDR"
info "share dir:    $SHARE_DIR"
info "keychain svc: $SHARE_KEYCHAIN_NAME"

# ── Status mode ──────────────────────────────────────────────────────────
if [ "$MODE" = "status" ]; then
    section "OpenBao seal status"
    json="$(remote_bao_status_json)"
    if [ -z "$json" ]; then
        err "could not reach $OPENBAO_POD in $OPENBAO_NAMESPACE on $SSH_TARGET"
        exit 4
    fi
    printf '%s' "$json" | jq '{sealed, version, t, n, progress, ha_enabled, cluster_name}'
    if [ "$(printf '%s' "$json" | jq -r '.sealed')" = "false" ]; then
        info "(unsealed)"
    else
        info "(sealed)"
    fi
    exit 0
fi

# ── Pre-flight ───────────────────────────────────────────────────────────
section "Pre-flight"

# 1. Reachability
info "checking cluster reachability..."
if [ -z "$(remote_bao_status_json)" ]; then
    err "cannot reach $OPENBAO_POD in $OPENBAO_NAMESPACE on $SSH_TARGET"
    err "  - is the cluster up?    ssh $SSH_TARGET 'sudo kubectl get nodes'"
    err "  - is the pod scheduled? ssh $SSH_TARGET 'sudo kubectl get pod -n $OPENBAO_NAMESPACE'"
    exit 4
fi
info "  ok"

# 2. Already unsealed?
info "current seal state..."
if ! is_sealed; then
    if [ "$FORCE_RERUN" -eq 0 ]; then
        info "  already unsealed — nothing to do"
        info "  (use --force-rerun to re-feed shares anyway)"
        exit 2
    fi
    info "  already unsealed but --force-rerun set; proceeding"
else
    info "  sealed (proceeding)"
fi

# 3. Unseal-key source reachable + valid
info "checking unseal-key source..."
case "$SHARE_SOURCE" in
  share-files)
    [ -r "$SHARE_DIR/share-2.json" ] || { err "share 1 present but share 2 missing or unreadable: $SHARE_DIR/share-2.json"; exit 3; }
    for n in 1 2; do
      if ! jq -e --arg f "$SHARE_FIELD" 'has($f)' "$SHARE_DIR/share-$n.json" >/dev/null 2>&1; then
        err "share $n at $SHARE_DIR/share-$n.json has no field '.$SHARE_FIELD'"
        err "  set OPENBAO_SHARE_FIELD env var if the JSON layout differs"
        exit 3
      fi
    done
    if [ "$IS_SANDBOX" -eq 1 ]; then
      info "  split share files present (sandbox posture — no Keychain share-3)"
    else
      if ! security find-generic-password -s "$SHARE_KEYCHAIN_NAME" -a "$SHARE_KEYCHAIN_ACCT" >/dev/null 2>&1; then
        err "share 3 missing in Keychain: service='$SHARE_KEYCHAIN_NAME' account='$SHARE_KEYCHAIN_ACCT'"
        err "  - has share 3 ever been seeded? See openbao role tasks/main.yml"
        err "  - is the login keychain unlocked?"
        exit 3
      fi
      info "  all 3 sources present"
    fi
    ;;
  keys-json)
    info "  using openbao-keys.json (.unseal_keys_hex) — no split share files present"
    ;;
  *)
    err "no unseal-key source found in $SHARE_DIR"
    err "  expected one of:"
    err "    - share-1.json + share-2.json (field '.$SHARE_FIELD')   [3-of-5 break-glass layout]"
    err "    - openbao-keys.json (.unseal_keys_hex[])                [freshly-initialized sandbox]"
    exit 3
    ;;
esac
info "  ok"

# ── Confirm ──────────────────────────────────────────────────────────────
if [ "$IS_SANDBOX" -eq 1 ]; then
    section "Unseal procedure (sandbox 1/1 self-unseal)"
    cat <<EOF
  source:    $([ "$SHARE_SOURCE" = keys-json ] && echo "$KEYS_JSON (.unseal_keys_hex)" || echo "$SHARE_DIR/share-1.json + share-2.json (.${SHARE_FIELD})")
             (sandbox posture — no Keychain share-3 required)
  target:    $OPENBAO_API_ADDR (pod=$OPENBAO_POD ns=$OPENBAO_NAMESPACE)
  transport: ssh to $SSH_TARGET, curl to pod IP:8200 (node-local, not ingress-exposed)
EOF
else
    section "Unseal procedure (3-of-5 Shamir)"
    cat <<EOF
  source 1:  $SHARE_DIR/share-1.json (JuiceFS, .${SHARE_FIELD})
  source 2:  $SHARE_DIR/share-2.json (JuiceFS, .${SHARE_FIELD})
  source 3:  Keychain service='$SHARE_KEYCHAIN_NAME' account='$SHARE_KEYCHAIN_ACCT' (will prompt to unlock)
  target:    $OPENBAO_API_ADDR (pod=$OPENBAO_POD ns=$OPENBAO_NAMESPACE)
  transport: ssh to $SSH_TARGET, curl to pod IP:8200 (node-local, not ingress-exposed)

Each share is piped via stdin through jq and ssh into curl's request body
(--data-binary @-). The share value never appears in this script's argv,
environment, /tmp, stdout, SSH argv, or curl argv.
EOF
fi
echo ""

if [ "$SKIP_CONFIRM" -eq 0 ]; then
    if ! [ -t 0 ]; then
        err "stdin is not a TTY — pass --yes to skip the confirm prompt"
        exit 1
    fi
    read -r -p "Proceed? [y/N] " ans
    case "$ans" in
        y|Y|yes|YES) ;;
        *) info "aborted"; exit 0 ;;
    esac
fi

# ── Node-side precheck: curl availability ────────────────────────────────
section "Node-side precheck"
info "checking curl on control node..."
if ! ssh "${ssh_opts[@]}" "$SSH_TARGET" command -v curl >/dev/null 2>&1; then
    err "curl not found on control node $SSH_TARGET"
    err "  The new unseal path requires curl on the node (pod-IP:8200 access)"
    err "  Install it and retry, or use the legacy kubectl-exec path"
    exit 4
fi
info "  curl available on control node"

# ── Feed shares ──────────────────────────────────────────────────────────
section "Feeding shares"

if [ "$SHARE_SOURCE" = "keys-json" ]; then
    # Sandbox / raw-init layout: feed the first t unseal keys from
    # openbao-keys.json (t = live threshold; 1 for a 1/1 sandbox). Same pipe as
    # the share-file path: jq stdout -> feed_share_via_stdin stdin -> ssh -> curl.
    # The key value never enters argv, env, /tmp, or stdout.
    t="$(remote_bao_status_json | jq -r '.t // 1')"
    case "$t" in ''|*[!0-9]*) t=1 ;; esac
    nkeys="$(jq -r '.unseal_keys_hex | length' "$KEYS_JSON")"
    [ "$t" -le "$nkeys" ] || { err "threshold t=$t exceeds available keys ($nkeys) in $KEYS_JSON"; exit 3; }
    i=0
    while [ "$i" -lt "$t" ]; do
        if [ "$OPENBAO_API_ADDR_USER_SET" -ne 1 ]; then
            POD_IP="$(resolve_openbao_pod_ip)"
            [ -n "$POD_IP" ] || { err "could not resolve OpenBao pod IP before key $((i+1))"; exit 4; }
        else
            POD_IP=""
        fi
        jq -r --argjson i "$i" '.unseal_keys_hex[$i]' "$KEYS_JSON" \
            | feed_share_via_stdin "key $((i+1))/$t (openbao-keys.json)" "$POD_IP"
        i=$((i+1))
    done
else

# share 1 — resolve pod IP (only if not user-overridden), then feed
if [ "$OPENBAO_API_ADDR_USER_SET" -ne 1 ]; then
    POD_IP="$(resolve_openbao_pod_ip)"
    if [ -z "$POD_IP" ]; then
        err "could not resolve OpenBao pod IP before feeding share 1"
        exit 4
    fi
    info "resolved pod IP: $POD_IP"
else
    POD_IP=""
    info "using explicit OPENBAO_API_ADDR override"
fi
jq -r --arg f "$SHARE_FIELD" '.[$f]' "$SHARE_DIR/share-1.json" \
    | feed_share_via_stdin "share 1 (JuiceFS)" "$POD_IP"

# share 2 — re-resolve pod IP (only if not user-overridden; pod could reschedule between shares)
if [ "$OPENBAO_API_ADDR_USER_SET" -ne 1 ]; then
    POD_IP="$(resolve_openbao_pod_ip)"
    if [ -z "$POD_IP" ]; then
        err "could not resolve OpenBao pod IP before feeding share 2"
        exit 4
    fi
else
    POD_IP=""
fi
jq -r --arg f "$SHARE_FIELD" '.[$f]' "$SHARE_DIR/share-2.json" \
    | feed_share_via_stdin "share 2 (JuiceFS)" "$POD_IP"

# share 3 — Keychain (non-sandbox only; sandbox is 1/1 self-unseal with shares 1+2)
if [ "$IS_SANDBOX" -eq 1 ]; then
    info "sandbox posture — skipping share 3 (1/1 self-unseal, shares 1+2 sufficient)"
else
    if [ "$OPENBAO_API_ADDR_USER_SET" -ne 1 ]; then
        POD_IP="$(resolve_openbao_pod_ip)"
        if [ -z "$POD_IP" ]; then
            err "could not resolve OpenBao pod IP before feeding share 3"
            exit 4
        fi
    else
        POD_IP=""
    fi
    security find-generic-password -s "$SHARE_KEYCHAIN_NAME" -a "$SHARE_KEYCHAIN_ACCT" -w \
        | feed_share_via_stdin "share 3 (Keychain)" "$POD_IP"
fi

fi  # close the share-source if/else

# ── Verify ───────────────────────────────────────────────────────────────
section "Verification"
if is_sealed; then
    err "still sealed after feeding 3 shares — investigate"
    remote_bao_status_json | jq '{sealed, t, n, progress}' >&2
    exit 6
fi

remote_bao_status_json | jq '{sealed, version, cluster_id, cluster_name, ha_enabled}'
section "Done — unsealed"
exit 0
