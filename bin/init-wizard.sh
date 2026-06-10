#!/usr/bin/env bash
# init-wizard.sh — interactive greenfield env bootstrap wizard.
#
# Collects every unique-non-generable input for a new DMF env, generates
# random passwords for everything else, and writes (both sandbox and cloud):
#
# All artifacts operator-local under ~/.dmfdeploy/envs/<env>/:
#   bundle.sops.yaml                                 (encrypted secrets)
#   .sops.yaml                                       (per-env sops creation rule)
#   manifest.yaml                                    (Resource Profile)
#   inventory/hosts.ini                              (ansible inventory)
#   inventory/group_vars/all/{main,tailscale,openbao_secrets}.yml (vars)
#   ssh/operator.pub                                 (cluster SSH pubkey)
#   object-storage.tfvars                           (cloud only: B2 credentials)
#   hetzner.tfvars                                  (cloud only: provider credentials)
#   terraform-state/                                 (cloud only: per-env tofu state)
#   openbao-keys{,.json}                             (sandbox only: Tier-3 break-glass)
#
# Hard-refuses if the bundle already exists for the named env. Stops
# at artifact generation — operator runs `tofu apply` and the bootstrap
# playbooks themselves.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
UMBRELLA_DIR="$(dirname "$REPO_DIR")"

# shellcheck source=lib/_resolve_env_paths.sh
. "$SCRIPT_DIR/lib/_resolve_env_paths.sh"
dmf_source_operator_config

# Sandbox lane writes everything under DMF_DATA_ROOT (default ~/.dmfdeploy).
# Cloud lane keeps the repo-rooted layout untouched.
DMF_DATA_ROOT="${DMF_DATA_ROOT:-${HOME}/.dmfdeploy}"

AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"
export SOPS_AGE_KEY_FILE="${AGE_KEY_FILE}"

# ── Output helpers ──────────────────────────────────────────────────────────

CLR_RESET=$'\033[0m'
CLR_DIM=$'\033[2m'
CLR_BOLD=$'\033[1m'
CLR_RED=$'\033[31m'
CLR_GREEN=$'\033[32m'
CLR_YELLOW=$'\033[33m'
CLR_CYAN=$'\033[36m'

die()  { echo "${CLR_RED}ERROR:${CLR_RESET} $*" >&2; exit 1; }
warn() { echo "${CLR_YELLOW}WARN:${CLR_RESET}  $*" >&2; }
info() { echo "${CLR_CYAN}info:${CLR_RESET}  $*" >&2; }
ok()   { echo "${CLR_GREEN}  ✓${CLR_RESET} $*" >&2; }
section() {
    echo "" >&2
    echo "${CLR_BOLD}─── $1 ───${CLR_RESET}" >&2
}

# ── Prompts ─────────────────────────────────────────────────────────────────

prompt_required() {
    local label="$1" hint="${2:-}" val=""
    while [ -z "$val" ]; do
        [ -n "$hint" ] && echo "${CLR_DIM}  ${hint}${CLR_RESET}" >&2
        read -r -p "  ${label}: " val
        [ -z "$val" ] && warn "value required, try again"
    done
    printf '%s' "$val"
}

prompt_default() {
    local label="$1" default="${2:-}" hint="${3:-}" val=""
    [ -n "$hint" ] && echo "${CLR_DIM}  ${hint}${CLR_RESET}" >&2
    if [ -n "$default" ]; then
        read -r -p "  ${label} [${default}]: " val
        [ -z "$val" ] && val="$default"
    else
        read -r -p "  ${label} (optional, empty to skip): " val
    fi
    printf '%s' "$val"
}

prompt_secret() {
    local label="$1" hint="${2:-}" val=""
    while [ -z "$val" ]; do
        [ -n "$hint" ] && echo "${CLR_DIM}  ${hint}${CLR_RESET}" >&2
        read -r -s -p "  ${label} (hidden): " val
        echo "" >&2
        [ -z "$val" ] && warn "value required, try again"
    done
    printf '%s' "$val"
}

prompt_secret_optional() {
    local label="$1" hint="${2:-}" val=""
    [ -n "$hint" ] && echo "${CLR_DIM}  ${hint}${CLR_RESET}" >&2
    read -r -s -p "  ${label} (hidden; empty to skip): " val
    echo "" >&2
    printf '%s' "$val"
}

