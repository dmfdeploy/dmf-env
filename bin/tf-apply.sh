#!/usr/bin/env bash
# tf-apply.sh — wrapper for `tofu` that resolves per-env inputs and isolates state.
#
# Usage:
#   bin/tf-apply.sh <ENV_NAME> <tofu-subcommand> [args...]
#
# ENV_NAME is required. The resolver finds the env's artifacts under
# ~/.dmfdeploy/envs/<env>/, and isolates terraform state per-env under
# ~/.dmfdeploy/envs/<env>/terraform-state/.
#
# Examples:
#   bin/tf-apply.sh <env-name> plan
#   bin/tf-apply.sh <env-name> apply
#   bin/tf-apply.sh <env-name> apply -target='module.cluster.hcloud_server.node["k3s-node-03"]'
#   bin/tf-apply.sh <env-name> init
#   bin/tf-apply.sh <env-name> import 'module.cluster.hcloud_ssh_key.k3s' 12345
#
# Wizard-created envs use private tfvars under $DMF_ENV_TFVARS_DIR/<provider>.tfvars.
# Legacy envs fall back to local config files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

cd "$REPO_DIR"

# shellcheck source=lib/_resolve_env_paths.sh
. "$SCRIPT_DIR/lib/_resolve_env_paths.sh"

dmf_source_operator_config
dmf_resolve_env_paths "$1" || {
  echo "ERROR: Unable to resolve environment $1" >&2
  echo "Available environments:" >&2
  dmf_list_known_envs "$REPO_DIR" | sed 's/^/  /' >&2
  exit 1
}

ENV_NAME="$1"
shift

normalize_dir() {
  local dir="$1"
  while [ "$dir" != "/" ] && [ "${dir%/}" != "$dir" ]; do
    dir="${dir%/}"
  done
  printf '%s' "$dir"
}

apply_uses_saved_plan() {
  [ "${1:-}" = "apply" ] || return 1
  shift
  for arg in "$@"; do
    case "$arg" in
      -*) ;;
      *) return 0 ;;
    esac
  done
  return 1
}

inventory_var() {
  local key="$1"
  local f="${DMF_ENV_INVENTORY_DIR}/group_vars/all/main.yml"
  [ -f "$f" ] || return 1
  awk -v key="$key" '
    $0 ~ "^[[:space:]]*" key ":[[:space:]]*" {
      sub("^[[:space:]]*" key ":[[:space:]]*", "", $0)
      gsub(/^"/, "", $0)
      gsub(/"$/, "", $0)
      gsub(/^'\''/, "", $0)
      gsub(/'\''$/, "", $0)
      print
      exit
    }
  ' "$f"
}

# Determine provider from manifest or inventory fallback
DMF_PROVIDER="$(inventory_var dmf_provider || true)"
if [ -z "$DMF_PROVIDER" ]; then
  case "$ENV_NAME" in
    *)               DMF_PROVIDER="hetzner" ;;
  esac
fi

# Runtime guard: only hetzner has a Terraform/cloud destroy/apply path.
case "$DMF_PROVIDER" in
  hetzner) ;;  # OK — the only supported provider for tf-apply
  sandbox)
    echo "ERROR: sandbox has no Terraform/OpenTofu destroy/apply path" >&2
    exit 1
    ;;
  *)
    echo "ERROR: unsupported provider for tf-apply: $DMF_PROVIDER" >&2
    exit 1
    ;;
esac

# ──────────────────────────────────────────────────────────────
# Resolve provider inputs.
#
# New wizard-created envs write private provider tfvars under
# $DMF_ENV_TFVARS_DIR/<provider>.tfvars. Prefer those files:
# the secret stays on disk and is handed to Tofu by path. Legacy envs fall
# back to the older local-config readers.
# ──────────────────────────────────────────────────────────────

PROVIDER_TFVARS=""
if [ -n "${DMF_ENV_TFVARS_DIR}" ] && [ -d "${DMF_ENV_TFVARS_DIR}" ]; then
  tfvars_file="${DMF_ENV_TFVARS_DIR}/${DMF_PROVIDER}.tfvars"
  [ -f "$tfvars_file" ] && PROVIDER_TFVARS="$tfvars_file"
