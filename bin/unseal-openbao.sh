#!/usr/bin/env bash
# unseal-openbao.sh — strict, scriptable 3-share Shamir unseal of OpenBao.
#
# Threat-model goal: a Shamir share value never appears in
#   - this script's argv
#   - this script's environment
#   - any /tmp file
#   - this script's stdout
#   - the SSH client argv (local or remote)
#   - the kubectl or bao argv on the control node or in the pod
#
# The share traverses: function stdin → jq stdin → ssh stdin → kubectl exec -i
# stdin → `bao write sys/unseal -` stdin inside the OpenBao pod → the request
# body bao sends to the pod's own listener. The kubectl exec stream runs over
# the Kubernetes API server and kubelet connections, which are TLS; neither
# logs stream content.
#
# TLS: every OpenBao call runs `bao` inside the pod, where the pod spec sets
# BAO_ADDR=https://127.0.0.1:8200 and BAO_CACERT to the certificate the pod
# serves (issued for 127.0.0.1). bao verifies that certificate. The wrapper
# clears any *_SKIP_VERIFY variable for each call and has no path that skips
# verification. A TLS failure stops the run with exit 7 and says what to check.
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
# Current live env id lives in the umbrella's STATUS.digest.local.md, which bin/generate-status.sh writes. SHARE_DIR,
# SHARE_KEYCHAIN_NAME, and SSH_TARGET are derived from the env's inventory.
# SSH_TARGET comes from openbao_key_path / openbao_keychain_share3_service in
# group_vars/all/openbao.yml and the first [k3s_control] host in hosts.ini.
# Each can be overridden via env:
#   OPENBAO_SSH_TARGET    (default: derived from inventory)
#   OPENBAO_SSH_KEY       (default: derived from inventory)
#   OPENBAO_NAMESPACE     (default: openbao)
#   OPENBAO_POD           (default: openbao-0)
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
#   7   TLS verification against OpenBao failed (never bypassed)

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
    echo "(current live env id is in the umbrella's STATUS.digest.local.md, which bin/generate-status.sh writes)" >&2
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
    # Config error, not "already unsealed" — exit 1, never 2. Callers treat 2 as
    # success ("already unsealed"); reusing it here let an unresolved inventory be
    # mistaken for a no-op unseal (dmf-init bao-preflight false-success). (ADR-0044.)
    exit 1
fi
SSH_KEY="${OPENBAO_SSH_KEY:-${DERIVED_SSH_KEY:-}}"
OPENBAO_NAMESPACE="${OPENBAO_NAMESPACE:-openbao}"
OPENBAO_POD="${OPENBAO_POD:-openbao-0}"
SHARE_DIR="${OPENBAO_SHARE_DIR:-${DERIVED_SHARE_DIR:-}}"
[ -n "$SHARE_DIR" ] || { err "share dir not resolvable for '${ENV_NAME}' — set OPENBAO_SHARE_DIR or ensure the env inventory sets openbao_key_path"; exit 1; }
SHARE_KEYCHAIN_NAME="${OPENBAO_KEYCHAIN_SERVICE:-$DERIVED_KEYCHAIN_SVC}"
SHARE_KEYCHAIN_ACCT="${OPENBAO_KEYCHAIN_ACCOUNT:-share}"
SHARE_FIELD="${OPENBAO_SHARE_FIELD:-key}"   # JSON field in share-N.json

# The node-side curl transport and its OPENBAO_API_ADDR / OPENBAO_CACERT
# overrides are gone (#717): every call now runs bao inside the pod, which
# verifies the certificate the pod serves. Refuse a stale override instead of
# silently ignoring it, so nobody believes their CA file is in use.
for stale_var in OPENBAO_API_ADDR OPENBAO_CACERT; do
    if [ -n "${!stale_var:-}" ]; then
        err "$stale_var is no longer used: the wrapper runs bao inside the OpenBao pod,"
        err "  which verifies TLS against the certificate the pod serves. Unset $stale_var and retry."
        exit 1
    fi
done
# -T: never allocate a remote TTY. A TTY would echo piped stdin (a share) back
# onto the command's output.
ssh_opts=(-T -o LogLevel=ERROR)
[ -n "$SSH_KEY" ] && ssh_opts+=(-i "$SSH_KEY")

# bao's stderr from the most recent pod call, kept for TLS classification. It
# holds bao's error text only; bao never echoes request bodies.
BAO_ERR_FILE="$(mktemp)"
trap 'rm -f "$BAO_ERR_FILE"' EXIT