prompt_choice() {
    local label="$1"; shift
    local choices=("$@")
    local i=1
    echo "  ${label}:" >&2
    for c in "${choices[@]}"; do
        echo "    [$i] $c" >&2
        i=$((i+1))
    done
    local sel=""
    while [ -z "$sel" ]; do
        read -r -p "  Pick 1-${#choices[@]}: " sel
        if ! [[ "$sel" =~ ^[1-9][0-9]*$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#choices[@]}" ]; then
            warn "invalid choice"
            sel=""
        fi
    done
    printf '%s' "${choices[$((sel-1))]}"
}

yaml_string_list() {
    local raw="${1:-}" item out=""
    raw="${raw//,/ }"
    for item in $raw; do
        [ -n "$item" ] || continue
        if [ -n "$out" ]; then
            out="${out}, \"${item}\""
        else
            out="\"${item}\""
        fi
    done
    if [ -n "$out" ]; then
        printf '[%s]' "$out"
    else
        printf '[]'
    fi
}

confirm() {
    local label="$1" ans=""
    read -r -p "  ${label} [y/N]: " ans
    [[ "${ans:-N}" =~ ^[Yy] ]]
}

# ── Generators ──────────────────────────────────────────────────────────────

gen_password() {
    local length="${1:-32}"
    # Subshell isolates the SIGPIPE from `head -c N` closing the pipe
    # before `tr` finishes — would otherwise trip `set -o pipefail`.
    # Alphanumeric only: ~188 bits of entropy at 32 chars, plenty, and
    # no character that needs YAML / shell / Ansible escaping anywhere
    # downstream. (Previous charset `!@#%^*-_=+` had an unintended tr
    # range `*-_` that pulled in backslash, brackets, etc.)
    (
        set +o pipefail
        LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$length"
    )
}

gen_token() {
    local length="${1:-48}"
    (
        set +o pipefail
        LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$length"
    )
}

# gen_env_id — produces an opaque per-env identifier of shape `xxxx-xxxx`
# (8 lowercase alphanumeric chars, hyphen between the two halves). The id
# is the only path-shaped identifier henceforth; provider, architecture,
# and human label are tracked as separate fields. Retries on collision
# against an existing bundle, inventory, manifest, terraform root, or any
# new-layout env dir under ~/.dmfdeploy/envs/.
gen_env_id() {
    local raw id attempt=0
    while [ "$attempt" -lt 20 ]; do
        raw="$(set +o pipefail; LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 8)"
        id="${raw:0:4}-${raw:4:4}"
        if [ ! -e "${DMF_DATA_ROOT}/envs/${id}" ]; then
            printf '%s' "$id"
            return 0
        fi
        attempt=$((attempt + 1))
    done
    die "could not generate a non-colliding env_id after 20 attempts"
}

# ── Pre-flight ──────────────────────────────────────────────────────────────

check_age_key() {
    [ -f "$AGE_KEY_FILE" ] || die "age private key not found at ${AGE_KEY_FILE}. Generate with: age-keygen -o ${AGE_KEY_FILE} && chmod 600 ${AGE_KEY_FILE}"
    local pubkey
    pubkey="$(age-keygen -y "$AGE_KEY_FILE" 2>/dev/null)"
    [ -z "$pubkey" ] && die "could not derive public key from ${AGE_KEY_FILE}"
    printf '%s' "$pubkey"
}

hcloud_config_path() {
    printf '%s' "${HCLOUD_CONFIG:-${HOME}/.config/hcloud/cli.toml}"
}

hcloud_context_exists() {
    local context="$1"
    hcloud --config "$(hcloud_config_path)" context list -o noheader -o columns=name 2>/dev/null | grep -Fx -- "$context" >/dev/null
}

hcloud_token_from_context() {
    local context="$1"
    local config
    config="$(hcloud_config_path)"
    python3 - "$config" "$context" <<'PY'
import pathlib
import re
import sys

config_path = pathlib.Path(sys.argv[1]).expanduser()
context = sys.argv[2]
if not config_path.exists():
    sys.exit(0)

data = config_path.read_text()
pattern = (
    r'\[\[contexts\]\]\s+'
    r'name\s*=\s*"' + re.escape(context) + r'"\s+'
    r'token\s*=\s*"([^"]+)"'
)
match = re.search(pattern, data, re.DOTALL)
if match:
    print(match.group(1))
PY
}

ensure_hcloud_context() {
    local default_context="$1"
    command -v hcloud >/dev/null 2>&1 || die "missing dependency for Hetzner provider: hcloud"

    HCLOUD_CONTEXT="$(prompt_default "Hetzner hcloud context name" "$default_context" "Local CLI context for the Hetzner Console project that owns this env. Use one context per project/env boundary.")"
    [ -n "${HCLOUD_CONTEXT}" ] || die "Hetzner hcloud context name is required"
    [[ "${HCLOUD_CONTEXT}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Hetzner hcloud context name must contain only letters, numbers, dot, underscore, or hyphen"

    if hcloud_context_exists "${HCLOUD_CONTEXT}"; then
        hcloud --config "$(hcloud_config_path)" context use "${HCLOUD_CONTEXT}" >/dev/null
        ok "hcloud context selected: ${HCLOUD_CONTEXT}"
    else
        info "creating hcloud context '${HCLOUD_CONTEXT}' — paste the token for the matching Hetzner Console project when prompted"
        hcloud --config "$(hcloud_config_path)" context create "${HCLOUD_CONTEXT}"
    fi

    HCLOUD_TOKEN="$(hcloud_token_from_context "${HCLOUD_CONTEXT}")"
    [ -n "${HCLOUD_TOKEN}" ] || die "could not read token for hcloud context '${HCLOUD_CONTEXT}' from $(hcloud_config_path)"
}

usage() {
    cat >&2 <<'EOF'
Usage:
  bin/init-wizard.sh
  bin/init-wizard.sh --non-interactive <answers.yaml>
  bin/init-wizard.sh --help

Greenfield env bootstrap wizard.
  --non-interactive  Load operator inputs from a YAML answers file and stop at artifact generation.
  --remove <env>     Passthrough to bin/remove-env.sh (kept for compatibility).
EOF
}

check_deps() {
    local mode="${1:-interactive}"
    for cmd in sops age-keygen ssh-keygen python3; do
        command -v "$cmd" >/dev/null 2>&1 || die "missing dependency: ${cmd}"
    done
    if [ "$mode" = "non-interactive" ]; then
        command -v yq >/dev/null 2>&1 || die "missing dependency: yq"
    fi
}

yaml_get() {
    local file="$1" expr="$2"
    yq -r "${expr} // \"\"" "$file"
}

trim_spaces() {
    printf '%s' "$1" | tr -d '[:space:]'
}

lowercase() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

validate_dns_label() {
    local label="$1"
    [ -n "$label" ] || die "sandbox label is required"
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "invalid sandbox label: ${label}"
    [ "${#label}" -le 63 ] || die "sandbox label must be 63 chars or fewer"
}

validate_absolute_path() {
    local path="$1" label="$2"
    [ -n "$path" ] || die "${label} is required"
    case "$path" in
        /*) ;;
        *) die "${label} must be an absolute path, got: ${path}" ;;
    esac
}

apply_posture_profile() {
    case "${POSTURE}" in
        sandbox)
            POSTURE_PROMETHEUS_STORAGE_SIZE="5Gi"
            POSTURE_PROMETHEUS_RETENTION_SIZE="2GB"
            POSTURE_PROMETHEUS_ALERTMANAGER_ENABLED="false"
            POSTURE_LOKI_STORAGE_SIZE="5Gi"
            POSTURE_ZOT_STORAGE_SIZE="15Gi"
            POSTURE_LONGHORN_REPLICA_COUNT="1"
            POSTURE_MIN_NODE_RAM_GB="10"
            POSTURE_MIN_NODE_DISK_GB="60"
            POSTURE_RECOMMENDED_VPS="generic ARM64 Debian (4 CPU / 10 GiB / 60 GiB)"
            ;;
        test)
            POSTURE_PROMETHEUS_STORAGE_SIZE="5Gi"
            POSTURE_PROMETHEUS_RETENTION_SIZE="2GB"
            POSTURE_PROMETHEUS_ALERTMANAGER_ENABLED="false"
            POSTURE_LOKI_STORAGE_SIZE="5Gi"
            POSTURE_ZOT_STORAGE_SIZE="15Gi"
            POSTURE_LONGHORN_REPLICA_COUNT="2"
            POSTURE_MIN_NODE_RAM_GB="8"
            POSTURE_MIN_NODE_DISK_GB="80"
            POSTURE_RECOMMENDED_VPS="Hetzner CAX21 / Aliyun small ARM"
            ;;
        production)
            POSTURE_PROMETHEUS_STORAGE_SIZE="50Gi"
            POSTURE_PROMETHEUS_RETENTION_SIZE="40GB"
            POSTURE_PROMETHEUS_ALERTMANAGER_ENABLED="true"
            POSTURE_LOKI_STORAGE_SIZE="50Gi"
            POSTURE_ZOT_STORAGE_SIZE="20Gi"
            POSTURE_LONGHORN_REPLICA_COUNT="3"
            POSTURE_MIN_NODE_RAM_GB="16"
            POSTURE_MIN_NODE_DISK_GB="200"
            POSTURE_RECOMMENDED_VPS="Hetzner CAX31+ / equivalent"
            ;;
        *)
            die "unknown posture: ${POSTURE}"
            ;;
    esac
}

init_env_paths() {
    local env_id="$1"
    ENV_ID="$env_id"
    ENV_ROOT="${DMF_DATA_ROOT}/envs/${ENV_ID}"
    BUNDLE_FILE="${ENV_ROOT}/bundle.sops.yaml"
    MANIFEST_FILE="${ENV_ROOT}/manifest.yaml"
    INVENTORY_DISPLAY="${ENV_ROOT}/inventory/"
    SOPS_FILE="${ENV_ROOT}/.sops.yaml"
    rm -f "${BUNDLE_FILE}.wizard-tmp"
}

# derive_sandbox_base_domain — compute BASE_DOMAIN for sandbox.
# Inputs (must be set before calling):
#   SANDBOX_NODE_IP       — browser-reachable IP (public for NAT'd nodes)
#   SANDBOX_LABEL         — DNS-safe label
#   SANDBOX_BASE_DOMAIN   — explicit override (optional; may be empty)
#   SANDBOX_ADDRESSING    — "sslip.io" (default) or "hosts"
# Side effects: sets BASE_DOMAIN and SANDBOX_LABEL (ensures label is set).
derive_sandbox_base_domain() {
    # Explicit override wins — operator provided sandbox.base_domain.
    if [ -n "${SANDBOX_BASE_DOMAIN:-}" ]; then
        BASE_DOMAIN="${SANDBOX_BASE_DOMAIN}"
        if [ -z "${SANDBOX_LABEL}" ]; then
            SANDBOX_LABEL="$(printf '%s' "${BASE_DOMAIN}" | cut -d. -f1)"
        fi
        return 0
    fi

    # Air-gapped opt-out: hosts-based addressing → .dmf.test.
    if [ "${SANDBOX_ADDRESSING:-sslip.io}" = "hosts" ]; then
        BASE_DOMAIN="${SANDBOX_LABEL}.dmf.test"
        return 0
    fi

    # Default: sslip.io — requires a valid IPv4 to derive a working domain.
    local ip="${SANDBOX_NODE_IP:-}"
    if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        local dashed
        dashed="$(printf '%s' "$ip" | tr '.' '-')"
        BASE_DOMAIN="${dashed}.sslip.io"
        # If no label was given, derive one from the dashed IP for consistency.
        if [ -z "${SANDBOX_LABEL}" ]; then
            SANDBOX_LABEL="${dashed}"
        fi
        return 0
    fi

    # Non-IPv4 (or empty): fall back to .dmf.test with a warning.
    warn "SANDBOX_NODE_IP '${ip}' is not a valid IPv4 — falling back to .dmf.test (air-gapped opt-out). Set sandbox.addressing: hosts or supply sandbox.base_domain explicitly."
    BASE_DOMAIN="${SANDBOX_LABEL}.dmf.test"
}

validate_inputs() {
    case "${PROVIDER}" in
        sandbox|hetzner) ;;
        *) die "unknown provider: ${PROVIDER}" ;;
    esac

    OPERATOR_DISPLAY="${OPERATOR_DISPLAY:-${OPERATOR_USERNAME}}"

    if [ "${PROVIDER}" = "sandbox" ]; then
        ARCH="arm64"
        POSTURE="sandbox"
        derive_sandbox_base_domain
        ENV_LABEL="${SANDBOX_LABEL}"
        [ -n "${SANDBOX_LABEL}" ] && validate_dns_label "${SANDBOX_LABEL}"
        [ -n "${SANDBOX_NODE_IP}" ] || die "sandbox.node_ip is required"
        [ -n "${ANSIBLE_USER}" ] || die "sandbox.ansible_user is required"
        [ -n "${SANDBOX_IFACE}" ] || die "sandbox.iface is required"
        validate_absolute_path "${SSH_PRIVKEY_PATH}" "sandbox.ssh_private_key_path"
        SSH_ALLOW_IPV4=""
        SSH_ALLOW_IPV6=""
        CF_DNS_TOKEN=""
        CF_ZONE_NAME=""
        B2_KEY_ID=""
        B2_APP_KEY=""
        B2_REGION=""
        TS_AUTHKEY=""
        HEADSCALE_HOST=""
        OPENBAO_BREAKGLASS_DIR=""
        OPENBAO_USB_BASE=""
        HCLOUD_TOKEN=""
        HCLOUD_CONTEXT=""
        HCLOUD_SSH_KEY_NAME=""
        ALICLOUD_ACCESS_KEY=""
        ALICLOUD_SECRET_KEY=""
        AWS_ACCESS_KEY_ID=""
        AWS_SECRET_ACCESS_KEY=""
        AWS_REGION=""
        SSH_PUBKEY_PATH=""
        SSH_PRIVKEY_CONTENTS=""
        USE_GENERATED_KEY="yes"
    else
        [ -n "${ARCH}" ] || die "architecture is required"
        case "${ARCH}" in
            arm64|amd64) ;;
            *) die "invalid architecture: ${ARCH}" ;;
        esac

        [ -n "${POSTURE}" ] || die "posture is required"
        case "${POSTURE}" in
            test|production) ;;
            *) die "invalid posture: ${POSTURE}" ;;
        esac

        [ -n "${BASE_DOMAIN}" ] || die "base_domain is required"
        [ -n "${OPERATOR_USERNAME}" ] || die "operator.username is required"
        [ -n "${OPERATOR_EMAIL}" ] || die "operator.email is required"
        [ -n "${OPENBAO_BREAKGLASS_DIR}" ] || die "openbao.breakglass_dir is required"
        validate_absolute_path "${OPENBAO_BREAKGLASS_DIR}" "openbao.breakglass_dir"

        if [ -z "${OPENBAO_USB_BASE}" ]; then
            OPENBAO_USB_BASE="/path/to/usb-storage"
        fi

        if [ -z "${CF_ZONE_NAME}" ]; then
            CF_ZONE_NAME="$(printf '%s' "${BASE_DOMAIN}" | rev | cut -d. -f1,2 | rev)"
        fi

        case "${PROVIDER}" in
            hetzner)
                [ -n "${HCLOUD_CONTEXT}" ] || die "hetzner.context is required"
                [ -n "${HCLOUD_TOKEN}" ] || die "hetzner.cloud_token is required"
                HCLOUD_SSH_KEY_NAME="${HCLOUD_SSH_KEY_NAME:-${ENV_ID}-operator}"
                ;;
            aliyun)
                [ -n "${ALICLOUD_ACCESS_KEY}" ] || die "alicloud access_key is required"
                [ -n "${ALICLOUD_SECRET_KEY}" ] || die "alicloud secret_key is required"
                ;;
            aws)
                [ -n "${AWS_ACCESS_KEY_ID}" ] || die "aws.access_key_id is required"
                [ -n "${AWS_SECRET_ACCESS_KEY}" ] || die "aws.secret_access_key is required"
                [ -n "${AWS_REGION}" ] || die "aws.region is required"
                ;;
        esac

        [ -n "${CF_DNS_TOKEN}" ] || die "dns.cloudflare_api_token is required"
        [ -n "${SSH_ALLOW_IPV4}" ] || die "network.ssh_allow_ipv4 is required"
        [ -n "${B2_KEY_ID}" ] || die "object_storage.b2_key_id is required"
        [ -n "${B2_APP_KEY}" ] || die "object_storage.b2_app_key is required"
        [ -n "${B2_REGION}" ] || die "object_storage.b2_region is required"

        if [ "${PROVIDER}" = "aws" ]; then
            warn "AWS Terraform root module is not yet scaffolded — bundle + manifest + tfvars will be written, but \`tofu apply\` will need a module first. See follow-ups in docs/plans/."
        fi

        case "${USE_GENERATED_KEY}" in
            yes)
                SSH_PUBKEY_PATH=""
                SSH_PRIVKEY_CONTENTS=""
                ;;
            no)
                [ -n "${SSH_PUBKEY_PATH}" ] || die "ssh.public_key_path is required when ssh.mode=byo"
                validate_absolute_path "${SSH_PUBKEY_PATH}" "ssh.public_key_path"
                validate_absolute_path "${SSH_PRIVKEY_PATH}" "ssh.private_key_path"
                [ -r "${SSH_PUBKEY_PATH}" ] || die "cannot read SSH public key at ${SSH_PUBKEY_PATH}"
                [ -r "${SSH_PRIVKEY_PATH}" ] || die "cannot read SSH private key at ${SSH_PRIVKEY_PATH}"
                ;;
            *)
                die "invalid ssh.mode: ${USE_GENERATED_KEY}"
                ;;
        esac
    fi

    apply_posture_profile
}

collect_inputs_interactive() {
    echo "" >&2
    echo "${CLR_BOLD}DMF Init Wizard${CLR_RESET}" >&2
    echo "${CLR_DIM}Greenfield env bootstrap. Stops at artifact generation; operator runs tofu + playbooks.${CLR_RESET}" >&2

    check_deps interactive
    AGE_PUBLIC_KEY="$(check_age_key)"
    ok "age public key: ${AGE_PUBLIC_KEY}"

    section "Environment"
    PROVIDER="$(prompt_choice "Provider" hetzner sandbox)"

    # Bundle-dir validation is cloud-only. Sandbox envs write their bundle
    # straight into ~/.dmfdeploy/envs/<env>/ and never touch
    # DMF_BOOTSTRAP_BUNDLE_DIR.
    if [ "$PROVIDER" = "sandbox" ]; then
        install -d -m 0700 "${DMF_DATA_ROOT}"
        install -d -m 0700 "${DMF_DATA_ROOT}/envs"
        ok "sandbox data root: ${DMF_DATA_ROOT}/envs/"
    fi
    if [ "$PROVIDER" = "sandbox" ]; then
        # Sandbox is the single-node ARM64 Debian release-gate profile
        # (ADR-0031 Profile 1 / WP1S). Architecture is fixed; the human label is
        # the DNS subdomain label collected with the base domain below.
        ARCH="arm64"
        ENV_LABEL=""
        ok "architecture: arm64 (fixed for sandbox)"
    else
        ARCH="$(prompt_choice "Architecture" arm64 amd64)"
        ENV_LABEL="$(prompt_default "Optional human label" "" "Display-only; surfaces in NetBox site name + manifest description. Empty to skip (env_id is used as fallback). Free text — never used as a path.")"
    fi

    # Posture drives resource sizing across the rendered inventory (Prometheus
    # storage + retention, Longhorn replica count, Alertmanager enabled state).
    # The actual sizing map is applied in validate_inputs() so both input modes
    # share one source of truth.
    if [ "$PROVIDER" = "sandbox" ]; then
        POSTURE="sandbox"
    else
        echo "" >&2
        echo "  Posture drives resource sizing. Pick:" >&2
        echo "    test       — experiment / lab work; 8 GB RAM, 80 GB disk per node" >&2
        echo "                  (e.g. Hetzner CAX21). Prometheus 5Gi / 2GB; 2 Longhorn replicas;" >&2
        echo "                  Alertmanager off." >&2
        echo "    production — hardening / live posture; 16 GB RAM, 200 GB disk per node" >&2
        echo "                  (e.g. Hetzner CAX31+). Prometheus 50Gi / 40GB; 3 Longhorn replicas;" >&2
        echo "                  Alertmanager on (requires ntfy + watchdog receiver URLs in OpenBao)." >&2
        echo "" >&2
        POSTURE="$(prompt_choice "Posture" test production)"
    fi

    local env_id
    env_id="$(gen_env_id)"
    ok "env_id (auto-generated): ${env_id}"
    init_env_paths "$env_id"

    section "Operator identity"
    info "The INITIAL OPERATOR (you): your steady-state admin, seeded into Authentik"
    info "(OIDC/passkey login) and projected as each app's OIDC admin. This is NOT a"
    info "per-app break-glass local account — those are separate, dormant, dedicated"
    info "identities (e.g. awx-break-glass) under secret/apps/<app>/breakglass."
    OPERATOR_USERNAME="$(prompt_required "Operator username" "Your operator identity (e.g. yourname) — becomes ops-admin in Authentik + the OIDC-projected admin in each app. Must NOT collide with any break-glass local username.")"
    OPERATOR_EMAIL="$(prompt_required "Operator email" "Your email — Authentik bootstrap + (cloud) Let's Encrypt notifications.")"
    OPERATOR_DISPLAY="$(prompt_default "Operator display name" "${OPERATOR_USERNAME}")"

    if [ "$PROVIDER" = "sandbox" ]; then
        section "Sandbox base domain"
        info "Default: sslip.io — hostnames resolve automatically via <node-ip-dashed>.sslip.io"
        info "with no /etc/hosts edits. Requires the node to be internet-reachable on 443."
        info "Opt-out: use .dmf.test + explicit host mappings for air-gapped runs."
        local sandbox_label=""
        while :; do
            sandbox_label="$(prompt_default "Sandbox subdomain label (cosmetic)" "" "Optional display label; empty auto-derives BASE_DOMAIN from node IP via sslip.io. Lowercase letters, digits, hyphens; must start and end alphanumeric; max 63 chars.")"
            sandbox_label="$(printf '%s' "$sandbox_label" | tr '[:upper:]' '[:lower:]')"
            # Empty is valid — auto-derive from node IP.
            if [ -z "$sandbox_label" ]; then
                break
            fi
            if [[ "$sandbox_label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] && [ "${#sandbox_label}" -le 63 ]; then
                break
            fi
            warn "invalid DNS label '${sandbox_label}' — lowercase letters/digits/hyphens, start+end alphanumeric, ≤63 chars, or empty to auto-derive"
        done
        SANDBOX_LABEL="$sandbox_label"
        ENV_LABEL="${SANDBOX_LABEL}"
        # Placeholder; derive_sandbox_base_domain() in validate_inputs() resolves once
        # SANDBOX_NODE_IP is known.
        if [ -n "$SANDBOX_LABEL" ]; then
            BASE_DOMAIN="${SANDBOX_LABEL}.dmf.test"
        else
            BASE_DOMAIN="<auto-derive-after-node-ip>"
        fi
        CF_DNS_TOKEN=""
        CF_ZONE_NAME=""
        if [ -n "$SANDBOX_LABEL" ]; then
            ok "label: ${SANDBOX_LABEL}  (cosmetic; BASE_DOMAIN final after node IP collection)"
        else
            ok "label: (empty — BASE_DOMAIN will auto-derive from node IP via sslip.io)"
        fi
    else
        section "Base domain + DNS"
        BASE_DOMAIN="$(prompt_required "Base domain" "Apex or subdomain the cluster lives under, e.g., lab.example.com.")"
        CF_DNS_TOKEN="$(prompt_secret "Cloudflare API token (zone-read + dns-edit scoped)" "Used by cert-manager DNS-01 + Tailscale playbook.")"
        CF_ZONE_NAME="$(prompt_default "Cloudflare zone name (apex)" "$(echo "${BASE_DOMAIN}" | rev | cut -d. -f1,2 | rev)" "The registered zone in Cloudflare (apex, not the cluster subdomain).")"
    fi

    if [ "$PROVIDER" = "sandbox" ]; then
        section "Sandbox node connection"
        info "One ARM64 Debian node, reached VPS-style over plain SSH on its routable IP."
        SANDBOX_NODE_IP="$(prompt_required "Sandbox node host/IP" "Routable address of the node — its LAN IP, or a VPS public IP. Used as ansible_host and k3s_node_ip.")"
        ANSIBLE_USER="$(prompt_default "Node SSH user (ansible_user)" "${USER}" "Login user on the node (needs passwordless sudo). The default is your local username — correct for a Lima VM (its guest user matches your host user); on a cloud VPS / bare metal it is usually debian or root.")"
        SSH_PRIVKEY_PATH="$(prompt_required "SSH private key path for the node" "Workstation private key that authenticates as the SSH user. Referenced by path (ansible_ssh_private_key_file); not embedded.")"
        [ -r "${SSH_PRIVKEY_PATH}" ] || warn "SSH private key not readable at ${SSH_PRIVKEY_PATH} — it must exist before run-playbook.sh."
        SANDBOX_IFACE="$(prompt_default "Node primary network interface" "eth0" "NIC carrying the routable IP; pins k3s/flannel. Lima=lima0, Hetzner=enp7s0, many VPS=eth0/enp1s0.")"
        SSH_PUBKEY_PATH=""
        SSH_PRIVKEY_CONTENTS=""
        USE_GENERATED_KEY="yes"
        OPENBAO_BREAKGLASS_DIR=""
        OPENBAO_USB_BASE=""
    else
        section "Cluster SSH keys"
        local use_generated_key
        use_generated_key="$(prompt_default "Generate new per-env SSH keypair?" "yes" "Generate a new ed25519 keypair for this cluster (stored per-env under ~/.dmfdeploy/envs/<env>/ssh/). Alternatively, provide an existing workstation key. Default is to generate.")"
        USE_GENERATED_KEY="yes"
        case "${use_generated_key}" in
            y|yes|Y|YES)
                USE_GENERATED_KEY="yes"
                ;;
            n|no|N|NO)
                USE_GENERATED_KEY="no"
                SSH_PUBKEY_PATH="$(prompt_required "Workstation SSH public key path" "Path to an existing SSH public key (will be copied to the env dir).")"
                [ -r "${SSH_PUBKEY_PATH}" ] || die "cannot read SSH public key at ${SSH_PUBKEY_PATH}"
                SSH_PRIVKEY_PATH="$(prompt_required "Workstation SSH private key path" "Path to the matching private key.")"
                [ -r "${SSH_PRIVKEY_PATH}" ] || die "cannot read SSH private key at ${SSH_PRIVKEY_PATH}"
                ;;
            *)
                die "Invalid response: ${use_generated_key}" ;;
        esac

        section "Operator secret storage"
        OPENBAO_BREAKGLASS_DIR="$(prompt_required "OpenBao break-glass storage root path" "Filesystem path under which per-env share dirs live. Typically a JuiceFS mount, e.g. <secure-store>/openbao-breakglass. Wizard appends /<env_id>/ at use time.")"
        case "${OPENBAO_BREAKGLASS_DIR}" in
            /*) ;;
            *) die "OPENBAO_BREAKGLASS_DIR must be an absolute path, got: ${OPENBAO_BREAKGLASS_DIR}" ;;
        esac
        OPENBAO_USB_BASE="$(prompt_default "OpenBao USB share base path" "/path/to/usb-storage" "Parent dir of the per-env USB break-glass share (the wizard appends /<env_id>). Point this at your mounted encrypted break-glass volume, e.g. macOS /Volumes/<label> or Linux /mnt/<label>. Holds ADR-0009 Shamir shares 4+5 for disaster recovery; the openbao role mount-asserts whatever path you set here.")"
    fi

    if [ "$PROVIDER" = "sandbox" ]; then
        SSH_ALLOW_IPV4=""
        SSH_ALLOW_IPV6=""
    else
        section "Network access"
        SSH_ALLOW_IPV4="$(prompt_required "SSH allow IPv4 CIDRs" "Comma-separated CIDRs allowed to SSH to the nodes, e.g. 203.0.113.10/32. Use 0.0.0.0/0 only if you accept public SSH exposure.")"
        SSH_ALLOW_IPV6="$(prompt_default "SSH allow IPv6 CIDRs" "" "Comma-separated IPv6 CIDRs. Empty skips IPv6 SSH firewall allowance.")"
    fi

    section "Provider credentials"
    HCLOUD_TOKEN=""
    HCLOUD_CONTEXT=""
    HCLOUD_SSH_KEY_NAME=""
    ALICLOUD_ACCESS_KEY=""
    ALICLOUD_SECRET_KEY=""
    AWS_ACCESS_KEY_ID=""
    AWS_SECRET_ACCESS_KEY=""
    AWS_REGION=""
    case "$PROVIDER" in
        hetzner)
            ensure_hcloud_context "${env_id}"
            HCLOUD_SSH_KEY_NAME="${env_id}-operator"
            ;;
        aliyun)
            ALICLOUD_ACCESS_KEY="$(prompt_secret "Alicloud AccessKey ID")"
            ALICLOUD_SECRET_KEY="$(prompt_secret "Alicloud AccessKey Secret")"
            ;;
        aws)
            AWS_ACCESS_KEY_ID="$(prompt_secret "AWS Access Key ID")"
            AWS_SECRET_ACCESS_KEY="$(prompt_secret "AWS Secret Access Key")"
            AWS_REGION="$(prompt_default "AWS region" "eu-central-1")"
            ;;
        sandbox)
            info "Sandbox profile — no cloud provider credentials required."
            ;;
    esac

    if [ "$PROVIDER" = "sandbox" ]; then
        B2_KEY_ID=""
        B2_APP_KEY=""
        B2_REGION=""
        TS_AUTHKEY=""
        HEADSCALE_HOST=""
    else
        section "Backblaze B2 (object storage)"
        info "Will use the SAME B2 keypair for audit + openbao_snapshots + app_backups buckets."
        info "Bucket names: dmf-{audit,openbao-snapshots,app-backups}-${env_id} — will be created by b2-buckets.sh post-wizard."
        B2_KEY_ID="$(prompt_required "B2 keyID" "From the B2 console — application key (NOT master key).")"
        B2_APP_KEY="$(prompt_secret "B2 applicationKey")"
        B2_REGION="$(prompt_default "B2 region" "us-west-001" "Account region — matches the s3 endpoint subdomain.")"

        section "Optional networking"
        TS_AUTHKEY="$(prompt_secret_optional "Tailscale auth key")"
        HEADSCALE_HOST="$(prompt_default "Headscale host (empty to skip)" "" "Self-hosted Tailscale control plane. Used by the headscale-cleanup playbook.")"
    fi
}

load_inputs_noninteractive() {
    local answers_file="$1"
    [ -r "$answers_file" ] || die "answers file not readable: ${answers_file}"

    check_deps non-interactive
    AGE_PUBLIC_KEY="$(check_age_key)"
    ok "age public key: ${AGE_PUBLIC_KEY}"
    local provider
    provider="$(lowercase "$(trim_spaces "$(yaml_get "$answers_file" '.provider')")")"
    [ -n "$provider" ] || die "answers file is missing provider"
    PROVIDER="$provider"

    local env_id
    env_id="$(gen_env_id)"
    ok "env_id (auto-generated): ${env_id}"
    init_env_paths "$env_id"

    ARCH="$(lowercase "$(trim_spaces "$(yaml_get "$answers_file" '.architecture')")")"
    POSTURE="$(lowercase "$(trim_spaces "$(yaml_get "$answers_file" '.posture')")")"
    OPERATOR_USERNAME="$(yaml_get "$answers_file" '.operator.username')"
    OPERATOR_EMAIL="$(yaml_get "$answers_file" '.operator.email')"
    OPERATOR_DISPLAY="$(yaml_get "$answers_file" '.operator.display')"
    ENV_LABEL="$(yaml_get "$answers_file" '.label')"
    BASE_DOMAIN="$(yaml_get "$answers_file" '.base_domain')"
    SANDBOX_LABEL="$(yaml_get "$answers_file" '.sandbox.label')"
    SANDBOX_NODE_IP="$(yaml_get "$answers_file" '.sandbox.node_ip')"
    ANSIBLE_USER="$(yaml_get "$answers_file" '.sandbox.ansible_user')"
    SANDBOX_IFACE="$(yaml_get "$answers_file" '.sandbox.iface')"
    SANDBOX_ADDRESSING="$(yaml_get "$answers_file" '.sandbox.addressing')"
    SANDBOX_BASE_DOMAIN="$(yaml_get "$answers_file" '.sandbox.base_domain')"
    SSH_PRIVKEY_PATH="$(yaml_get "$answers_file" '.sandbox.ssh_private_key_path')"
    [ -z "$SSH_PRIVKEY_PATH" ] && SSH_PRIVKEY_PATH="$(yaml_get "$answers_file" '.ssh.private_key_path')"
    SSH_PUBKEY_PATH="$(yaml_get "$answers_file" '.ssh.public_key_path')"
    CF_DNS_TOKEN="$(yaml_get "$answers_file" '.dns.cloudflare_api_token')"
    CF_ZONE_NAME="$(yaml_get "$answers_file" '.dns.cloudflare_zone_name')"
    SSH_ALLOW_IPV4="$(yaml_get "$answers_file" '.network.ssh_allow_ipv4')"
    SSH_ALLOW_IPV6="$(yaml_get "$answers_file" '.network.ssh_allow_ipv6')"
    HCLOUD_CONTEXT="$(yaml_get "$answers_file" '.hetzner.context')"
    HCLOUD_TOKEN="$(yaml_get "$answers_file" '.hetzner.cloud_token')"
    ALICLOUD_ACCESS_KEY="$(yaml_get "$answers_file" '.aliyun.access_key')"
    ALICLOUD_SECRET_KEY="$(yaml_get "$answers_file" '.aliyun.secret_key')"
    AWS_ACCESS_KEY_ID="$(yaml_get "$answers_file" '.aws.access_key_id')"
    AWS_SECRET_ACCESS_KEY="$(yaml_get "$answers_file" '.aws.secret_access_key')"
    AWS_REGION="$(yaml_get "$answers_file" '.aws.region')"
    B2_KEY_ID="$(yaml_get "$answers_file" '.object_storage.b2_key_id')"
    B2_APP_KEY="$(yaml_get "$answers_file" '.object_storage.b2_app_key')"
    B2_REGION="$(yaml_get "$answers_file" '.object_storage.b2_region')"
    TS_AUTHKEY="$(yaml_get "$answers_file" '.networking.tailscale_authkey')"
    HEADSCALE_HOST="$(yaml_get "$answers_file" '.networking.headscale_host')"
    OPENBAO_BREAKGLASS_DIR="$(yaml_get "$answers_file" '.openbao.breakglass_dir')"
    OPENBAO_USB_BASE="$(yaml_get "$answers_file" '.openbao.usb_base')"
    local ssh_mode
    ssh_mode="$(lowercase "$(trim_spaces "$(yaml_get "$answers_file" '.ssh.mode')")")"
    case "${ssh_mode}" in
        generate)
            USE_GENERATED_KEY="yes"
            ;;
        byo)
            USE_GENERATED_KEY="no"
            ;;
        "")
            if [ "$PROVIDER" = "sandbox" ]; then
                USE_GENERATED_KEY="yes"
            else
                die "ssh.mode is required for provider=${PROVIDER}"
            fi
            ;;
        *)
            die "invalid ssh.mode in answers file: ${ssh_mode}"
            ;;
    esac

    if [ "$PROVIDER" = "sandbox" ]; then
        SANDBOX_LABEL="$(lowercase "$SANDBOX_LABEL")"
        if [ -z "$SANDBOX_LABEL" ]; then
            SANDBOX_LABEL="$(lowercase "$ENV_LABEL")"
        fi
        # Empty is valid — auto-derive from node IP in derive_sandbox_base_domain().
        if [ -n "$SANDBOX_LABEL" ]; then
            validate_dns_label "$SANDBOX_LABEL"
            ENV_LABEL="$SANDBOX_LABEL"
        fi
        derive_sandbox_base_domain
        ARCH="arm64"
        POSTURE="sandbox"
        case "${SSH_PRIVKEY_PATH}" in
            "") die "sandbox.ssh_private_key_path is required for provider=sandbox" ;;
        esac
        CF_DNS_TOKEN=""
        CF_ZONE_NAME=""
        B2_KEY_ID=""
        B2_APP_KEY=""
        B2_REGION=""
        TS_AUTHKEY=""
        HEADSCALE_HOST=""
        OPENBAO_BREAKGLASS_DIR=""
        OPENBAO_USB_BASE=""
    else
        if [ -z "${OPERATOR_DISPLAY}" ]; then
            OPERATOR_DISPLAY="${OPERATOR_USERNAME}"
        fi
    fi

    if [ "$PROVIDER" != "sandbox" ] && [ "$USE_GENERATED_KEY" = "no" ]; then
        [ -n "$SSH_PRIVKEY_PATH" ] || die "ssh.private_key_path is required when ssh.mode=byo"
        [ -n "$SSH_PUBKEY_PATH" ] || die "ssh.public_key_path is required when ssh.mode=byo"
    fi

    if [ "$PROVIDER" = "hetzner" ] && [ -z "$HCLOUD_CONTEXT" ]; then
        HCLOUD_CONTEXT="$ENV_ID"
    fi
    if [ "$PROVIDER" = "hetzner" ] && [ -n "$HCLOUD_CONTEXT" ]; then
        HCLOUD_SSH_KEY_NAME="${ENV_ID}-operator"
    fi
}

# _gen_keypair <env_id> <ssh_dir> <name> <pubvar> <privvar>
# Generate an ed25519 keypair into <ssh_dir>/<name>.pub; set <pubvar> to that
# pubkey path and <privvar> to the privkey contents (exactly one trailing
# newline). Portable: only ssh-keygen + mktemp -d (no shred, no /Volumes, no
# Keychain). ssh-keygen needs a NON-existent target (it prompts to overwrite an
# existing file → silent abort under set -e with no TTY), hence mktemp -d.
_gen_keypair() {
    local env_id="$1" ssh_dir="$2" name="$3" pubvar="$4" privvar="$5"
    command -v ssh-keygen >/dev/null 2>&1 || die "missing dependency: ssh-keygen"
    install -d -m 0700 "$ssh_dir"
    local tmp_dir
    tmp_dir="$(mktemp -d)" || die "mktemp -d failed"
    local priv="${tmp_dir}/${name}"
    ssh-keygen -t ed25519 -N "" -C "dmf ${env_id} ${name}" -f "$priv" >/dev/null 2>&1 \
        || { rm -rf "$tmp_dir"; die "ssh-keygen failed to generate the ${name} keypair"; }
    cat "${priv}.pub" > "${ssh_dir}/${name}.pub"
    chmod 0644 "${ssh_dir}/${name}.pub"
    printf -v "$pubvar" '%s' "${ssh_dir}/${name}.pub"
    # $(cat) strips trailing newlines; re-add exactly one so the PEM is intact.
    printf -v "$privvar" '%s\n' "$(cat "$priv")"
    rm -rf "$tmp_dir"
    ok "generated per-env keypair: ${ssh_dir}/${name}.pub"
}

# Node/operator key (per-env). Sets SSH_PUBKEY_PATH + SSH_PRIVKEY_CONTENTS.
generate_per_env_ssh_keypair() {
    local env_id="$1" env_root="$2"
    _gen_keypair "$env_id" "${env_root}/ssh" operator SSH_PUBKEY_PATH SSH_PRIVKEY_CONTENTS
}

# AWX control-node key (per-env, ADR-0016 Path A). Always generated — it's
# internal automation identity (no bring-your-own). Sets AWX_PUBKEY_PATH +
# AWX_PRIVKEY_CONTENTS (privkey → bundle; pubkey → cloud-init via tf-apply -var).
generate_awx_control_node_keypair() {
    local env_id="$1" env_root="$2"
    _gen_keypair "$env_id" "${env_root}/ssh" awx-control-node AWX_PUBKEY_PATH AWX_PRIVKEY_CONTENTS
}

# ── Renderers ───────────────────────────────────────────────────────────────

render_sops_yaml() {
    local env_id="$1" pubkey="$2"

    # Both sandbox and cloud lanes: write a per-env .sops.yaml inside the env dir.
    # sops walks upward from the bundle file looking for .sops.yaml, so a single rule
    # that matches bundle.sops.yaml is enough — and there's no need to mutate
    # a repo-level .sops.yaml or remember to clean it up at teardown.
    local env_root="${DMF_DATA_ROOT}/envs/${env_id}"
    install -d -m 0700 "$env_root"
    local sops_file="${env_root}/.sops.yaml"
    cat > "$sops_file" <<EOF
# ${env_id} — per-env sops creation rule.
# Generated by init-wizard.sh on $(date -u +%Y-%m-%d).
# sops walks upward from the encrypted file looking for .sops.yaml; the rule
# below matches bundle.sops.yaml in the same directory.
creation_rules:
  - path_regex: '.*/bundle\.sops\.yaml\$'
    age: '${pubkey}'
EOF
    chmod 0600 "$sops_file"
    ok "wrote ${sops_file}"
}

render_bundle() {
    local env_id="$1" pubkey="$2"
    # Temp file name matters: sops matches creation_rules against the INPUT
    # filename, not the output. Both sandbox and cloud write bundle.sops.yaml
    # under the env dir so the per-env .sops.yaml (path_regex: .*/bundle\.sops\.yaml$)
    # picks it up. mktemp under the env dir so the per-env .sops.yaml is upstream of
    # the temp file on the path walk. The env dir already exists from render_sops_yaml.
    local env_root="${DMF_DATA_ROOT}/envs/${env_id}"
    local tmp_dir tmp
    tmp_dir="$(mktemp -d "${env_root}/.tmp-bundle.XXXXXX")"
    tmp="${tmp_dir}/bundle.sops.yaml"
    trap "rm -rf '$tmp_dir'" RETURN

    # Every interpolated value is double-quoted in the bundle YAML.
    # Generated passwords + operator-typed tokens may contain characters
    # YAML treats specially when unquoted (*, !, &, #, :, |, >, etc).
    # Operator-supplied tokens with embedded " would still break — none
    # of the supported providers issue tokens with " in them.
    cat > "$tmp" <<EOF
apiVersion: dmfdeploy.dev/v1alpha1
kind: BootstrapSecretBundle
metadata:
  env_id: "${env_id}"
  env_label: "${ENV_LABEL}"
  provider: "${PROVIDER}"
  architecture: "${ARCH}"
  base_domain: "${BASE_DOMAIN}"
  created_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  schema_version: 2
  last_validated_at: null
  last_seeded_to_bao_at: null
  external_sources:
    awx_control_node_ssh: dedicated-operator-bootstrap

bootstrap_admin:
  username: "${OPERATOR_USERNAME}"
  email: "${OPERATOR_EMAIL}"
  password: "${ADMIN_PASSWORD}"

cluster:
  k3s_token: "${K3S_TOKEN}"

ssh:
  # base64 (single line) — a raw multi-line PEM in a YAML scalar gets its
  # newlines folded to spaces (→ corrupt key). run-playbook.sh base64-decodes
  # this when materializing ~/.dmfdeploy/envs/<env>/ssh/operator.key at runtime.
  operator_private_key_b64: "$(printf '%s' "${SSH_PRIVKEY_CONTENTS:-}" | base64 | tr -d '\n')"
  # AWX control-node key (ADR-0016 Path A) — same base64 treatment.
  awx_control_node_private_key_b64: "$(printf '%s' "${AWX_PRIVKEY_CONTENTS:-}" | base64 | tr -d '\n')"

providers:
EOF

    case "$PROVIDER" in
        hetzner)
            cat >> "$tmp" <<EOF
  hetzner:
    context: "${HCLOUD_CONTEXT}"
    cloud_token: "${HCLOUD_TOKEN}"
EOF
            ;;
        aliyun)
            cat >> "$tmp" <<EOF
  alicloud:
    access_key: "${ALICLOUD_ACCESS_KEY}"
    secret_key: "${ALICLOUD_SECRET_KEY}"
EOF
            ;;
        aws)
            cat >> "$tmp" <<EOF
  aws:
    access_key_id: "${AWS_ACCESS_KEY_ID}"
    secret_access_key: "${AWS_SECRET_ACCESS_KEY}"
    region: "${AWS_REGION}"
EOF
            ;;
    esac

    cat >> "$tmp" <<EOF
  cloudflare:
    dns_token: "${CF_DNS_TOKEN}"
  tailscale:
    authkey: "${TS_AUTHKEY}"

notifications:
  ntfy_url: ""
  healthchecks_url: ""

apps:
  authentik:
    bootstrap_token: "${AUTHENTIK_TOKEN}"
    db_password: "${AUTHENTIK_DB_PASSWORD}"
  netbox:
    db_password: "${NETBOX_DB_PASSWORD}"
  awx:
    admin_password: "${AWX_ADMIN_PASSWORD}"
  forgejo:
    db_password: "${FORGEJO_DB_PASSWORD}"
  zot:
    admin_password: "${ZOT_ADMIN_PASSWORD}"
    service_password: "${ZOT_SERVICE_PASSWORD}"
EOF

    # Sandbox (ADR-0031 Profile 1 / WP1S) carries no object storage; emit an
    # empty map so the bundle schema validator skips the per-bucket checks.
    # Cloud providers keep the B2-backed audit / snapshot / app-backup blocks.
    if [ "$PROVIDER" = "sandbox" ]; then
        cat >> "$tmp" <<EOF

object_storage: {}
EOF
    else
        cat >> "$tmp" <<EOF

object_storage:
  audit:
    bucket: "dmf-audit-${env_id}"
    endpoint: "https://s3.${B2_REGION}.backblazeb2.com"
    region: "${B2_REGION}"
    access_key_id: "${B2_KEY_ID}"
    secret_access_key: "${B2_APP_KEY}"
  openbao_snapshots:
    bucket: "dmf-openbao-snapshots-${env_id}"
    endpoint: "https://s3.${B2_REGION}.backblazeb2.com"
    region: "${B2_REGION}"
    access_key_id: "${B2_KEY_ID}"
    secret_access_key: "${B2_APP_KEY}"
  app_backups:
    bucket: "dmf-app-backups-${env_id}"
    endpoint: "https://s3.${B2_REGION}.backblazeb2.com"
    region: "${B2_REGION}"
    access_key_id: "${B2_KEY_ID}"
    secret_access_key: "${B2_APP_KEY}"
EOF
    fi

    # Atomic write: sops streams encrypted output to <bundle>.wizard-tmp;
    # only mv onto the real bundle path after success. A failed sops thus
    # never leaves a zero-byte zombie at the bundle path.
    # Pin sops to the per-env config explicitly. Without --config, sops
    # walks upward from CWD (not from the input file path) looking for
    # .sops.yaml — and when the wizard runs from inside dmf-env, it finds
    # the repo-level config first, whose creation_rules don't match
    # bundle.sops.yaml → "no matching creation rules found".
    local bundle="${env_root}/bundle.sops.yaml"
    local sops_args=(--config "${env_root}/.sops.yaml")
    local out_tmp="${bundle}.wizard-tmp"
    # ${arr[@]+"${arr[@]}"} expands to the elements when set, else to nothing —
    # the cloud lane leaves sops_args empty, and "${sops_args[@]}" on an empty
    # array trips `set -u` on macOS bash 3.2 ("unbound variable"). The explicit
    # --age below carries the recipient, so an empty arg list is correct here.
    sops ${sops_args[@]+"${sops_args[@]}"} --encrypt \
        --age "$pubkey" \
        --input-type yaml \
        --output-type yaml \
        "$tmp" > "$out_tmp"
    chmod 0600 "$out_tmp"
    mv "$out_tmp" "$bundle"
    ok "wrote ${bundle}"
}

render_object_storage_tfvars() {
    local env_id="$1"
    local env_root="${DMF_DATA_ROOT}/envs/${env_id}"
    install -d -m 0700 "$env_root"
    local f="${env_root}/object-storage.tfvars"
    umask 077
    cat > "$f" <<EOF
object_storage_access_key_id     = "${B2_KEY_ID}"
object_storage_secret_access_key = "${B2_APP_KEY}"
EOF
    chmod 0600 "$f"
    ok "wrote ${f}"
}

render_provider_tfvars() {
    local env_id="$1"
    local env_root="${DMF_DATA_ROOT}/envs/${env_id}"
    install -d -m 0700 "$env_root"
    umask 077
    case "$PROVIDER" in
        hetzner)
            local f="${env_root}/hetzner.tfvars"
            cat > "$f" <<EOF
hcloud_token         = "${HCLOUD_TOKEN}"
cloudflare_api_token = "${CF_DNS_TOKEN}"
EOF
            chmod 0600 "$f"
            ok "wrote ${f}"
            ;;
        aliyun)
            local f="${env_root}/aliyun.tfvars"
            cat > "$f" <<EOF