fi

SUBCMD="${1:-unknown}"
PROVIDER_TFVARS_ARGS=()
if [ -n "$PROVIDER_TFVARS" ]; then
  case "$SUBCMD" in
    plan|destroy)
      PROVIDER_TFVARS_ARGS=(-var-file="$PROVIDER_TFVARS")
      ;;
    apply)
      if ! apply_uses_saved_plan "$@"; then
        PROVIDER_TFVARS_ARGS=(-var-file="$PROVIDER_TFVARS")
      fi
      ;;
  esac
fi

alicloud_access_key=""
alicloud_secret_key=""
hcloud_token=""
cf_dns_token=""

case "$DMF_PROVIDER" in
  aliyun)
    if [ -n "$PROVIDER_TFVARS" ]; then
      :
    else
    # ── Alicloud: read AK/SK from operator-local credential file ──
    aliyun_creds="$HOME/.secure/aliyun/.ay-dmfdeploy"
    if [ -f "$aliyun_creds" ]; then
      # shellcheck disable=SC1090
      . "$aliyun_creds"
    fi

    alicloud_access_key="${ALIYUN_ACCESS_KEY_ID:-}"
    alicloud_secret_key="${ALIYUN_ACCESS_KEY_SECRET:-}"

    if [ -z "$alicloud_access_key" ] || [ -z "$alicloud_secret_key" ]; then
      echo "ERROR: ALIYUN_ACCESS_KEY_ID or ALIYUN_ACCESS_KEY_SECRET not found in $aliyun_creds" >&2
      exit 1
    fi

    export TF_VAR_alicloud_access_key="$alicloud_access_key"
    export TF_VAR_alicloud_secret_key="$alicloud_secret_key"
    fi
    ;;

  hetzner)
    if [ -n "$PROVIDER_TFVARS" ]; then
      :
    else
    # ── Hetzner legacy fallback: read token from hcloud CLI config ──
    hcloud_context="$(inventory_var hcloud_context || true)"
    hcloud_config="$HOME/.config/hcloud/cli.toml"
    if [ -f "$hcloud_config" ]; then
      hcloud_token="$(python3 -c '
import pathlib, re, sys
config = pathlib.Path(sys.argv[1]).read_text()
requested = sys.argv[2]
if requested:
    active = requested
else:
    active_match = re.search(r"active_context\s*=\s*\"([^\"]+)\"", config)
    if not active_match:
        sys.exit(0)
    active = active_match.group(1)
ctx_pattern = rf"\[\[contexts\]\]\s+name\s*=\s*\"{re.escape(active)}\".*?token\s*=\s*\"([^\"]+)\""
token_match = re.search(ctx_pattern, config, re.DOTALL)
if token_match:
    print(token_match.group(1))
' "$hcloud_config" "$hcloud_context" 2>/dev/null)" || hcloud_token=""
    fi

    if [ -z "$hcloud_token" ]; then
      echo "ERROR: hcloud_token not found in $hcloud_config" >&2
      if [ -n "$hcloud_context" ]; then
        echo "  Expected context: $hcloud_context" >&2
      else
        echo "  Run: hcloud context create dmf-infra" >&2
      fi
      exit 1
    fi

    export TF_VAR_hcloud_token="$hcloud_token"
    fi
    ;;

  *)
    echo "ERROR: unsupported provider for $ENV_NAME: $DMF_PROVIDER" >&2
    exit 1
    ;;
esac

if [ -z "$PROVIDER_TFVARS" ]; then
  # Cloudflare DNS token is shared across all legacy environments
  cf_dns_file="$HOME/.config/cf/dns.txt"
  if [ -f "$cf_dns_file" ]; then
    cf_dns_token="$(tr -d '[:space:]' < "$cf_dns_file")" || cf_dns_token=""
  fi

  if [ -z "$cf_dns_token" ]; then
    echo "ERROR: cloudflare_api_token not found at $cf_dns_file" >&2
    echo "  Provision: echo '<token>' > $cf_dns_file && chmod 600 $cf_dns_file" >&2
    exit 1
  fi

  export TF_VAR_cloudflare_api_token="$cf_dns_token"