# Run bao inside the OpenBao pod. stdin passes through to bao; stdout is bao's
# stdout; stderr goes to BAO_ERR_FILE. BAO_ADDR and BAO_CACERT come from the
# pod spec; env -u drops any skip-verify variable so verification stays on.
# sudo -n: never prompt. A password prompt would read the piped share as input.
pod_bao() {
    ssh "${ssh_opts[@]}" "$SSH_TARGET" \
        sudo -n kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
        -n "$OPENBAO_NAMESPACE" exec -i "$OPENBAO_POD" -- \
        env -u BAO_SKIP_VERIFY -u VAULT_SKIP_VERIFY \
        bao "$@" 2>"$BAO_ERR_FILE"
}

tls_error_seen() {
    grep -qiE 'x509|certificate|tls:|handshake' "$BAO_ERR_FILE" 2>/dev/null
}

die_tls() {
    err "TLS verification failed while talking to OpenBao inside $OPENBAO_POD:"
    sed -n '1,5s/^/    /p' "$BAO_ERR_FILE" >&2
    err "The wrapper never skips certificate verification. Check that:"
    err "  - the openbao-tls certificate is ready and current:"
    err "      ssh $SSH_TARGET 'sudo kubectl -n $OPENBAO_NAMESPACE get certificate,secret'"
    err "  - BAO_CACERT in the pod names the certificate the pod serves"
    err "    (pod spec default: /openbao/config/tls/tls.crt)"
    err "  - the certificate covers the BAO_ADDR host (pod spec default: 127.0.0.1)"
    err "  - the pod restarted after the last certificate rotation"
    exit 7
}

# Fetch seal status into STATUS_JSON. Exits 7 on a TLS failure; returns 1 when
# OpenBao is unreachable for any other reason. `bao status` exits 0 unsealed,
# 2 sealed, 1 error, so we parse JSON instead of trusting the exit code.
STATUS_JSON=""
fetch_status() {
    STATUS_JSON="$(pod_bao status -format=json </dev/null || true)"
    # The -z test matters: jq 1.6 exits 0 for `jq -e` on empty input.
    if [ -z "$STATUS_JSON" ] || ! printf '%s' "$STATUS_JSON" | jq -e 'has("sealed")' >/dev/null 2>&1; then
        STATUS_JSON=""
        if tls_error_seen; then die_tls; fi
        return 1
    fi
}

is_sealed() {
    fetch_status || return 2
    [ "$(printf '%s' "$STATUS_JSON" | jq -r '.sealed // "unknown"')" = "true" ]
}