alicloud_access_key  = "${ALICLOUD_ACCESS_KEY}"
alicloud_secret_key  = "${ALICLOUD_SECRET_KEY}"
cloudflare_api_token = "${CF_DNS_TOKEN}"
EOF
            chmod 0600 "$f"
            ok "wrote ${f}"
            ;;
        aws)
            local f="${env_root}/aws.tfvars"
            cat > "$f" <<EOF
aws_access_key_id     = "${AWS_ACCESS_KEY_ID}"
aws_secret_access_key = "${AWS_SECRET_ACCESS_KEY}"
aws_region            = "${AWS_REGION}"
cloudflare_api_token  = "${CF_DNS_TOKEN}"
EOF
            chmod 0600 "$f"
            ok "wrote ${f} (stub — AWS Terraform root module not yet scaffolded)"
            ;;
    esac
}

render_manifest() {
    local env_id="$1"
    local f
    if [ "$PROVIDER" = "sandbox" ]; then
        f="${DMF_DATA_ROOT}/envs/${env_id}/manifest.yaml"
        render_manifest_sandbox "${env_id}" "${f}"
        return 0
    fi
    f="${DMF_DATA_ROOT}/envs/${env_id}/manifest.yaml"
    install -d -m 0700 "${DMF_DATA_ROOT}/envs/${env_id}"
    local cpu_cores mem_gb cluster_size disk_gb private_cidr provider_human server_type provider_region private_iface
    case "$PROVIDER" in
        hetzner)
            provider_human="Hetzner"
            cluster_size=3
            disk_gb=80
            private_cidr="10.0.0.0/28"
            provider_region="nbg1"
            private_iface="enp7s0"
            if [ "$ARCH" = "arm64" ]; then
                cpu_cores=4
                mem_gb=8
                server_type="cax21"
            else
                cpu_cores=4
                mem_gb=8
                server_type="cpx31"
            fi
            ;;
        aliyun)
            provider_human="Aliyun"
            cpu_cores=2
            mem_gb=8
            cluster_size=3
            disk_gb=80
            private_cidr="10.0.0.0/24"
            provider_region="eu-central-1"
            private_iface="eth1"
            server_type="ecs.g8y.large"
            ;;
        aws)
            provider_human="AWS"
            cpu_cores=2
            mem_gb=8
            cluster_size=3
            disk_gb=80
            private_cidr="10.0.0.0/24"
            provider_region="eu-central-1"
            private_iface="eth1"
            server_type="t4g.large"
            ;;
    esac

    # Description is structured: provider/arch first, label-or-id last so
    # the prose is readable without re-deriving meaning from the slug.
    local descr_tail="${env_id}"
    [ -n "${ENV_LABEL}" ] && descr_tail="${ENV_LABEL} (${env_id})"
    local node1="${env_id}-node-01"
    local node2="${env_id}-node-02"
    local node3="${env_id}-node-03"
    local private_network="${env_id}-private"
    local lb_name="${env_id}-traefik"
    local provider_cloud_extra=""
    if [ "$PROVIDER" = "hetzner" ]; then
        provider_cloud_extra="$(cat <<EOF
      ssh_key_name: ${HCLOUD_SSH_KEY_NAME}
      firewall_name: ${env_id}-k3s-nodes
      server_label_cluster: ${env_id}
      load_balancer:
        name: ${lb_name}