fi

# ──────────────────────────────────────────────────────────────
# Per-env state isolation
# ──────────────────────────────────────────────────────────────

TF_DIR="terraform/${DMF_PROVIDER}"
mkdir -p "${DMF_ENV_TF_STATE_DIR}"
export TF_DATA_DIR="${DMF_ENV_TF_STATE_DIR}/.terraform"

INIT_BACKEND_CONFIG=()
SUBCMD="${1:-unknown}"
if [ "$SUBCMD" = "init" ]; then
  INIT_BACKEND_CONFIG=(-backend-config="path=${DMF_ENV_TF_STATE_DIR}/terraform.tfstate")
fi

# ──────────────────────────────────────────────────────────────
# Logging (matches bin/run-playbook.sh style)
# ──────────────────────────────────────────────────────────────
LOG_DIR="/tmp/dmf-tofu-logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/${ENV_NAME}-${SUBCMD}-$(date +%Y%m%d-%H%M%S).log"

echo "==> Logging to: $LOG_FILE" >&2
echo "==> tofu dir:   $TF_DIR" >&2
echo "==> Subcommand: $SUBCMD" >&2
[ "${#PROVIDER_TFVARS_ARGS[@]}" -gt 0 ] && echo "==> var-file:   $PROVIDER_TFVARS" >&2
echo >&2

# The AWX control-node keypair is generated per-env by init-wizard.sh (pubkey at
# ${DMF_ENV_SSH_DIR}/awx-control-node.pub, privkey in the sops bundle). It's
# passed to Terraform via -var awx_control_node_ssh_pubkey_path below — no
# hardcoded path, no separate generator at apply time.

# ──────────────────────────────────────────────────────────────
# Construct tofu command with per-env variables
# ──────────────────────────────────────────────────────────────

cd "$TF_DIR"
set +e

SUBCMD="${1:-unknown}"
USER_ARGS=("${@:2}")
EXTRA_ARGS=()
VAR_ARGS=()

case "$SUBCMD" in
  init)
    EXTRA_ARGS=("${INIT_BACKEND_CONFIG[@]+"${INIT_BACKEND_CONFIG[@]}"}")
    ;;
  plan|destroy|import)
    EXTRA_ARGS=(-lock=false)
    VAR_ARGS=(
      -var "manifest_path=${DMF_ENV_MANIFEST_FILE}"
      -var "hosts_ini_output_path=${DMF_ENV_INVENTORY_DIR}/hosts.ini"
      -var "ssh_pubkey_path=${DMF_ENV_SSH_PUBKEY}"
      -var "awx_control_node_ssh_pubkey_path=${DMF_ENV_SSH_DIR}/awx-control-node.pub"
    )
    ;;
  apply)
    EXTRA_ARGS=(-lock=false)
    if ! apply_uses_saved_plan "$@"; then
      VAR_ARGS=(
        -var "manifest_path=${DMF_ENV_MANIFEST_FILE}"
        -var "hosts_ini_output_path=${DMF_ENV_INVENTORY_DIR}/hosts.ini"
        -var "ssh_pubkey_path=${DMF_ENV_SSH_PUBKEY}"
        -var "awx_control_node_ssh_pubkey_path=${DMF_ENV_SSH_DIR}/awx-control-node.pub"
      )
    fi
    ;;
esac

tofu "$SUBCMD" \
  ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
  ${VAR_ARGS[@]+"${VAR_ARGS[@]}"} \
  ${PROVIDER_TFVARS_ARGS[@]+"${PROVIDER_TFVARS_ARGS[@]}"} \
  ${USER_ARGS[@]+"${USER_ARGS[@]}"} 2>&1 | tee "$LOG_FILE"
RC=${PIPESTATUS[0]}
set -e

exit "$RC"