# Feed one share into OpenBao through `bao write sys/unseal -` inside the pod.
# stdin of THIS function = the share value (one line).
# The share traverses: function stdin → jq → ssh → kubectl exec -i → bao stdin.
# It never lands in argv on the local Mac, the control node, or in the pod.
# bao's stdout goes to /dev/null, so nothing it prints can reach ours.
feed_share_via_stdin() {
    local label="$1"
    local sealed progress

    if ! jq -R '{key: .}' | pod_bao write -format=json sys/unseal - >/dev/null; then
        if tls_error_seen; then die_tls; fi
        err "$label: bao rejected the unseal request:"
        sed -n '1,5s/^/    /p' "$BAO_ERR_FILE" >&2
        return 5
    fi

    if ! fetch_status; then
        err "$label: fed, but could not read seal status afterwards (pod responding?)"
        return 5
    fi
    sealed="$(printf '%s' "$STATUS_JSON" | jq -r '.sealed | tostring')"
    progress="$(printf '%s' "$STATUS_JSON" | jq -r '.progress // "?"')"
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

# ── Resolved environment ─────────────────────────────────────────────────
section "Environment: $ENV_NAME"
info "ssh target:   $SSH_TARGET"
info "openbao pod:  $OPENBAO_NAMESPACE/$OPENBAO_POD (bao in-pod, TLS verified)"
info "share dir:    $SHARE_DIR"
info "keychain svc: $SHARE_KEYCHAIN_NAME"

# ── Status mode ──────────────────────────────────────────────────────────
if [ "$MODE" = "status" ]; then
    section "OpenBao seal status"
    if ! fetch_status; then
        err "could not reach $OPENBAO_POD in $OPENBAO_NAMESPACE on $SSH_TARGET"
        exit 4
    fi
    printf '%s' "$STATUS_JSON" | jq '{sealed, version, t, n, progress, ha_enabled, cluster_name}'
    if [ "$(printf '%s' "$STATUS_JSON" | jq -r '.sealed')" = "false" ]; then
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
if ! fetch_status; then
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
  target:    pod=$OPENBAO_POD ns=$OPENBAO_NAMESPACE
  transport: ssh to $SSH_TARGET, kubectl exec into the pod, bao against the
             pod's own listener with TLS verified (not ingress-exposed)
EOF
else
    section "Unseal procedure (3-of-5 Shamir)"
    cat <<EOF
  source 1:  $SHARE_DIR/share-1.json (JuiceFS, .${SHARE_FIELD})
  source 2:  $SHARE_DIR/share-2.json (JuiceFS, .${SHARE_FIELD})
  source 3:  Keychain service='$SHARE_KEYCHAIN_NAME' account='$SHARE_KEYCHAIN_ACCT' (will prompt to unlock)
  target:    pod=$OPENBAO_POD ns=$OPENBAO_NAMESPACE
  transport: ssh to $SSH_TARGET, kubectl exec into the pod, bao against the
             pod's own listener with TLS verified (not ingress-exposed)

Each share is piped via stdin through jq, ssh, and kubectl exec into
bao write sys/unseal - inside the pod. The share value never appears in this
script's argv, environment, /tmp, stdout, SSH argv, kubectl argv, or bao argv.
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

# ── Feed shares ──────────────────────────────────────────────────────────
section "Feeding shares"

if [ "$SHARE_SOURCE" = "keys-json" ]; then
    # Sandbox / raw-init layout: feed the first t unseal keys from
    # openbao-keys.json (t = live threshold; 1 for a 1/1 sandbox). Same pipe as
    # the share-file path: jq stdout -> feed_share_via_stdin stdin -> ssh ->
    # kubectl exec -> bao.
    # The key value never enters argv, env, /tmp, or stdout.
    fetch_status || { err "could not read the unseal threshold from $OPENBAO_POD"; exit 4; }
    t="$(printf '%s' "$STATUS_JSON" | jq -r '.t // 1')"
    case "$t" in ''|*[!0-9]*) t=1 ;; esac
    nkeys="$(jq -r '.unseal_keys_hex | length' "$KEYS_JSON")"
    [ "$t" -le "$nkeys" ] || { err "threshold t=$t exceeds available keys ($nkeys) in $KEYS_JSON"; exit 3; }
    i=0
    while [ "$i" -lt "$t" ]; do
        jq -r --argjson i "$i" '.unseal_keys_hex[$i]' "$KEYS_JSON" \
            | feed_share_via_stdin "key $((i+1))/$t (openbao-keys.json)"
        i=$((i+1))
    done
else

# share 1
jq -r --arg f "$SHARE_FIELD" '.[$f]' "$SHARE_DIR/share-1.json" \
    | feed_share_via_stdin "share 1 (JuiceFS)"

# share 2
jq -r --arg f "$SHARE_FIELD" '.[$f]' "$SHARE_DIR/share-2.json" \
    | feed_share_via_stdin "share 2 (JuiceFS)"

# share 3 — Keychain (non-sandbox only; sandbox is 1/1 self-unseal with shares 1+2)
if [ "$IS_SANDBOX" -eq 1 ]; then
    info "sandbox posture — skipping share 3 (1/1 self-unseal, shares 1+2 sufficient)"
else
    security find-generic-password -s "$SHARE_KEYCHAIN_NAME" -a "$SHARE_KEYCHAIN_ACCT" -w \
        | feed_share_via_stdin "share 3 (Keychain)"
fi

fi  # close the share-source if/else

# ── Verify ───────────────────────────────────────────────────────────────
section "Verification"
if ! fetch_status; then
    err "could not read seal status after feeding shares — check with --status"
    exit 4
fi
if [ "$(printf '%s' "$STATUS_JSON" | jq -r '.sealed | tostring')" != "false" ]; then
    err "still sealed after feeding 3 shares — investigate"
    printf '%s' "$STATUS_JSON" | jq '{sealed, t, n, progress}' >&2
    exit 6
fi

printf '%s' "$STATUS_JSON" | jq '{sealed, version, cluster_id, cluster_name, ha_enabled}'
section "Done — unsealed"
exit 0