EOF
)"
    fi

    local ssh_allow_ipv4_yaml ssh_allow_ipv6_yaml
    ssh_allow_ipv4_yaml="$(yaml_string_list "${SSH_ALLOW_IPV4:-}")"
    ssh_allow_ipv6_yaml="$(yaml_string_list "${SSH_ALLOW_IPV6:-}")"

    cat > "$f" <<EOF
---
# ${env_id} — Resource Profile
# Generated by init-wizard.sh on $(date -u +%Y-%m-%d).
# Edit before \`tofu apply\` if any of the defaults below don't match the
# operator's intent.

apiVersion: dmf.${BASE_DOMAIN}/v1alpha1
kind: ResourceProfile
metadata:
  name: ${env_id}
  label: "${ENV_LABEL}"
  provider: ${PROVIDER}
  architecture: ${ARCH}
  lane: cloud
  description: ${provider_human} ${ARCH} 3-node k3s cluster — ${descr_tail}
  created: $(date -u +%Y-%m-%d)
  manifest_version: 0.2.0

spec:
  provider: ${PROVIDER}
  architecture: ${ARCH}
  resource_profile:
    cluster_size: ${cluster_size}
    per_host:
      cpu:
        kind: ${ARCH}
        cores: ${cpu_cores}
      memory_gb: ${mem_gb}
      storage:
        - { kind: cloud_ssd, size_gb: ${disk_gb}, role: boot+container }
      network:
        - { kind: ethernet, bandwidth_gbps: 1, role: public }
        - { kind: ethernet, bandwidth_gbps: 1, role: private, cidr: ${private_cidr} }
      gpu: null
    timing_reference: null
    scaling:
      mode: fixed

  topology:
    profile: hub-cluster-first
    kubernetes_distribution: k3s
    environment_name: ${env_id}
    control_plane:
      ha: true
      members: [${node1}, ${node2}, ${node3}]
      bootstrap_node: ${node1}
    workers: []
    os: debian-12
    private_interface: ${private_iface}
    admin_user: k3s-admin

  provider:
    cloud:
      kind: ${PROVIDER}
      server_type: ${server_type}
      region: ${provider_region}
      private_network: ${private_network}
      private_cidr: ${private_cidr}
${provider_cloud_extra}
      tokens:
        cloud_api: "openbao:secret/k3s-${env_id}/credentials#cloud_token"
        dns_api: "openbao:secret/k3s-${env_id}/credentials#cloudflare_dns_token"

  ingress:
    mode: cloud-native
    external_base_url: https://${BASE_DOMAIN}

  domain:
    cluster_domain: ${BASE_DOMAIN}
    public_base_url: https://${BASE_DOMAIN}
    tls:
      mode: dns-01-wildcard
      provider: cloudflare
      issuer: letsencrypt-dns
      acme_email: ${OPERATOR_EMAIL}
      cloudflare_zone: ${CF_ZONE_NAME}
      sans:
        - "*.${BASE_DOMAIN}"
        - "${BASE_DOMAIN}"
    hosts:
      authentik: auth.${BASE_DOMAIN}
      forgejo: forgejo.${BASE_DOMAIN}
      grafana: grafana.${BASE_DOMAIN}
      console: console.${BASE_DOMAIN}
      netbox: netbox.${BASE_DOMAIN}
      awx: awx.${BASE_DOMAIN}
      registry: registry.${BASE_DOMAIN}

  network:
    ingress_model: public-plus-private
    public_lane:
      enabled: true
      hosts: [auth.${BASE_DOMAIN}, ${BASE_DOMAIN}]
      provider: ${PROVIDER}-ccm
    private_lane:
      enabled: true
      provider: tailscale
      headscale_url: ${HEADSCALE_HOST:+https://${HEADSCALE_HOST}}
      endpoint_node: any
      hosts:
        - forgejo.${BASE_DOMAIN}
        - grafana.${BASE_DOMAIN}
        - console.${BASE_DOMAIN}
        - netbox.${BASE_DOMAIN}
        - awx.${BASE_DOMAIN}
        - registry.${BASE_DOMAIN}
    ssh_allow_ipv4: ${ssh_allow_ipv4_yaml}
    ssh_allow_ipv6: ${ssh_allow_ipv6_yaml}

  object_storage:
    audit:
      bucket: dmf-audit-${env_id}
      endpoint: https://s3.${B2_REGION}.backblazeb2.com
      region: ${B2_REGION}
    openbao_snapshots:
      bucket: dmf-openbao-snapshots-${env_id}
      endpoint: https://s3.${B2_REGION}.backblazeb2.com
      region: ${B2_REGION}
    app_backups:
      bucket: dmf-app-backups-${env_id}
      endpoint: https://s3.${B2_REGION}.backblazeb2.com
      region: ${B2_REGION}
EOF
    ok "wrote ${f}"
}

render_inventory_main() {
    local env_id="$1"
    local env_root="${DMF_DATA_ROOT}/envs/${env_id}"
    local dir="${env_root}/inventory/group_vars/all"
    install -d -m 0755 "$dir"
    local f="${dir}/main.yml"

    local private_iface="eth1"
    [ "$PROVIDER" = "hetzner" ] && private_iface="enp7s0"
    local private_cidr="10.0.0.0/24"
    [ "$PROVIDER" = "hetzner" ] && private_cidr="10.0.0.0/28"
    local ssh_allow_ipv4_yaml ssh_allow_ipv6_yaml
    ssh_allow_ipv4_yaml="$(yaml_string_list "${SSH_ALLOW_IPV4:-}")"
    ssh_allow_ipv6_yaml="$(yaml_string_list "${SSH_ALLOW_IPV6:-}")"

    local label_comment="${ENV_LABEL:-<none>}"
    local control_node="${env_id}-node-01"

    cat > "$f" <<EOF
---
# ${env_id} site-specific variables (rendered by init-wizard.sh).
# Label: ${label_comment}
# Operator-tunable; secrets are exported from OpenBao at runtime by
# bin/run-playbook.sh.

# --- Env schema (consumed by dmf-born-inventory → NetBox) ---
dmf_env_id: "${env_id}"
dmf_env_label: "${ENV_LABEL}"
dmf_provider: "${PROVIDER}"
dmf_architecture: "${ARCH}"
hcloud_context: "${HCLOUD_CONTEXT}"
EOF

    if [ "$PROVIDER" = "hetzner" ]; then
        cat >> "$f" <<EOF
hcloud_ssh_key_name: "${HCLOUD_SSH_KEY_NAME}"
hcloud_load_balancer_name: "${env_id}-traefik"
EOF
    fi

    cat >> "$f" <<EOF

# --- Network ---
k3s_private_interface: ${private_iface}
k3s_flannel_iface: "{{ k3s_private_interface }}"
k3s_advertise_address: "{{ k3s_node_ip }}"
k3s_node_external_ip: "{{ ansible_host }}"
k3s_server_disable_cloud_controller: true
EOF

    if [ "$PROVIDER" = "hetzner" ]; then
        cat >> "$f" <<EOF
k3s_kubelet_args:
  - cloud-provider=external
k3s_server_tls_sans:
  - "{{ hostvars[k3s_control_node].k3s_node_ip }}"
  - "{{ hostvars[k3s_control_node].ansible_host }}"

# --- Hetzner cloud-native ingress ---
cluster_ingress_mode: cloud-native
cluster_ingress_provider_tasks: "{{ inventory_dir }}/../../tasks/hetzner/ccm.yml"
cluster_ingress_external_traffic_policy: Cluster
cluster_ingress_service_annotations:
  load-balancer.hetzner.cloud/name: "{{ hcloud_load_balancer_name }}"
  load-balancer.hetzner.cloud/location: nbg1
  load-balancer.hetzner.cloud/use-private-ip: "true"
hcloud_ccm_network: ${env_id}-private
EOF
    fi

    cat >> "$f" <<EOF

# --- Apex / hostnames ---
external_base_url: "https://${BASE_DOMAIN}"

authentik_host: auth.${BASE_DOMAIN}
forgejo_host: forgejo.${BASE_DOMAIN}
grafana_host: grafana.${BASE_DOMAIN}
dmf_cms_host: console.${BASE_DOMAIN}
netbox_host: netbox.${BASE_DOMAIN}
awx_host: awx.${BASE_DOMAIN}
registry_host: registry.${BASE_DOMAIN}

# --- cert-manager ---
cert_manager_cluster_domain: ${BASE_DOMAIN}
cert_manager_cluster_issuer: letsencrypt-dns
cert_manager_acme_email: ${OPERATOR_EMAIL}
cert_manager_dns_provider: cloudflare
cert_manager_dns_names:
  - "*.{{ cert_manager_cluster_domain }}"
  - "{{ cert_manager_cluster_domain }}"

# --- Identity (operator passkey for Authentik bootstrap) ---
authentik_bootstrap_passkey_username: ${OPERATOR_USERNAME}
authentik_bootstrap_passkey_email: ${OPERATOR_EMAIL}
authentik_bootstrap_passkey_name: ${OPERATOR_DISPLAY}

# --- DMF push-notification channel ---
# Single per-env ntfy topic, auto-constructed from dmf_env_id + operator
# username. Consumed by Authentik (passkey enrollment URL) and Prometheus
# Alertmanager (alerts). Subscribe on your phone:
#   https://ntfy.sh/dmf-${env_id}-${OPERATOR_USERNAME}
dmf_ntfy_url: "https://ntfy.sh/dmf-${env_id}-${OPERATOR_USERNAME}"

# --- Workstation paths (operator-specific; not in dmf-infra defaults) ---
ssh_pubkey_path: ${env_root}/ssh/operator.pub

# --- DNS / Cloudflare ---
cloudflare_zone_name: ${CF_ZONE_NAME}
EOF

    if [ -n "${HEADSCALE_HOST}" ]; then
        cat >> "$f" <<EOF
headscale_ssh_target: "root@${HEADSCALE_HOST}"
EOF
    fi

    cat >> "$f" <<EOF

# --- Hardening ---
harden_admin_user: k3s-admin
harden_admin_pubkey: "{{ lookup('file', '${env_root}/ssh/operator.pub') }}"
ansible_ssh_private_key_file: "${env_root}/ssh/operator.key"
harden_ssh_allow_ipv4: ${ssh_allow_ipv4_yaml}
harden_ssh_allow_ipv6: ${ssh_allow_ipv6_yaml}
harden_private_cidr: "${private_cidr}"

# --- Kubernetes ---
k3s_control_node: ${control_node}
k3s_token: "{{ vault_k3s_token }}"

# --- Posture: ${POSTURE} ---
# Drives resource sizing below. Selected at wizard time. The
# bin/init-wizard.sh POSTURE case-statement is the canonical mapping:
#   test       → 5Gi Prometheus / 2GB retention / 2 Longhorn replicas /
#                Alertmanager off. Targets CAX21-class nodes
#                (${POSTURE_MIN_NODE_RAM_GB} GB RAM, ${POSTURE_MIN_NODE_DISK_GB} GB disk).
#   production → 50Gi Prometheus / 40GB retention / 3 Longhorn replicas /
#                Alertmanager on (requires ntfy + watchdog URLs in OpenBao).
#                Targets CAX31+ / dedicated-storage nodes.
# To change posture for this env, edit the four posture-driven values
# below by hand AND raise node sizing if moving test → production.

# --- Storage ---
longhorn_default_replica_count: ${POSTURE_LONGHORN_REPLICA_COUNT}

# --- Monitoring ---
# When enabled, base/prometheus role asserts that ntfy + watchdog receiver
# URLs are set; provide vault_alertmanager_ntfy_url +
# vault_alertmanager_watchdog_url (via OpenBao seed-bao) before enabling.
prometheus_alertmanager_enabled: ${POSTURE_PROMETHEUS_ALERTMANAGER_ENABLED}

# Prometheus PVC + retention. The dmf-infra CLAUDE.md has WAL sizing
# guidance — TL;DR retention_size controls TSDB blocks only; the WAL
# needs ~300 MB extra headroom beyond your retention number, so a 2GB
# retention wants ~5Gi PVC, a 40GB retention wants ~50Gi PVC, etc.
prometheus_storage_size: ${POSTURE_PROMETHEUS_STORAGE_SIZE}
prometheus_retention_size: ${POSTURE_PROMETHEUS_RETENTION_SIZE}

# Loki PVC. Same posture-mapping shape as Prometheus — role default is
# 50Gi (production-shaped) and Longhorn faults the volume on small-disk
# nodes when two replicas can't fit.
loki_storage_size: ${POSTURE_LOKI_STORAGE_SIZE}

# --- Registry ---
# Zot PVC. Role default is 20Gi (production-shaped). Test posture
# shrinks to 15Gi — comfortable headroom over today's DMF image set
# (awx-ee, dmf-cms, nmos-cpp-{registry,node} ~2GB total) and several
# version iterations. If you adopt Zot as a cluster-wide pull-through
# cache for upstream Helm-chart images, expect 40-60Gi target sizing —
# see docs/plans/DMF Zot Cluster-Wide Pull-Through Cache Plan.
# Raising in place requires \`helm uninstall zot\` + PVC delete +
# redeploy; k8s/Longhorn don't shrink PVCs.
zot_storage_size: ${POSTURE_ZOT_STORAGE_SIZE}

# --- AWX integration (Path A — ADR-0016) ---
# AWX uses this privkey to SSH into the control node. Generated per-env by the
# wizard; the privkey lives in the sops bundle and run-playbook.sh materializes
# it to this 0600 path at run time.
awx_control_node_ssh_privkey_path: ${env_root}/ssh/awx-control-node.key
EOF
    ok "wrote ${f}"
}

render_inventory_tailscale() {
    local env_id="$1"
    local env_root="${DMF_DATA_ROOT}/envs/${env_id}"
    # Skip silently when the operator opted out of Tailscale at prompt time
    # (descriptor declares optional: true; absence of an authkey is the
    # documented "skip" signal).
    [ -z "${TS_AUTHKEY}" ] && return 0

    local descriptor="${REPO_DIR}/../dmf-infra/k3s-lab-bootstrap/providers/tailscale.yaml"
    [ -r "$descriptor" ] || die "tailscale descriptor not found at ${descriptor}"

    # Build the inputs JSON from collected wizard state.
    # - headscale_url is required by the descriptor; if HEADSCALE_HOST is
    #   empty the renderer will surface a clean error rather than us
    #   silently skipping (operator gave us an authkey but no control
    #   plane to register against — that's a wizard input bug worth
    #   surfacing).
    # - hostname / accept_routes / advertise_exit_node / ephemeral are
    #   intentionally omitted so the descriptor's own defaults apply
    #   (hostname → "{{ inventory_hostname }}" Jinja literal, the rest
    #   match the provider descriptor's own defaults).
    local inputs_json
    if [ -n "${HEADSCALE_HOST}" ]; then
        inputs_json="$(printf '{"headscale_url": "https://%s"}' "${HEADSCALE_HOST}")"
    else
        inputs_json='{}'
    fi

    "$SCRIPT_DIR/lib/render-provider-descriptor.py" \
        "$descriptor" \
        "${env_root}/inventory" <<< "$inputs_json"
    ok "wrote ${env_root}/inventory/group_vars/all/tailscale.yml"
}

render_inventory_openbao_secrets() {
    local env_id="$1"
    local env_root="${DMF_DATA_ROOT}/envs/${env_id}"
    local dir="${env_root}/inventory/group_vars/all"
    local f="${dir}/openbao_secrets.yml"
    install -d -m 0755 "$dir"
    cat > "$f" <<EOF
---
# Per-env OpenBao break-glass storage paths.
# These point at LOCAL paths on the operator's workstation. Override
# per-env so a fresh init does not silently overwrite another env's
# shares.

openbao_key_path: ${OPENBAO_BREAKGLASS_DIR}/${env_id}/openbao-keys-automation

# JuiceFS mount root — the parent of the break-glass directory. The
# stack/operator/openbao role asserts this path exists locally before
# OpenBao init writes Shamir shares 1 and 2 under it. Role default is
# Linux-flavoured (/mnt/secure); wizard-generated envs on macOS need
# this override. Derived from the break-glass dir the operator entered
# above, so a layout of <juicefs-root>/openbao-breakglass/<env_id>/...
# yields the right mount path automatically.
openbao_juicefs_mount_path: $(dirname "${OPENBAO_BREAKGLASS_DIR}")

# ESO reads this path on the operator workstation to fetch the OpenBao
# AppRole role_id/secret_id at runtime (see playbooks/vertical-orchestration/100-eso.yml).
# The role's stat assert in base/external-secrets uses this var; without
# the override the lookup falls through to a path the role default can't
# resolve and ESO fails to install.
eso_openbao_breakglass_file: ${OPENBAO_BREAKGLASS_DIR}/${env_id}/openbao-keys-automation.json

# Per-environment Keychain service for share 3.
openbao_keychain_share3_service: openbao-breakglass-share-3-${env_id}

# Per-environment USB share directory.
openbao_usb_dir: ${OPENBAO_USB_BASE}/${env_id}
EOF
    ok "wrote ${f}"
}

# render_manifest_sandbox — single-node ARM64 Debian ResourceProfile for the
# sandbox-single-node release profile (ADR-0031 Profile 1 / WP1S). Local-path
# storage, local-CA TLS, k3s ServiceLB ingress; no cloud provider, object
# storage, or overlay mesh. Layer-1 Terraform does not apply to this lane.
render_manifest_sandbox() {
    local env_id="$1" f="$2"
    local descr_tail="${env_id}"
    [ -n "${ENV_LABEL}" ] && descr_tail="${ENV_LABEL} (${env_id})"
    cat > "$f" <<EOF
---
# ${env_id} — Resource Profile (sandbox-single-node)
# Generated by init-wizard.sh on $(date -u +%Y-%m-%d).
# One ARM64 Debian node: local-path storage, local-CA TLS, k3s ServiceLB
# ingress on 80/443. No cloud provider, object storage, or overlay mesh
# (ADR-0031 Profile 1 / WP1S). Layer-1 Terraform does not apply to this lane;
# the node is bound VPS-style over SSH via the per-env inventory at
# ~/.dmfdeploy/envs/${env_id}/inventory/hosts.ini.

apiVersion: dmf.${BASE_DOMAIN}/v1alpha1
kind: ResourceProfile
metadata:
  name: ${env_id}
  label: "${ENV_LABEL}"
  provider: sandbox
  architecture: ${ARCH}
  lane: sandbox
  description: Sandbox (generic ARM64 Debian) single-node k3s — ${descr_tail}
  created: $(date -u +%Y-%m-%d)
  manifest_version: 0.2.0

spec:
  provider: sandbox
  architecture: ${ARCH}
  release_profile: sandbox-single-node
  resource_profile:
    cluster_size: 1
    per_host:
      cpu:
        kind: ${ARCH}
        cores: 4
      memory_gb: 10
      storage:
        - { kind: local_path, size_gb: 60, role: boot+container }
      network:
        - { kind: ethernet, bandwidth_gbps: 1, role: public }
      gpu: null
    timing_reference: null
    scaling:
      mode: fixed

  topology:
    profile: single-node
    kubernetes_distribution: k3s
    environment_name: ${env_id}
    control_plane:
      ha: false
      members: [${env_id}-01]
      bootstrap_node: ${env_id}-01
    workers: []
    os: debian-12
    admin_user: ${ANSIBLE_USER}

  provider:
    sandbox:
      kind: sandbox
      node_address: ${SANDBOX_NODE_IP}
      network_interface: ${SANDBOX_IFACE}

  ingress:
    mode: single-node-servicelb
    ingress_class: traefik
    external_base_url: https://${BASE_DOMAIN}

  domain:
    cluster_domain: ${BASE_DOMAIN}
    public_base_url: https://${BASE_DOMAIN}
    tls:
      mode: local-ca
      issuer: sandbox-ca
      sans:
        - "*.${BASE_DOMAIN}"
        - "${BASE_DOMAIN}"
    hosts:
      authentik: auth.${BASE_DOMAIN}
      forgejo: forgejo.${BASE_DOMAIN}
      grafana: grafana.${BASE_DOMAIN}
      console: console.${BASE_DOMAIN}
      netbox: netbox.${BASE_DOMAIN}
      awx: awx.${BASE_DOMAIN}
      registry: registry.${BASE_DOMAIN}

  network:
    ingress_model: single-node
    # Collapsed ingress: one local lane on the bundled k3s Traefik. No
    # traefik-private / Tailscale on a single node — every app host is served
    # by the same ServiceLB-fronted Traefik with the local-CA default cert.
    local_lane:
      enabled: true
      ingress_class: traefik
      provider: k3s-servicelb
      hosts:
        - ${BASE_DOMAIN}
        - auth.${BASE_DOMAIN}
        - forgejo.${BASE_DOMAIN}
        - grafana.${BASE_DOMAIN}
        - console.${BASE_DOMAIN}
        - netbox.${BASE_DOMAIN}
        - awx.${BASE_DOMAIN}
        - registry.${BASE_DOMAIN}

  object_storage: {}
EOF
    ok "wrote ${f}"
}

# render_sandbox_inventory — writes the single-node inventory for a sandbox env
# under ~/.dmfdeploy/envs/<env>/inventory/: hosts.ini plus group_vars/all/main.yml
# replicated from the dmf-sandbox reference profile with env identity, node
# connection, base domain, and OpenBao key path substituted. No openbao_secrets.yml
# (sandbox Tier-3 unseal keeps its key path in main.yml; no JuiceFS/Keychain/USB).
# The entire env dir is operator-private (0700); inventory is not committed to
# any repo — teardown is a single `rm -rf ~/.dmfdeploy/envs/<env>`.
render_sandbox_inventory() {
    local env_id="$1"
    local inv_dir="${DMF_DATA_ROOT}/envs/${env_id}/inventory"
    local gv_dir="${inv_dir}/group_vars/all"
    install -d -m 0700 "${DMF_DATA_ROOT}/envs/${env_id}"
    install -d -m 0755 "$gv_dir"

    local hosts="${inv_dir}/hosts.ini"
    cat > "$hosts" <<EOF
# ${env_id} sandbox — single ARM64 Debian node (WP1S).
# Generated by init-wizard.sh on $(date -u +%Y-%m-%d).
#
# Provider-agnostic: the same lane runs on bare metal, a cloud VPS, or a local
# VM — only ansible_host / k3s_node_ip / k3s_private_interface differ. The node
# has one routable identity, so ansible_host == k3s_node_ip.
#
# NOTE: if the node IP is DHCP-assigned, pin it (reservation) or update here.

[k3s]
${env_id}-01 ansible_host=${SANDBOX_NODE_IP} k3s_node_ip=${SANDBOX_NODE_IP} ansible_user=${ANSIBLE_USER}

# Single-node: the one node bootstraps the cluster (--cluster-init) and is the
# sole control-plane/etcd member.
[k3s_control]
${env_id}-01
EOF
    ok "wrote ${hosts}"

    local f="${gv_dir}/main.yml"
    cat > "$f" <<EOF
---
# ${env_id} sandbox — single-node Debian 12 reference deploy (WP1S).
#
# Generated by init-wizard.sh on $(date -u +%Y-%m-%d) from the dmf-sandbox
# reference profile.
#
# This inventory carries the sandbox-single-node capability variables directly
# (rather than relying on the bootstrap-sandbox-profile.yml prelude) so that
# individual atomic playbooks run against it behave correctly even when invoked
# outside the sandbox wrappers — e.g. the Layer 2/3 first-acceptance path.

# --- Env schema (consumed by dmf-born-inventory → NetBox; cosmetic for the
#     secret-free first-acceptance path) ---
dmf_env_id: "${env_id}"
dmf_env_label: "${ENV_LABEL}"
dmf_provider: "sandbox"          # generic SSH host; not a cloud provider
dmf_architecture: "${ARCH}"

# --- Connection (VPS-style: plain SSH to the routable IP) ---
# UserKnownHostsFile=/dev/null because a disposable sandbox's host key may churn
# on rebuild; StrictHostKeyChecking=no avoids the prompt for this throwaway env.
ansible_user: ${ANSIBLE_USER}
# The node OS admin/login user (= ansible_user). 210-harden connects as this
# (no root SSH on the sandbox) and keeps it in sshd AllowUsers + sudoers.
harden_admin_user: ${ANSIBLE_USER}
# Allow SSH from anywhere on the hardened nftables public chain (key-only auth +
# fail2ban + sshd AllowUsers still apply). Without this the harden role drops
# port 22 and locks out the sandbox's LAN SSH. Tighten to your LAN/mgmt CIDR for
# a stricter posture.
harden_ssh_allow_ipv4: ['0.0.0.0/0']
# Hardened nftables must accept the k3s pod+service CIDRs (k3s defaults
# 10.42.0.0/16 + 10.43.0.0/16, covered by 10.42.0.0/15) so pods can reach the
# node API (6443)/kubelet — else CoreDNS + cluster networking break. The role
# default (10.0.0.0/28, a cloud node net) doesn't cover them on a single node.
harden_private_cidr: "10.42.0.0/15"
ansible_ssh_private_key_file: "${SSH_PRIVKEY_PATH}"
ansible_ssh_common_args: "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
ansible_python_interpreter: /usr/bin/python3
# AWX→control-node key (ADR-0016 Path A) — generated per-env; privkey lives in
# the sops bundle and is materialized to this 0600 path at run time by
# run-playbook.sh. No hardcoded/operator-specific path.
awx_control_node_ssh_privkey_path: ${DMF_DATA_ROOT}/envs/${env_id}/ssh/awx-control-node.key

# --- Cluster basics ---
k3s_control_node: ${env_id}-01
# Mapped from OpenBao: seed-bao writes the bundle's cluster.k3s_token, then
# run-playbook.sh export-vars emits vault_k3s_token, which 300-k3s consumes
# here as k3s_token.
k3s_token: "{{ vault_k3s_token }}"

# K3s networking. The routable interface is this host's primary NIC and the
# default route, so it is the cluster's single routable identity. (On Hetzner
# this field is enp7s0; on bare metal it is whatever the box names its NIC.)
k3s_private_interface: ${SANDBOX_IFACE}
k3s_flannel_iface: "{{ k3s_private_interface }}"
k3s_advertise_address: "{{ k3s_node_ip }}"
k3s_node_external_ip: "{{ k3s_node_ip }}"
k3s_server_disable_cloud_controller: false

# --- sandbox-single-node release profile capabilities ---
dmf_release_profile: sandbox-single-node
dmf_storage_backend: local-path
dmf_storage_class: local-path
# local-path is RWO-only: the NetBox media PVC must be ReadWriteOnce on the single
# node. The sandbox profile prelude (bootstrap-sandbox-profile.yml) also sets this,
# but rendering it into the inventory keeps a STANDALONE 610-netbox run correct too
# (the role default is ReadWriteMany → Helm immutable-PVC patch failure).
netbox_media_access_mode: ReadWriteOnce
dmf_ingress_mode: single-node-servicelb
dmf_tls_mode: local-ca
dmf_object_storage_enabled: false
dmf_headscale_enabled: false
dmf_tailscale_enabled: false
dmf_monitoring_profile: minimal
dmf_awx_profile: single-node-low-concurrency
dmf_sandbox_base_domain: ${BASE_DOMAIN}

# Sandbox-fit monitoring sizing (60 GiB / 4 CPU / 10 GiB Lima VM).
# Role defaults are cloud-shaped (Prom 50Gi/30d/40GB, Loki 50Gi/30d) and
# wedge a single-node disk. Sized to a reference single-node cluster + a
# generous 7d operator retention; total monitoring PVCs ≈ 11 GiB (Prom 5 +
# Loki 5 + Grafana 1). Audit headroom with df -h on the node before raising.
# Rendered into the inventory (not just the bootstrap-sandbox-profile prelude)
# so a STANDALONE re-run of a single monitoring play stays sandbox-fit too
# (same hygiene as netbox_media_access_mode above).
prometheus_storage_size: 5Gi
prometheus_retention: 7d
prometheus_retention_size: 4GB
loki_storage_size: 5Gi
loki_retention: 168h          # 7 days
loki_security_retention: 168h  # 7 days (no separate security stream on sandbox)
# Grafana PVC stays at the role default 1Gi (already sandbox-fit).
# Alertmanager off on sandbox — the role asserts ntfy + watchdog receiver
# URLs when enabled, and an experiment-phase sandbox has neither. Set
# vault_alertmanager_ntfy_url + vault_alertmanager_watchdog_url in OpenBao
# and flip this back to true to turn alerting on.
prometheus_alertmanager_enabled: false

# Ingress: keep k3s ServiceLB (klipper) and let it bind 80/443 on the single
# node. No MetalLB on a one-node sandbox.
cluster_ingress_mode: single-node-servicelb
cluster_ingress_provider_tasks: ""
cluster_ingress_external_traffic_policy: Cluster

# Storage / readiness: local-path only; no Longhorn to wait on.
cluster_ready_wait_for_longhorn: false
cluster_ready_wait_for_storageclass: false

# TLS / external entry. The stable external entry point is the HTTPS base domain
# (served by the collapsed single Traefik with the local-CA default cert), NOT
# the raw node IP — apps derive their scheme from external_base_url, so this must
# be https in local-ca mode. The node's routable IP lives in hosts.ini
# (k3s_node_ip) for ServiceLB / CoreDNS / the /etc/hosts mapping.
external_base_url: "https://{{ dmf_sandbox_base_domain }}"
cert_manager_cluster_domain: "{{ dmf_sandbox_base_domain }}"

# Collapsed ingress (single-node, no traefik-private / Tailscale): every
# host-based app routes through the bundled k3s Traefik (IngressClass 'traefik').
forgejo_ingress_class_name: traefik
netbox_ingress_class: traefik
awx_ingress_class: traefik
cms_ingress_class: traefik
grafana_ingress_class: traefik

# Per-app hostnames (consumed by the app + configure/OIDC playbooks). Local-only
# under the sandbox base domain — reach them via the node IP + a hosts mapping.
authentik_host: auth.${BASE_DOMAIN}
forgejo_host: forgejo.${BASE_DOMAIN}
grafana_host: grafana.${BASE_DOMAIN}
dmf_cms_host: console.${BASE_DOMAIN}
netbox_host: netbox.${BASE_DOMAIN}
awx_host: awx.${BASE_DOMAIN}
registry_host: registry.${BASE_DOMAIN}

# --- Identity (operator passkey for Authentik bootstrap) ---
# Collected in the operator prompts (same as the cloud path). Without these the
# bootstrap blueprint falls back to the placeholder "operator" user, so the
# enrollment flow's identification stage rejects the operator's real username.
authentik_bootstrap_passkey_username: ${OPERATOR_USERNAME}
authentik_bootstrap_passkey_email: ${OPERATOR_EMAIL}
authentik_bootstrap_passkey_name: ${OPERATOR_DISPLAY}

# --- OpenBao: sandbox Tier-3 self-recovering unseal (ADR-0031 O4 / Profile 1) ---
# No operator-Mac / JuiceFS / Keychain / USB break-glass distribution. A single
# Shamir share with the fresh-init automation file as the only key custody,
# written locally under ~/.dmfdeploy/envs/<env>/ (created if absent by the
# role's localhost file task). Reset == re-init; this is a disposable sandbox,
# not production.
openbao_breakglass_distribution_enabled: false
openbao_shamir_shares: 1
openbao_shamir_threshold: 1
openbao_key_path: "${DMF_DATA_ROOT}/envs/${env_id}/openbao-keys"
# ESO loads the OpenBao AppRole creds from the fresh-init automation/break-glass
# JSON the openbao role writes at <openbao_key_path>.json (vertical-orchestration/100-eso.yml).
eso_openbao_breakglass_file: "${DMF_DATA_ROOT}/envs/${env_id}/openbao-keys.json"
EOF
    ok "wrote ${f}"
}

# ── Main ────────────────────────────────────────────────────────────────────

render_tail() {
    local pubkey="${AGE_PUBLIC_KEY:-}"
    [ -n "$pubkey" ] || pubkey="$(check_age_key)"

    section "Auto-generating passwords + tokens"
    ADMIN_PASSWORD="$(gen_password 32)";        ok "bootstrap_admin password (32ch)"
    K3S_TOKEN="$(gen_token 48)";                ok "k3s cluster token (48ch)"
    AUTHENTIK_TOKEN="$(gen_token 60)";          ok "authentik bootstrap API token (60ch)"
    AUTHENTIK_DB_PASSWORD="$(gen_password 32)"; ok "authentik DB password"
    NETBOX_DB_PASSWORD="$(gen_password 32)";    ok "netbox DB password"
    AWX_ADMIN_PASSWORD="$(gen_password 32)";    ok "awx admin password"
    FORGEJO_DB_PASSWORD="$(gen_password 32)";   ok "forgejo DB password"
    ZOT_ADMIN_PASSWORD="$(gen_password 32)";    ok "zot admin password (break-glass)"
    ZOT_SERVICE_PASSWORD="$(gen_password 32)";  ok "zot-svc machine-write password (ADR-0033)"

    section "Summary (no secrets shown)"
    if [ "$PROVIDER" = "sandbox" ]; then
        cat >&2 <<EOF
  env_id:          ${ENV_ID}      ${CLR_DIM}(opaque slug — the only path identifier)${CLR_RESET}
  env_label:       ${ENV_LABEL}      ${CLR_DIM}(= sandbox subdomain label)${CLR_RESET}
  profile:         sandbox-single-node      ${CLR_DIM}(ADR-0031 Profile 1 / WP1S)${CLR_RESET}
  provider:        ${PROVIDER}
  architecture:    ${ARCH}
  base_domain:     ${BASE_DOMAIN}      ${CLR_DIM}(sslip.io auto-DNS; .dmf.test for air-gapped)${CLR_RESET}
  operator:        ${OPERATOR_USERNAME} <${OPERATOR_EMAIL}>
  node:            ${SANDBOX_NODE_IP}      ${CLR_DIM}(ansible_user=${ANSIBLE_USER}, iface=${SANDBOX_IFACE})${CLR_RESET}
  ssh privkey:     ${SSH_PRIVKEY_PATH}
  openbao:         local Tier-3 unseal (Shamir 1/1; no JuiceFS/Keychain/USB)
  env root:        ${ENV_ROOT}/      ${CLR_DIM}(teardown: rm -rf this)${CLR_RESET}
  bundle:          ${BUNDLE_FILE}
  manifest:        ${MANIFEST_FILE}
  inventory:       ${INVENTORY_DISPLAY}
  sops.yaml:       ${SOPS_FILE}
EOF
    else
        cat >&2 <<EOF
  env_id:          ${ENV_ID}      ${CLR_DIM}(opaque slug — the only path identifier)${CLR_RESET}
  env_label:       ${ENV_LABEL:-<none>}      ${CLR_DIM}(display-only; not used in any path)${CLR_RESET}
  posture:         ${POSTURE}      ${CLR_DIM}(min ${POSTURE_MIN_NODE_RAM_GB} GB RAM / ${POSTURE_MIN_NODE_DISK_GB} GB disk per node; ${POSTURE_RECOMMENDED_VPS})${CLR_RESET}
  provider:        ${PROVIDER}
  architecture:    ${ARCH}
  hcloud context:  ${HCLOUD_CONTEXT:-n/a}
  base_domain:     ${BASE_DOMAIN}      ${CLR_DIM}(separately defined; not coupled to env_id)${CLR_RESET}
  operator:        ${OPERATOR_USERNAME} <${OPERATOR_EMAIL}>
  ssh pubkey:      ${SSH_PUBKEY_PATH:-${ENV_ROOT}/ssh/operator.pub}
  cf zone:         ${CF_ZONE_NAME}
  b2 region:       ${B2_REGION}
  tailscale:       $([ -n "${TS_AUTHKEY}" ] && echo "configured" || echo "skipped")
  headscale:       ${HEADSCALE_HOST:-skipped}
  bundle:          ${BUNDLE_FILE}
  manifest:        ${MANIFEST_FILE}
  inventory:       ${INVENTORY_DISPLAY}
  sops.yaml:       ${SOPS_FILE}
EOF
    fi

    echo "" >&2
    if [ "${NON_INTERACTIVE}" -eq 0 ]; then
        confirm "Write artifacts now?" || die "aborted by operator; nothing written"
    else
        info "Non-interactive mode: auto-confirmed write and stopping at artifact generation."
    fi

    section "Writing artifacts"

    if [ "$PROVIDER" != "sandbox" ]; then
        if [ "${USE_GENERATED_KEY:-yes}" = "yes" ]; then
            generate_per_env_ssh_keypair "${ENV_ID}" "$ENV_ROOT"
        else
            install -d -m 0700 "${ENV_ROOT}/ssh"
            cat "${SSH_PUBKEY_PATH}" > "${ENV_ROOT}/ssh/operator.pub"
            chmod 0644 "${ENV_ROOT}/ssh/operator.pub"
            SSH_PUBKEY_PATH="${ENV_ROOT}/ssh/operator.pub"
            SSH_PRIVKEY_CONTENTS="$(cat "${SSH_PRIVKEY_PATH}")
"
        fi
    fi
    generate_awx_control_node_keypair "${ENV_ID}" "$ENV_ROOT"

    render_sops_yaml "${ENV_ID}" "${pubkey}"
    render_bundle "${ENV_ID}" "${pubkey}"
    if [ "$PROVIDER" = "sandbox" ]; then
        render_manifest "${ENV_ID}"
        render_sandbox_inventory "${ENV_ID}"
    else
        render_object_storage_tfvars "${ENV_ID}"
        render_provider_tfvars "${ENV_ID}"
        render_manifest "${ENV_ID}"
        render_inventory_main "${ENV_ID}"
        render_inventory_tailscale "${ENV_ID}"
        render_inventory_openbao_secrets "${ENV_ID}"
    fi

    if [ "$PROVIDER" != "sandbox" ] && [ "${NON_INTERACTIVE}" -eq 0 ]; then
        echo "" >&2
        "$SCRIPT_DIR/validate-env.sh" "${ENV_ID}"
    fi

    section "Done. Next steps for the operator"
    if [ "$PROVIDER" = "sandbox" ]; then
        cat >&2 <<EOF

  The entire env lives under ${ENV_ROOT}/ — bundle, manifest, inventory,
  sops rule, and (after pre-seed) the break-glass keys. Teardown is a single
  \`rm -rf\` of that directory. No DMF_BOOTSTRAP_BUNDLE_DIR export is needed
  for sandbox envs.

  1. Verify the bundle decrypts:
     ${SCRIPT_DIR}/bootstrap-secrets.sh doctor ${ENV_ID}

  2. Confirm the node is reachable over SSH:
     ssh -i ${SSH_PRIVKEY_PATH} ${ANSIBLE_USER}@${SANDBOX_NODE_IP}

  3. Provision the sandbox (single node; local-path, ServiceLB 80/443, local CA):
     RUNBOOK_TIMEOUT=5400 ${SCRIPT_DIR}/run-playbook.sh ${ENV_ID} \\
       ../dmf-infra/k3s-lab-bootstrap/bootstrap-sandbox-provision-pre-seed.yml

  4. OpenBao Tier-3 self-recovering unseal runs in-profile (Shamir 1/1; key
     under ${ENV_ROOT}/openbao-keys — no JuiceFS/Keychain/USB).
     Then seed (writes the bundle's cluster.k3s_token into OpenBao as
     vault_k3s_token, which the inventory maps to k3s_token):
     ${SCRIPT_DIR}/bootstrap-secrets.sh seed-bao ${ENV_ID}

  5. Post-seed (apps + monitoring + catalog):
     RUNBOOK_TIMEOUT=5400 ${SCRIPT_DIR}/run-playbook.sh ${ENV_ID} \\
       ../dmf-infra/k3s-lab-bootstrap/bootstrap-sandbox-provision-post-seed.yml

  6. Configure (cross-app wiring: Zot OIDC, Forgejo bootstrap, NetBox SoT, AWX integration):
     RUNBOOK_TIMEOUT=5400 ${SCRIPT_DIR}/run-playbook.sh ${ENV_ID} \\
       ../dmf-infra/k3s-lab-bootstrap/bootstrap-sandbox-configure.yml

  7. Verify the sandbox gate:
     RUNBOOK_TIMEOUT=5400 ${SCRIPT_DIR}/run-playbook.sh ${ENV_ID} \\
       ../dmf-infra/k3s-lab-bootstrap/bootstrap-sandbox-verify.yml
EOF

        # Step 8: conditional on addressing mode
        if [ "${SANDBOX_ADDRESSING:-sslip.io}" = "hosts" ]; then
            cat >&2 <<EOF

  8. Trust the local CA in your browser/admin client (the cert-manager step
     prints the CA cert + per-OS trust instructions), then map *.${BASE_DOMAIN}
     to ${SANDBOX_NODE_IP} in your hosts file / resolver.
EOF
        else
            cat >&2 <<EOF

  8. Trust the local CA in your browser/admin client (the cert-manager step
     prints the CA cert + per-OS trust instructions). *.${BASE_DOMAIN} resolves
     automatically (sslip.io public DNS); no /etc/hosts entry needed. Ensure the
     node is reachable on port 443 from your browser.
EOF
        fi

        cat >&2 <<EOF

  9. Enroll your two operator passkeys (ADR-0028 D8 — ≥2 confirmed devices).
     a. Subscribe (optional but recommended) — the bootstrap pushes the
        passkey enrollment URL to a per-env ntfy topic, reusable within TTL, 24h TTL:
            https://ntfy.sh/dmf-${ENV_ID}-${OPERATOR_USERNAME}
     b. First passkey (terminal — script returns + self-heals URL):
            ${SCRIPT_DIR}/get-passkey-enrollment-url.sh ${ENV_ID}
        Open the URL in a private window, pick AUTHENTICATOR A
        (e.g. iCloud Keychain).
     c. Second passkey (browser — Console self-service after sign-in):
        DMF Console → Settings → "Create new device invitation".
        Use AUTHENTICATOR B (hardware key, different device, etc.).
     Full procedure + same-authenticator failure mode:
        docs/runbooks/passkey-enrollment.md (in the umbrella repo)

EOF
    else
        cat >&2 <<EOF

  The entire cloud env lives under ${ENV_ROOT}/ — bundle, manifest, inventory,
  sops rule, and generated SSH keys. Teardown is a single \`rm -rf\` of that
  directory.

  1. Verify bundle decrypts:
     ${SCRIPT_DIR}/bootstrap-secrets.sh doctor ${ENV_ID}

  2. Create + configure B2 buckets (idempotent):
     ${SCRIPT_DIR}/b2-buckets.sh ensure ${ENV_ID}

  3. Provision Layer 1 (cloud nodes via OpenTofu):
     # Generic terraform root: ${REPO_DIR}/terraform/hetzner/ (for all hetzner envs)
     # Per-env state isolation: ${DMF_DATA_ROOT}/envs/${ENV_ID}/terraform-state/
     ${SCRIPT_DIR}/tf-apply.sh ${ENV_ID} init
     ${SCRIPT_DIR}/tf-apply.sh ${ENV_ID} plan -out=plan.bin
     ${SCRIPT_DIR}/tf-apply.sh ${ENV_ID} apply plan.bin

  4. Pre-seed bootstrap (k3s + OpenBao deploy + initialize):
     RUNBOOK_TIMEOUT=5400 ${SCRIPT_DIR}/run-playbook.sh ${ENV_ID} \\
       ../dmf-infra/k3s-lab-bootstrap/bootstrap-provision-pre-seed.yml

  5. CAPTURE the 5 Shamir shares from the init output (operator-only;
     distribute per ${DMF_DATA_ROOT}/envs/${ENV_ID}/inventory/group_vars/all/openbao_secrets.yml
     — 3 to macOS Keychain, 2 to USB).

  6. Unseal OpenBao:
     ${SCRIPT_DIR}/unseal-openbao.sh ${ENV_ID}

  7. Seed secrets from the bundle:
     ${SCRIPT_DIR}/bootstrap-secrets.sh seed-bao ${ENV_ID}

  8. Post-seed (monitoring → apps → vertical-resilience):
     RUNBOOK_TIMEOUT=5400 ${SCRIPT_DIR}/run-playbook.sh ${ENV_ID} \\
       ../dmf-infra/k3s-lab-bootstrap/bootstrap-provision-post-seed.yml

  9. Configure (cross-app wiring: Zot OIDC, Forgejo bootstrap, NetBox SoT, AWX integration):
     RUNBOOK_TIMEOUT=5400 ${SCRIPT_DIR}/run-playbook.sh ${ENV_ID} \\
       ../dmf-infra/k3s-lab-bootstrap/bootstrap-configure.yml

  10. Publish public LB DNS records after ingress exists:
     ${SCRIPT_DIR}/tf-apply.sh ${ENV_ID} plan -var publish_lb_dns_records=true -out=publish-dns.plan
     ${SCRIPT_DIR}/tf-apply.sh ${ENV_ID} apply publish-dns.plan

  11. Verify the resilience track:
     RUNBOOK_TIMEOUT=5400 ${SCRIPT_DIR}/run-playbook.sh ${ENV_ID} \\
       ../dmf-infra/k3s-lab-bootstrap/bootstrap-verify.yml \\
       --tags vertical-resilience \\
       -e resilience_verify_soak_prewarm=true

  12. Enroll your two operator passkeys (ADR-0028 D8 — ≥2 confirmed devices).
     a. Subscribe (optional but recommended) — the bootstrap pushes the
        passkey enrollment URL to a per-env ntfy topic, reusable within TTL, 24h TTL:
            https://ntfy.sh/dmf-${ENV_ID}-${OPERATOR_USERNAME}
     b. First passkey (terminal — script returns + self-heals URL):
            ${SCRIPT_DIR}/get-passkey-enrollment-url.sh ${ENV_ID}
        Open the URL in a private window, pick AUTHENTICATOR A
        (e.g. iCloud Keychain).
     c. Second passkey (browser — Console self-service after sign-in):
        DMF Console → Settings → "Create new device invitation".
        Use AUTHENTICATOR B (hardware key, different device, etc.).
     Full procedure + same-authenticator failure mode:
        docs/runbooks/passkey-enrollment.md (in the umbrella repo)

EOF
    fi
}

main() {
    local mode="interactive" answers_file=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --non-interactive)
                [ $# -ge 2 ] || die "--non-interactive requires an answers file"
                mode="non-interactive"
                answers_file="$2"
                shift 2
                ;;
            -h|--help)
                usage
                return 0
                ;;
            *)
                die "unknown flag: $1"
                ;;
        esac
    done

    NON_INTERACTIVE=0
    [ "$mode" = "non-interactive" ] && NON_INTERACTIVE=1

    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        load_inputs_noninteractive "$answers_file"
    else
        collect_inputs_interactive
    fi

    validate_inputs
    render_tail
}

# Handle --remove mode at the top level (delegate to remove-env.sh)
if [ $# -gt 0 ] && [ "$1" = "--remove" ]; then
  shift
  exec "$SCRIPT_DIR/remove-env.sh" "$@"
fi

main "$@"
