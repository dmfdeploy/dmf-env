#!/usr/bin/env bash
# bootstrap-secrets.sh — manage pre-Bao bootstrap secrets for DMF platform.
#
# Subcommands:
#   init <env>                    — create or update encrypted bundle
#   doctor <env>                  — validate bundle and local prerequisites
#   export-vars <env> <json-out>  — decrypt bundle to Ansible vars JSON
#   seed-bao <env>                — seed platform + admin paths into OpenBao
#   seed-awx-control-node-ssh <env> — seed AWX SSH privkey into OpenBao
#   status <env>                  — report bundle/seed metadata only
#   rotate <env> <field>          — regenerate a specific field (optional)
#   set-base-domain <env> <domain> — set metadata.base_domain for migration
#
# ADR-0007: no secrets in argv, stdout, logs, or AI transcripts.
# ADR-0010: live runs through bin/run-playbook.sh (this script is called by it).
#
# Usage (<env-id> is your env; current id is in the umbrella STATUS.md):
#   bin/bootstrap-secrets.sh init <env-id>
#   bin/bootstrap-secrets.sh doctor <env-id>
#   bin/bootstrap-secrets.sh export-vars <env-id> /tmp/vars.json
#   bin/bootstrap-secrets.sh seed-bao <env-id>
#   bin/bootstrap-secrets.sh seed-awx-control-node-ssh <env-id>
#   bin/bootstrap-secrets.sh status <env-id>

set -euo pipefail

# ──────────────────────────────────────────────────────────────
# Constants and environment resolution
# ──────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# Dual-layout env path resolver. Auto-source ~/.dmfdeploy/env (or the legacy
# ~/.config/dmf/env fallback) so DMF_BOOTSTRAP_BUNDLE_DIR is available for
# pre-consolidation envs without the operator having to source it manually.
# shellcheck source=lib/_resolve_env_paths.sh
. "$SCRIPT_DIR/lib/_resolve_env_paths.sh"
dmf_source_operator_config

# SOPS age key resolution: env var first, then standard path
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"
export SOPS_AGE_KEY_FILE="${AGE_KEY_FILE}"

# resolve_env_or_die <env_name> — populate DMF_ENV_* via the resolver.
# Subcommands call this BEFORE touching paths so they pick up the right
# layout transparently. For brand-new envs (no inventory yet, no bundle yet),
# pass --allow-missing; the resolver will set legacy placeholders.
resolve_env_or_die() {
  local env_name="$1"
  local allow_missing="${2:-}"
  if ! dmf_resolve_env_paths "$env_name"; then
    if [ "$allow_missing" != "--allow-missing" ]; then
      echo "ERROR: '$env_name' is not a known env" >&2
      echo "  Looked under ~/.dmfdeploy/envs/${env_name}/." >&2
      exit 1
    fi
  fi
}

# ──────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────

require_env_name() {
  if [ $# -lt 1 ] || [ -z "${1:-}" ]; then
    echo "ERROR: environment name required" >&2
    echo "  Usage: bin/bootstrap-secrets.sh <subcommand> <env> [args...]" >&2
    exit 1
  fi
  # Validate env name: alphanumeric + hyphens only
  if ! echo "$1" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$'; then
    echo "ERROR: invalid environment name '${1}'" >&2
    echo "  Must be alphanumeric with optional hyphens (e.g. the xxxx-xxxx env-id shape)" >&2
    exit 1
  fi
}

require_sops() {
  if ! command -v sops &>/dev/null; then
    echo "ERROR: sops is not installed" >&2
    echo "  brew install sops" >&2
    exit 1
  fi
}

# Resolve the .sops.yaml config file for this bundle.
# New-layout envs keep a per-env .sops.yaml beside the bundle.
bundle_sops_config_file() {
  local cfg
  cfg="$(dirname "${DMF_ENV_BUNDLE_FILE}")/.sops.yaml"
  if [ -f "${cfg}" ]; then
    printf '%s' "${cfg}"
    return
  fi
  # Not found
  return
}

require_age_key() {
  if [ ! -f "${AGE_KEY_FILE}" ]; then
    echo "ERROR: age private key not found at ${AGE_KEY_FILE}" >&2
    echo "" >&2
    echo "  Generate one with:" >&2
    echo "    mkdir -p \$(dirname ${AGE_KEY_FILE})" >&2
    echo "    age-keygen -o ${AGE_KEY_FILE}" >&2
    echo "    chmod 600 ${AGE_KEY_FILE}" >&2
    echo "" >&2
    echo "  Then extract the public key and add it to dmf-env/.sops.yaml:" >&2
    echo "    age-keygen -y ${AGE_KEY_FILE}" >&2
    echo "" >&2
    echo "  Alternatively, set SOPS_AGE_KEY_FILE to your key location." >&2
    exit 1
  fi

  local perms
  perms="$(age_key_perms || echo "unknown")"
  if [ "${perms}" != "600" ] && [ "${perms}" != "0600" ]; then
    echo "WARNING: age key file permissions are ${perms} (should be 0600)" >&2
    echo "  chmod 600 ${AGE_KEY_FILE}" >&2
  fi
}

# Octal permission bits of the age key file. GNU coreutils form (-c) must come
# first: GNU stat treats `-f '%Lp'` as "filesystem-status these operands" and
# dumps a multi-line block to stdout even though it exits non-zero, which
# poisons the command substitution at the call sites. BSD/macOS stat rejects
# -c cleanly on stderr with nothing on stdout, so GNU-first is safe both ways.
age_key_perms() {
  stat -c '%a' "${AGE_KEY_FILE}" 2>/dev/null || stat -f '%Lp' "${AGE_KEY_FILE}" 2>/dev/null
}

age_public_key() {
  age-keygen -y "${AGE_KEY_FILE}" 2>/dev/null
}

require_bundle_exists() {
  local env_name="$1"
  local bundle="${DMF_ENV_BUNDLE_FILE}"
  if [ ! -f "${bundle}" ]; then
    echo "ERROR: bundle not found: ${bundle}" >&2
    echo "  Run: bin/bootstrap-secrets.sh init ${env_name}" >&2
    exit 1
  fi
}

require_bundle_decryptable() {
  local env_name="$1"
  local bundle="${DMF_ENV_BUNDLE_FILE}"
  if ! sops --decrypt "${bundle}" &>/dev/null; then
    echo "ERROR: bundle cannot be decrypted: ${bundle}" >&2
    if [ "$DMF_ENV_LAYOUT" = "new" ]; then
      echo "  Check that your age key matches the recipient in ${DMF_ENV_SOPS_CONFIG}" >&2
    else
      echo "  Check that your age key matches a recipient in dmf-env/.sops.yaml" >&2
    fi
    exit 1
  fi
}

# Read a field from the decrypted bundle
bundle_field() {
  local env_name="$1"
  local field_path="$2"  # yaml path, e.g. bootstrap_admin.username
  local bundle="${DMF_ENV_BUNDLE_FILE}"
  sops --decrypt --output-type json "${bundle}" 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
parts = '${field_path}'.split('.')
obj = data
for p in parts:
    if isinstance(obj, dict):
        obj = obj.get(p)
    else:
        obj = None
        break
if obj is None:
    sys.exit(1)
print(obj)
"
}

# Write a field into the decrypted bundle and re-encrypt.
# Secret value is passed via stdin (NUL-delimited after JSON) — never argv.
bundle_set() {
  local env_name="$1"
  local field_path="$2"
  local value="$3"
  local bundle="${DMF_ENV_BUNDLE_FILE}"

  local tmp_file
  local tmp_file_dir
  tmp_file_dir="$(mktemp -d)"
  # Name the temp file = basename of the real bundle so it matches the SAME
  # creation_rule the bundle does (sandbox: bundle.sops.yaml; cloud:
  # <env>.sops.yaml). Without this, --config's rule (.*/bundle\.sops\.yaml$)
  # won't match a differently-named temp → "no matching creation rules found".
  tmp_file="${tmp_file_dir}/$(basename "${bundle}")"

  # Decrypt bundle JSON, then append NUL + secret value on same stdin stream.
  # python3 reads JSON up to NUL, then the secret after NUL.
  # Capture exit codes to detect failures (was previously silent under set -e).
  # To avoid PIPESTATUS issues with compound commands, write to temp file first.
  local decrypt_tmp
  decrypt_tmp="$(mktemp)"
  # SINGLE trap to clean up BOTH tmp dirs (bash keeps only one RETURN trap per scope)
  trap 'rm -rf "${tmp_file_dir}"; rm -f "${decrypt_tmp}"' RETURN

  set +e
  sops --decrypt --output-type json "${bundle}" 2>/dev/null > "${decrypt_tmp}"
  local sops_rc=$?
  set -e

  if [ -n "${DMF_BUNDLE_SET_DEBUG:-}" ]; then
    echo "DEBUG: bundle_set decrypt: sops=$sops_rc" >&2
  fi

  if [ "$sops_rc" -ne 0 ]; then
    echo "ERROR: bundle_set: decrypt/transform failed for field '${field_path}' in '${bundle}' (sops_decrypt=$sops_rc python=0)" >&2
    return 1
  fi

  # Now pipe the decrypted JSON + value through python3
  set +e
  {
    cat "${decrypt_tmp}"
    printf '\0%s' "${value}"
  } | python3 -c "
import json, sys
raw = sys.stdin.buffer.read()
json_blob, _, val_bytes = raw.partition(b'\0')
data = json.loads(json_blob)
parts = sys.argv[1].split('.')
obj = data
for p in parts[:-1]:
    if p not in obj:
        obj[p] = {}
    obj = obj[p]
obj[parts[-1]] = val_bytes.decode('utf-8')
print(json.dumps(data, indent=2))
" "${field_path}" > "${tmp_file}"; local rc=("${PIPESTATUS[@]}")
  set -e
  local python_rc="${rc[1]:-0}"

  if [ -n "${DMF_BUNDLE_SET_DEBUG:-}" ]; then
    echo "DEBUG: bundle_set python transform: python=$python_rc" >&2
  fi

  if [ "$python_rc" -ne 0 ]; then
    echo "ERROR: bundle_set: decrypt/transform failed for field '${field_path}' in '${bundle}' (sops_decrypt=$sops_rc python=$python_rc)" >&2
    return 1
  fi

  local sops_cfg
  sops_cfg="$(bundle_sops_config_file)"
  local encrypt_rc mv_rc
  set +e
  if [ -n "${sops_cfg}" ]; then
    sops --config "${sops_cfg}" --encrypt "${tmp_file}" > "${bundle}.tmp"
    encrypt_rc=$?
  else
    sops --encrypt "${tmp_file}" > "${bundle}.tmp"
    encrypt_rc=$?
  fi
  set -e

  if [ -n "${DMF_BUNDLE_SET_DEBUG:-}" ]; then
    echo "DEBUG: bundle_set encrypt: sops=$encrypt_rc" >&2
  fi

  if [ "$encrypt_rc" -ne 0 ]; then
    rm -f "${bundle}.tmp"
    echo "ERROR: sops --encrypt failed for ${bundle} (bundle left untouched)" >&2
    return 1
  fi

  chmod 0600 "${bundle}.tmp"
  set +e
  mv "${bundle}.tmp" "${bundle}"
  mv_rc=$?
  set -e

  if [ -n "${DMF_BUNDLE_SET_DEBUG:-}" ]; then
    echo "DEBUG: bundle_set mv: mv=$mv_rc" >&2
  fi

  if [ "$mv_rc" -ne 0 ]; then
    echo "ERROR: failed to move temporary file to bundle location" >&2
    return 1
  fi

  chmod 0600 "${bundle}"
}

# Generate a random base64 string of given length
gen_secret() {
  openssl rand -base64 "$1" | tr -d '+/=' | head -c "$2"
}

expand_local_path() {
  # Note: the tilde inside the parameter expansion pattern must be quoted.
  # Unquoted, bash performs tilde expansion on the pattern itself, so
  # ${1#~/} ends up trying to strip a prefix of "$HOME/" rather than the
  # literal "~/" — leaving "~/.ssh/..." unmodified, which then composes
  # to "$HOME/~/.ssh/..." in the printf. Quote it.
  case "$1" in
    "~/"*) printf '%s/%s' "$HOME" "${1#"~/"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

inventory_control_host() {
  local env_name="$1"
  local hosts_file="${DMF_ENV_INVENTORY_DIR}/hosts.ini"
  if [ ! -f "${hosts_file}" ]; then
    echo "ERROR: inventory not found: ${hosts_file}" >&2
    exit 1
  fi

  awk '
    $0 ~ /^\[k3s_control\]/ { in_group = 1; next }
    $0 ~ /^\[/ { in_group = 0 }
    in_group && $1 !~ /^($|#)/ { print $1; exit }
  ' "${hosts_file}"
}

inventory_host_var() {
  local env_name="$1"
  local host_name="$2"
  local var_name="$3"
  local hosts_file="${DMF_ENV_INVENTORY_DIR}/hosts.ini"

  awk -v host="${host_name}" -v var="${var_name}" '
    $1 == host {
      prefix = var "="
      for (i = 2; i <= NF; i++) {
        if (index($i, prefix) == 1) {
          print substr($i, length(prefix) + 1)
          exit
        }
      }
    }
  ' "${hosts_file}"
}

inventory_group_var() {
  local env_name="$1"
  local var_name="$2"
  local vars_dir="${DMF_ENV_INVENTORY_DIR}/group_vars/all"

  if [ ! -d "${vars_dir}" ]; then
    return 1
  fi

  awk -v var="${var_name}" '
    $0 ~ "^[[:space:]]*" var ":[[:space:]]*" {
      value = $0
      sub("^[^:]+:[[:space:]]*", "", value)
      gsub(/^["'\''"]|["'\''"]$/, "", value)
      print value
      exit
    }
  ' "${vars_dir}"/*.yml 2>/dev/null
}

resolve_remote_kubectl() {
  local env_name="$1"

  REMOTE_KUBECTL_SSH_TARGET="${DMF_KUBECTL_SSH_TARGET:-}"
  REMOTE_KUBECTL_SSH_KEY="${DMF_KUBECTL_SSH_KEY:-}"

  if [ -z "${REMOTE_KUBECTL_SSH_TARGET}" ]; then
    local control_host control_addr control_user
    control_host="$(inventory_control_host "${env_name}")"
    if [ -z "${control_host}" ]; then
      echo "ERROR: no [k3s_control] host found in ${DMF_ENV_INVENTORY_DIR}/hosts.ini" >&2
      echo "  Set DMF_KUBECTL_SSH_TARGET to override." >&2
      exit 1
    fi

    control_addr="$(inventory_host_var "${env_name}" "${control_host}" ansible_host)"
    control_user="$(inventory_host_var "${env_name}" "${control_host}" ansible_user)"
    control_addr="${control_addr:-${control_host}}"

    if [ -z "${control_user}" ]; then
      echo "ERROR: no ansible_user found for ${control_host} in ${DMF_ENV_INVENTORY_DIR}/hosts.ini" >&2
      echo "  Set DMF_KUBECTL_SSH_TARGET to override." >&2
      exit 1
    fi

    REMOTE_KUBECTL_SSH_TARGET="${control_user}@${control_addr}"
  fi

  if [ -z "${REMOTE_KUBECTL_SSH_KEY}" ]; then
    REMOTE_KUBECTL_SSH_KEY="$(inventory_group_var "${env_name}" ansible_ssh_private_key_file || true)"
  fi

  if [ -n "${REMOTE_KUBECTL_SSH_KEY}" ]; then
    REMOTE_KUBECTL_SSH_KEY="$(expand_local_path "${REMOTE_KUBECTL_SSH_KEY}")"
  fi

  echo "Using remote kubectl target: ${REMOTE_KUBECTL_SSH_TARGET}" >&2
}

remote_kubectl() {
  if [ -z "${REMOTE_KUBECTL_SSH_TARGET:-}" ]; then
    echo "ERROR: remote kubectl target not resolved" >&2
    exit 1
  fi

  local ssh_args
  ssh_args=(-o LogLevel=ERROR -o BatchMode=yes)
  if [ -n "${REMOTE_KUBECTL_SSH_KEY:-}" ]; then
    ssh_args+=(-i "${REMOTE_KUBECTL_SSH_KEY}")
  fi

  # OpenSSH joins trailing args with single spaces and lets the remote shell
  # re-parse the result. Naive `ssh host cmd "$@"` therefore corrupts any arg
  # that contains shell metacharacters — notably the multi-line `sh -c '...'`
  # script bodies seed-bao uses for stdin-fed secret writes. Shell-quote each
  # arg before joining so quoting + word boundaries survive the round-trip.
  local cmd="sudo -n kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml"
  local arg
  for arg in "$@"; do
    cmd+=" $(printf '%q' "$arg")"
  done

  ssh "${ssh_args[@]}" "${REMOTE_KUBECTL_SSH_TARGET}" "${cmd}"
}

# Validate the bundle schema exists and has required top-level keys
validate_bundle_schema() {
  local env_name="$1"
  local bundle="${DMF_ENV_BUNDLE_FILE}"

  sops --decrypt --output-type json "${bundle}" 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)

required_sections = ['bootstrap_admin', 'cluster', 'providers', 'metadata']
missing = [s for s in required_sections if s not in data]
if missing:
    print(f'ERROR: missing bundle sections: {missing}', file=sys.stderr)
    sys.exit(1)

# Check required fields present (non-empty)
required_fields = {
    'bootstrap_admin.username': str,
    'bootstrap_admin.email': str,
    'bootstrap_admin.password': str,
    'cluster.k3s_token': str,
    'metadata.base_domain': str,
}

for path, expected_type in required_fields.items():
    parts = path.split('.')
    obj = data
    for p in parts:
        obj = obj.get(p) if isinstance(obj, dict) else None
        if obj is None:
            break
    if obj is None or not isinstance(obj, expected_type) or obj == '':
        print(f'ERROR: required field missing or empty: {path}', file=sys.stderr)
        sys.exit(1)

# Validate provider tokens. Provider detection prefers the new
# metadata.provider field (init-wizard 2026-05-19 schema). Falls back
# to env_name prefix for legacy bundles, then to inspecting the
# providers map as a last resort. Token reads tolerate both schemas:
# new providers.hetzner.cloud_token AND legacy providers.hcloud.token.
providers = data.get('providers', {})
metadata = data.get('metadata', {})
metadata_provider = (metadata.get('provider') or '').lower()
env_label_meta = metadata.get('env_id') or metadata.get('environment') or ''

if metadata_provider in ('sandbox', 'local', 'none'):
    # Sandbox / local profiles (WP1S, ADR-0031 Profile 1) have no cloud
    # provider; the cloud-token validation chain below is skipped for them.
    provider = metadata_provider
elif metadata_provider in ('hetzner', 'aliyun', 'aws'):
    provider = metadata_provider
elif env_label_meta.startswith('aliyun'):
    provider = 'aliyun'
elif env_label_meta.startswith('hetzner'):
    provider = 'hetzner'
elif env_label_meta.startswith('aws'):
    provider = 'aws'
elif 'hetzner' in providers or 'hcloud' in providers:
    provider = 'hetzner'
elif 'alicloud' in providers or 'aliyun' in providers:
    provider = 'aliyun'
elif 'aws' in providers:
    provider = 'aws'
else:
    print('ERROR: cannot determine provider — bundle has no metadata.provider, env_name has no hetzner/aliyun/aws prefix, and providers section is empty', file=sys.stderr)
    sys.exit(1)

if provider == 'hetzner':
    hcloud_legacy = providers.get('hcloud', {}).get('token')
    hetzner_new = providers.get('hetzner', {}).get('cloud_token')
    if not (hcloud_legacy or hetzner_new):
        print('ERROR: Hetzner bundle missing token — set providers.hetzner.cloud_token (new schema) or providers.hcloud.token (legacy)', file=sys.stderr)
        sys.exit(1)
elif provider == 'aliyun':
    ali = providers.get('alicloud', {}) or providers.get('aliyun', {})
    if not ali.get('access_key'):
        print('ERROR: providers.alicloud.access_key is required for Aliyun environments', file=sys.stderr)
        sys.exit(1)
    if not ali.get('secret_key'):
        print('ERROR: providers.alicloud.secret_key is required for Aliyun environments', file=sys.stderr)
        sys.exit(1)
elif provider == 'aws':
    aws = providers.get('aws', {})
    if not aws.get('access_key_id'):
        print('ERROR: providers.aws.access_key_id is required for AWS environments', file=sys.stderr)
        sys.exit(1)
    if not aws.get('secret_access_key'):
        print('ERROR: providers.aws.secret_access_key is required for AWS environments', file=sys.stderr)
        sys.exit(1)

# Validate object_storage blocks (if present)
object_storage = data.get('object_storage', {})
if object_storage:
    for logical_name in ['audit', 'openbao_snapshots', 'app_backups']:
        block = object_storage.get(logical_name, {})
        required_keys = ['bucket', 'endpoint', 'region', 'access_key_id', 'secret_access_key']
        missing_keys = [k for k in required_keys if k not in block]
        if missing_keys:
            print(f'ERROR: object_storage.{logical_name} missing keys: {missing_keys}', file=sys.stderr)
            sys.exit(1)

# Validate metadata.base_domain shape
import re
metadata = data.get('metadata', {})
base_domain = metadata.get('base_domain', '')
if base_domain and not re.match(r'^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$', base_domain):
    print(f'ERROR: metadata.base_domain is not a valid domain: {base_domain}', file=sys.stderr)
    sys.exit(1)
"
}

# ──────────────────────────────────────────────────────────────
# Subcommands
# ──────────────────────────────────────────────────────────────

cmd_init() {
  echo "ERROR: bootstrap-secrets init is removed — create envs with bin/init-wizard.sh" >&2
  return 1
}

cmd_doctor() {
  require_env_name "${1:-}"
  local env_name="$1"
  require_sops
  resolve_env_or_die "$env_name"

  local pass=0
  local fail=0
  local results=()

  check() {
    local label="$1"
    shift
    if "$@" &>/dev/null; then
      results+=("  PASS: ${label}")
      ((pass++)) || true
    else
      results+=("  FAIL: ${label}")
      ((fail++)) || true
    fi
  }

  # Age key available
  check "age private key available" test -f "${AGE_KEY_FILE}"

  # Age key permissions. perms_ok wraps the two accepted spellings in one
  # predicate: `check` always returns 0 (it records the result itself), so a
  # `check ... || check ...` chain would never reach the second alternative.
  perms_ok() {
    [ "$1" = "600" ] || [ "$1" = "0600" ]
  }
  if [ -f "${AGE_KEY_FILE}" ]; then
    local perms
    perms="$(age_key_perms || echo "999")"
    check "age key permissions 0600" perms_ok "${perms}"
  fi

  results+=("  INFO: layout=${DMF_ENV_LAYOUT}, bundle=${DMF_ENV_BUNDLE_FILE}")

  # Bundle exists
  local bundle="${DMF_ENV_BUNDLE_FILE}"
  check "bundle exists: ${bundle}" test -f "${bundle}"

  # Bundle decryptable
  if [ -f "${bundle}" ]; then
    check "bundle decryptable" sops --decrypt "${bundle}"
  fi

  # No plaintext sibling next to the bundle.
  local plaintext="${bundle%.sops.yaml}.yaml"
  check "no plaintext sibling" test ! -f "${plaintext}"

  # Bundle dir not in git tree. For the new layout the bundle is at
  # ~/.dmfdeploy/envs/<env>/ (operator dot-dir, never under a git tree);
  # for legacy it's the configured DMF_BOOTSTRAP_BUNDLE_DIR.
  local bundle_parent
  bundle_parent="$(dirname "${bundle}")"
  check "bundle dir not in git tree" bash -c "! (cd '${bundle_parent}' && git rev-parse --is-inside-work-tree 2>/dev/null)"

  # Schema validation
  if [ -f "${bundle}" ] && sops --decrypt "${bundle}" &>/dev/null; then
    check "schema: required sections present" validate_bundle_schema "${env_name}"

    # Check entropy requirements
    local pw_len
    pw_len="$(bundle_field "${env_name}" bootstrap_admin.password 2>/dev/null | wc -c | tr -d ' ')" || pw_len=0
    check "bootstrap_admin.password entropy >= 24 chars" [ "${pw_len}" -ge 25 ]  # +1 for newline from wc

    local k3s_len
    k3s_len="$(bundle_field "${env_name}" cluster.k3s_token 2>/dev/null | wc -c | tr -d ' ')" || k3s_len=0
    check "cluster.k3s_token entropy >= 32 chars" [ "${k3s_len}" -ge 33 ]

    # Check base_domain is set
    local base_domain
    base_domain="$(bundle_field "${env_name}" metadata.base_domain 2>/dev/null)" || base_domain=""
    check "metadata.base_domain is set" [ -n "${base_domain}" ]

    # Check object_storage blocks presence
    local os_check
    os_check="$(sops --decrypt --output-type json "${bundle}" 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
provider = (data.get('metadata', {}).get('provider') or '').lower()
if provider in ('sandbox', 'local', 'none'):
    # Sandbox/local profiles have no object-storage requirement (ADR-0031
    # Profile 1); don't require the audit/snapshots/backups blocks.
    print('skip')
    sys.exit(0)
os = data.get('object_storage', {})
issues = []
for name in ['audit', 'openbao_snapshots', 'app_backups']:
    block = os.get(name, {})
    for key in ['bucket', 'endpoint', 'region', 'access_key_id', 'secret_access_key']:
        if key not in block:
            issues.append(f'{name}.{key}')
    # Warn if bucket is set but creds are empty
    bucket = block.get('bucket', '')
    ak = block.get('access_key_id', '')
    sk = block.get('secret_access_key', '')
    if bucket and (not ak or not sk):
        print(f'WARN: object_storage.{name}: bucket set but credentials empty', file=sys.stderr)
if issues:
    print(f'FAIL: missing keys: {issues}')
    sys.exit(1)
print('ok')
" 2>&1)" || os_check="error"
    if echo "${os_check}" | grep -q '^WARN'; then
      echo "${os_check}" | grep '^WARN' >&2
      results+=("  WARN: object_storage credentials empty (bucket names set)")
    fi
    if echo "${os_check}" | grep -q '^FAIL'; then
      results+=("  FAIL: object_storage schema incomplete: ${os_check}")
      ((fail++)) || true
    elif echo "${os_check}" | grep -q '^skip'; then
      results+=("  PASS: object_storage not required (sandbox/local profile)")
      ((pass++)) || true
    elif echo "${os_check}" | grep -q '^ok'; then
      results+=("  PASS: object_storage blocks present")
      ((pass++)) || true
    fi

    # Check no break-glass material in bundle
    local has_breakglass
    has_breakglass="$(sops --decrypt --output-type json "${bundle}" 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
bg_keys = ['shamir', 'root_token', 'breakglass', 'unseal', 'automation_json']
for k in bg_keys:
    if k in str(data):
        print('found')
        sys.exit(0)
print('clean')
" 2>/dev/null)" || has_breakglass="clean"
    check "no break-glass material in bundle" [ "${has_breakglass}" = "clean" ]
  fi

  # Print results
  echo "=== doctor: ${env_name} ===" >&2
  for r in "${results[@]}"; do
    echo "${r}" >&2
  done
  echo "" >&2
  echo "  ${pass} passed, ${fail} failed" >&2

  if [ "${fail}" -gt 0 ]; then
    exit 1
  fi
}

cmd_export_vars() {
  require_env_name "${1:-}"
  local env_name="$1"
  local output_json="${2:-}"

  if [ -z "${output_json}" ]; then
    echo "ERROR: output JSON path required" >&2
    echo "  Usage: bin/bootstrap-secrets.sh export-vars <env> <output-json>" >&2
    exit 1
  fi

  require_sops
  require_age_key
  resolve_env_or_die "$env_name"
  require_bundle_exists "${env_name}"
  require_bundle_decryptable "${env_name}"

  # Validate schema before export
  validate_bundle_schema "${env_name}"

  # Build the vars JSON — secure temp file
  local tmp_json
  tmp_json="$(mktemp)"
  chmod 0600 "${tmp_json}"

  sops --decrypt --output-type json "${DMF_ENV_BUNDLE_FILE}" 2>/dev/null | python3 -c "
import json, sys

data = json.load(sys.stdin)
vars = {}

# Bootstrap admin
admin = data.get('bootstrap_admin', {})
if admin.get('username'):
    vars['vault_bootstrap_admin_username'] = admin['username']
if admin.get('email'):
    vars['vault_bootstrap_admin_email'] = admin['email']
if admin.get('password'):
    vars['vault_bootstrap_admin_password'] = admin['password']

# Per-app machine-identity secrets (ADR-0033). zot-svc is the scoped Zot
# machine-write account used by 331-registry-zot's htpasswd, playbook 630,
# and zot-mirror. INDEPENDENT of the admin/bootstrap password — read it
# straight from the bundle (NOT a compatibility copy). Absent on bundles
# predating ADR-0033; seed-bao generates and writes it back, after which it
# surfaces here. While absent, the zot role's '| mandatory' fails loudly —
# the migration signal to run seed-bao first.
apps = data.get('apps', {})
zot_app = apps.get('zot', {}) if isinstance(apps, dict) else {}
if zot_app.get('service_password'):
    vars['vault_zot_service_password'] = zot_app['service_password']

# Base domain (for constructing platform URLs)
metadata = data.get('metadata', {})
if metadata.get('base_domain'):
    vars['vault_base_domain'] = metadata['base_domain']

# Cluster
cluster = data.get('cluster', {})
if cluster.get('k3s_token'):
    vars['vault_k3s_token'] = cluster['k3s_token']

# Providers — tolerate both legacy (hcloud.token) and new
# (hetzner.cloud_token) schemas. Bundle vault_hcloud_token from
# whichever is present.
providers = data.get('providers', {})
hcloud_token = (
    providers.get('hcloud', {}).get('token')
    or providers.get('hetzner', {}).get('cloud_token')
)
if hcloud_token:
    vars['vault_hcloud_token'] = hcloud_token

# Aliyun: alicloud is the canonical key in both legacy and new
# schemas; the new wizard also accepts aliyun as an alias.
alicloud = providers.get('alicloud', {}) or providers.get('aliyun', {})
if alicloud.get('access_key'):
    vars['vault_alicloud_access_key'] = alicloud['access_key']
if alicloud.get('secret_key'):
    vars['vault_alicloud_secret_key'] = alicloud['secret_key']

# AWS — new wizard schema only; no legacy equivalent.
aws = providers.get('aws', {})
if aws.get('access_key_id'):
    vars['vault_aws_access_key_id'] = aws['access_key_id']
if aws.get('secret_access_key'):
    vars['vault_aws_secret_access_key'] = aws['secret_access_key']
if aws.get('region'):
    vars['vault_aws_region'] = aws['region']

# Surface the new metadata fields when present so playbooks can
# consume them via vault_* even without re-rendering the inventory.
md_env_id = metadata.get('env_id')
md_env_label = metadata.get('env_label')
md_provider = metadata.get('provider')
md_architecture = metadata.get('architecture')
if md_env_id:
    vars['vault_dmf_env_id'] = md_env_id
if md_env_label:
    vars['vault_dmf_env_label'] = md_env_label
if md_provider:
    vars['vault_dmf_provider'] = md_provider
if md_architecture:
    vars['vault_dmf_architecture'] = md_architecture

cf = providers.get('cloudflare', {})
if cf.get('dns_token'):
    vars['vault_cloudflare_dns_token'] = cf['dns_token']

ts = providers.get('tailscale', {})
if ts.get('authkey'):
    vars['vault_tailscale_authkey'] = ts['authkey']

# Notifications
notifications = data.get('notifications', {})
if notifications.get('ntfy_url'):
    vars['vault_alertmanager_ntfy_url'] = notifications['ntfy_url']
if notifications.get('healthchecks_url'):
    vars['vault_alertmanager_watchdog_url'] = notifications['healthchecks_url']

# Object-storage: export audit block for ansible audit-log-archival role
obj_storage = data.get('object_storage', {})
audit_block = obj_storage.get('audit', {})
if audit_block.get('bucket'):
    vars['audit_log_s3_bucket'] = audit_block['bucket']
if audit_block.get('endpoint'):
    vars['audit_log_s3_endpoint'] = audit_block['endpoint']
if audit_block.get('region'):
    vars['audit_log_aws_region'] = audit_block['region']
if audit_block.get('access_key_id'):
    vars['audit_log_aws_access_key_id'] = audit_block['access_key_id']
if audit_block.get('secret_access_key'):
    vars['audit_log_aws_secret_access_key'] = audit_block['secret_access_key']

# Compatibility copies for transition — map app-local admin to shared bootstrap
if 'vault_bootstrap_admin_password' in vars:
    pw = vars['vault_bootstrap_admin_password']
    vars['vault_forgejo_admin_password'] = pw
    vars['vault_netbox_superuser_password'] = pw
    vars['vault_grafana_admin_password'] = pw
    vars['vault_awx_admin_password'] = pw
    vars['vault_zot_admin_password'] = pw

with open(sys.argv[1], 'w') as f:
    json.dump(vars, f, indent=2, sort_keys=True)
" "${tmp_json}"

  # Move to final location (atomic on same filesystem)
  mv "${tmp_json}" "${output_json}"
  chmod 0600 "${output_json}"
}

# ──────────────────────────────────────────────────────────────
# Temporary root token via Shamir share quorum
# ──────────────────────────────────────────────────────────────
# seed-bao writes to `secret/platform/*` and `secret/apps/*/admin`. Neither
# the post-init ops-admin (app-admin-writer policy) nor the policy-reconciler
# (sys/policies/acl/*) has write capability on `secret/data/platform/*`, so
# the script must elevate.
#
# This mirrors the "Rotate OpenBao ops-admin password" play in
# playbooks/vertical-orchestration/120-ops-admin-rotation.yml: read 3 Shamir
# shares from the breakglass JSON, run `bao operator generate-root` to mint
# a one-shot root token, perform writes, then `bao token revoke -self`.
# Rationale recorded in the implementation plan §22 (added with this commit).
#
# Globals set by acquire_temp_root and consumed by helpers below:
#   BAO_POD          OpenBao pod name in the openbao namespace
#   BAO_ROOT_TOKEN   The decoded one-shot root token (no_log domain)

BAO_POD=""
BAO_ROOT_TOKEN=""

acquire_temp_root() {
  local env_name="$1"

  # Resolve the breakglass file path from inventory. eso_openbao_breakglass_file
  # is the canonical name; fall back to openbao_key_path + ".json" so envs that
  # haven't migrated to the explicit var still work.
  local breakglass_file
  breakglass_file="$(inventory_group_var "${env_name}" eso_openbao_breakglass_file || true)"
  if [ -z "${breakglass_file}" ]; then
    local key_path
    key_path="$(inventory_group_var "${env_name}" openbao_key_path || true)"
    [ -n "${key_path}" ] && breakglass_file="${key_path}.json"
  fi
  if [ -z "${breakglass_file}" ]; then
    echo "ERROR: cannot resolve breakglass file path for env '${env_name}'." >&2
    echo "  Set eso_openbao_breakglass_file or openbao_key_path in" >&2
    echo "  ${DMF_ENV_INVENTORY_DIR}/group_vars/all/." >&2
    exit 1
  fi
  breakglass_file="$(expand_local_path "${breakglass_file}")"
  if [ ! -r "${breakglass_file}" ]; then
    echo "ERROR: breakglass file not readable: ${breakglass_file}" >&2
    echo "  Run the pre-seed provision first so the OpenBao role can write it." >&2
    exit 1
  fi

  # Pull the first <threshold> Shamir shares. The threshold is read from the
  # break-glass JSON (the openbao role writes shamir_threshold — sandbox is 1,
  # lab/cloud is 3); default 3 for legacy files that predate the field.
  local threshold
  threshold="$(jq -r '(.shamir_threshold // 3) | tonumber' "${breakglass_file}" 2>/dev/null)" || threshold=3
  [ "${threshold}" -ge 1 ] 2>/dev/null || threshold=3
  local shares
  shares="$(jq -r --argjson threshold "${threshold}" '(.unseal_keys_hex // []) | .[0:$threshold] | .[]' "${breakglass_file}" 2>/dev/null)" || shares=""
  if [ "$(printf '%s\n' "${shares}" | grep -c .)" -lt "${threshold}" ]; then
    echo "ERROR: breakglass file lacks ${threshold} unseal_keys_hex shares (threshold ${threshold}): ${breakglass_file}" >&2
    exit 1
  fi

  # Cancel any stale generate-root attempt left behind by a previous failed run.
  remote_kubectl exec -n openbao "${BAO_POD}" -- bao operator generate-root -cancel >/dev/null 2>&1 || true

  # Generate OTP for the root-generation ceremony.
  local otp
  otp="$(remote_kubectl exec -n openbao "${BAO_POD}" -- bao operator generate-root -generate-otp -format=json 2>/dev/null | jq -r '.otp // empty')"
  if [ -z "${otp}" ]; then
    echo "ERROR: failed to generate root-generation OTP" >&2
    exit 1
  fi

  # Init the ceremony with the OTP and capture the nonce.
  local nonce
  nonce="$(remote_kubectl exec -n openbao "${BAO_POD}" -- bao operator generate-root -init -otp="${otp}" -format=json 2>/dev/null | jq -r '.nonce // empty')"
  if [ -z "${nonce}" ]; then
    echo "ERROR: failed to start root-generation attempt" >&2
    exit 1
  fi

  # Submit each share via stdin. The last share's response carries
  # `encoded_token` (older bao versions used `encoded_root_token`).
  local share encoded_token=""
  while IFS= read -r share; do
    [ -n "${share}" ] || continue
    local result
    result="$(printf '%s' "${share}" | remote_kubectl exec -i -n openbao "${BAO_POD}" -- bao operator generate-root -nonce="${nonce}" -format=json -)" || {
      echo "ERROR: Shamir share submission failed" >&2
      remote_kubectl exec -n openbao "${BAO_POD}" -- bao operator generate-root -cancel >/dev/null 2>&1 || true
      exit 1
    }
    encoded_token="$(printf '%s' "${result}" | jq -r '.encoded_token // .encoded_root_token // empty')"
    [ -n "${encoded_token}" ] && break
  done <<EOF
${shares}
EOF

  if [ -z "${encoded_token}" ]; then
    echo "ERROR: no encoded root token returned after submitting shares" >&2
    remote_kubectl exec -n openbao "${BAO_POD}" -- bao operator generate-root -cancel >/dev/null 2>&1 || true
    exit 1
  fi

  # Decode the encoded token using the OTP to get the real one-shot root token.
  local decoded
  decoded="$(printf '%s' "${encoded_token}" | remote_kubectl exec -i -n openbao "${BAO_POD}" -- bao operator generate-root -decode=- -otp="${otp}" -format=json)"
  BAO_ROOT_TOKEN="$(printf '%s' "${decoded}" | jq -r '.token // .data.token // empty')"
  if [ -z "${BAO_ROOT_TOKEN}" ]; then
    echo "ERROR: failed to decode root token" >&2
    exit 1
  fi
}

revoke_temp_root() {
  [ -n "${BAO_ROOT_TOKEN:-}" ] || return 0
  [ -n "${BAO_POD:-}" ] || return 0

  printf '%s\n' "${BAO_ROOT_TOKEN}" | \
    remote_kubectl exec -i -n openbao "${BAO_POD}" -- sh -c '
      IFS= read -r BAO_TOKEN
      export BAO_ADDR=https://127.0.0.1:8200 BAO_TOKEN
      bao token revoke -self
    ' >/dev/null 2>&1 || true

  BAO_ROOT_TOKEN=""
}

# bao_kv_get PATH — read a path with the temp root token; emits JSON or
# nothing on miss/error. Caller treats empty as "not present".
# Stderr suppression covers both bao's own "No value found at..." noise and
# kubectl's "command terminated with exit code N" message on miss.
bao_kv_get() {
  local path="$1"
  {
    printf '%s\n' "${BAO_ROOT_TOKEN}" | \
      remote_kubectl exec -i -n openbao "${BAO_POD}" -- sh -c '
        IFS= read -r BAO_TOKEN
        export BAO_ADDR=https://127.0.0.1:8200 BAO_TOKEN
        bao kv get -format=json "$1" 2>/dev/null
      ' bao_kv_get "${path}"
  } 2>/dev/null
}

cmd_seed_bao() {
  # TODO(adr-0011-trigger): bao kv put inside the OpenBao pod exposes
  # secret values via argv (sh -c expansion). Operator-side stdin transport
  # is clean; pod-internal hardening defers to move-2 or ADR-0011 triggers
  # (public/OSS, external collaborators). See review §CONCERN 2.
  require_env_name "${1:-}"
  local env_name="$1"

  require_sops
  require_age_key
  resolve_env_or_die "$env_name"
  require_bundle_exists "${env_name}"
  require_bundle_decryptable "${env_name}"
  validate_bundle_schema "${env_name}"
  resolve_remote_kubectl "${env_name}"

  # Find OpenBao pod
  BAO_POD="$(remote_kubectl get pods -n openbao -l app.kubernetes.io/name=openbao -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" || {
    echo "ERROR: no OpenBao pod found in namespace 'openbao'" >&2
    echo "  Is OpenBao installed? Run the pre-seed provision first." >&2
    exit 1
  }

  echo "Using OpenBao pod: ${BAO_POD}" >&2

  # Check OpenBao is unsealed
  local seal_status
  seal_status="$(remote_kubectl exec -n openbao "${BAO_POD}" -- bao status -format=json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
print('sealed' if data.get('sealed', True) else 'unsealed')
")" || {
    echo "ERROR: cannot reach OpenBao — is it initialized?" >&2
    exit 1
  }

  if [ "${seal_status}" = "sealed" ]; then
    echo "ERROR: OpenBao is sealed. Unseal it first:" >&2
    echo "  bin/unseal-openbao.sh ${env_name}" >&2
    exit 1
  fi

  echo "OpenBao is unsealed." >&2

  # Acquire a one-shot root token via the Shamir share quorum so the writes
  # below succeed (no policy grants secret/data/platform/* to ops-admin).
  echo "Acquiring temporary root token via Shamir share quorum..." >&2
  acquire_temp_root "${env_name}"
  trap 'revoke_temp_root' EXIT INT TERM

  # Read values from bundle (never print them)
  local admin_username admin_email admin_password k3s_token base_domain
  admin_username="$(bundle_field "${env_name}" bootstrap_admin.username)"
  admin_email="$(bundle_field "${env_name}" bootstrap_admin.email)"
  admin_password="$(bundle_field "${env_name}" bootstrap_admin.password)"
  k3s_token="$(bundle_field "${env_name}" cluster.k3s_token)"
  # base_domain is used to synthesise per-app admin emails for apps whose
  # auth backend identifies the bootstrap admin row by email (Authentik).
  # See the per-app loop below for why this matters.
  base_domain="$(bundle_field "${env_name}" metadata.base_domain 2>/dev/null)" || base_domain=""

  # Check if target paths already exist — collision detection
  local existing_platform_admin
  existing_platform_admin="$(bao_kv_get secret/platform/bootstrap_admin)" || existing_platform_admin=""

  if [ -n "${existing_platform_admin}" ]; then
    local existing_uname
    existing_uname="$(echo "${existing_platform_admin}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('data', {}).get('data', {}).get('username', ''))
" 2>/dev/null)" || existing_uname=""

    if [ "${existing_uname}" != "${admin_username}" ]; then
      echo "ERROR: secret/platform/bootstrap_admin exists with different value." >&2
      echo "  Current username: ${existing_uname}" >&2
      echo "  Bundle username:  ${admin_username}" >&2
      echo "  Use 'rotate' subcommand to deliberately overwrite." >&2
      exit 1
    fi
    echo "  secret/platform/bootstrap_admin: same value, no-op" >&2
  else
    echo "  Writing secret/platform/bootstrap_admin..." >&2
    printf '%s\n%s\n%s\n%s\n' "${BAO_ROOT_TOKEN}" "${admin_username}" "${admin_email}" "${admin_password}" | \
      remote_kubectl exec -i -n openbao "${BAO_POD}" -- sh -c '
        IFS= read -r BAO_TOKEN
        export BAO_ADDR=https://127.0.0.1:8200 BAO_TOKEN
        IFS= read -r USERNAME
        IFS= read -r EMAIL
        IFS= read -r PASSWORD
        bao kv put secret/platform/bootstrap_admin \
          username="${USERNAME}" \
          email="${EMAIL}" \
          password="${PASSWORD}"
      ' || {
      echo "ERROR: failed to write secret/platform/bootstrap_admin" >&2
      exit 1
    }
  fi

  # Write cluster path
  local existing_k3s
  existing_k3s="$(bao_kv_get secret/platform/k3s/cluster)" || existing_k3s=""

  if [ -n "${existing_k3s}" ]; then
    echo "  secret/platform/k3s/cluster: already exists, skipping" >&2
  else
    echo "  Writing secret/platform/k3s/cluster..." >&2
    printf '%s\n%s\n' "${BAO_ROOT_TOKEN}" "${k3s_token}" | \
      remote_kubectl exec -i -n openbao "${BAO_POD}" -- sh -c '
        IFS= read -r BAO_TOKEN
        export BAO_ADDR=https://127.0.0.1:8200 BAO_TOKEN
        IFS= read -r K3S_TOKEN
        bao kv put secret/platform/k3s/cluster token="${K3S_TOKEN}"
      ' || {
      echo "ERROR: failed to write secret/platform/k3s/cluster" >&2
      exit 1
    }
  fi

  # Write provider paths. Tolerate both legacy (providers.hcloud.token)
  # and new (providers.hetzner.cloud_token) schemas; the wizard renders
  # the new shape, hand-rolled bundles may use the legacy shape.
  local hcloud_token cf_dns_token ts_authkey ntfy_url healthchecks_url
  hcloud_token="$(bundle_field "${env_name}" providers.hcloud.token)" || hcloud_token=""
  if [ -z "${hcloud_token}" ]; then
    hcloud_token="$(bundle_field "${env_name}" providers.hetzner.cloud_token)" || hcloud_token=""
  fi
  cf_dns_token="$(bundle_field "${env_name}" providers.cloudflare.dns_token)" || cf_dns_token=""
  ts_authkey="$(bundle_field "${env_name}" providers.tailscale.authkey)" || ts_authkey=""
  ntfy_url="$(bundle_field "${env_name}" notifications.ntfy_url)" || ntfy_url=""
  healthchecks_url="$(bundle_field "${env_name}" notifications.healthchecks_url)" || healthchecks_url=""
  local alicloud_access_key alicloud_secret_key
  alicloud_access_key="$(bundle_field "${env_name}" providers.alicloud.access_key)" || alicloud_access_key=""
  alicloud_secret_key="$(bundle_field "${env_name}" providers.alicloud.secret_key)" || alicloud_secret_key=""
  # Tolerate the providers.aliyun.* alias used by some new-schema bundles.
  if [ -z "${alicloud_access_key}" ]; then
    alicloud_access_key="$(bundle_field "${env_name}" providers.aliyun.access_key)" || alicloud_access_key=""
  fi
  if [ -z "${alicloud_secret_key}" ]; then
    alicloud_secret_key="$(bundle_field "${env_name}" providers.aliyun.secret_key)" || alicloud_secret_key=""
  fi
  # AWS — new wizard schema only.
  local aws_access_key_id aws_secret_access_key aws_region
  aws_access_key_id="$(bundle_field "${env_name}" providers.aws.access_key_id)" || aws_access_key_id=""
  aws_secret_access_key="$(bundle_field "${env_name}" providers.aws.secret_access_key)" || aws_secret_access_key=""
  aws_region="$(bundle_field "${env_name}" providers.aws.region)" || aws_region=""


  # Hetzner
  local existing_hcloud
  existing_hcloud="$(bao_kv_get secret/platform/hetzner)" || existing_hcloud=""
  if [ -z "${existing_hcloud}" ] && [ -n "${hcloud_token}" ]; then
    echo "  Writing secret/platform/hetzner..." >&2
    printf '%s\n%s\n' "${BAO_ROOT_TOKEN}" "${hcloud_token}" | \
      remote_kubectl exec -i -n openbao "${BAO_POD}" -- sh -c '
        IFS= read -r BAO_TOKEN
        export BAO_ADDR=https://127.0.0.1:8200 BAO_TOKEN
        IFS= read -r TOKEN
        bao kv put secret/platform/hetzner token="${TOKEN}"
      '
  elif [ -n "${existing_hcloud}" ]; then
    echo "  secret/platform/hetzner: already exists, skipping" >&2
  fi

  # Alicloud
  local existing_alicloud
  existing_alicloud="$(bao_kv_get secret/platform/alicloud)" || existing_alicloud=""
  if [ -z "${existing_alicloud}" ] && [ -n "${alicloud_access_key}" ]; then
    echo "  Writing secret/platform/alicloud..." >&2
    printf '%s\n%s\n%s\n' "${BAO_ROOT_TOKEN}" "${alicloud_access_key}" "${alicloud_secret_key}" | \
      remote_kubectl exec -i -n openbao "${BAO_POD}" -- sh -c '
        IFS= read -r BAO_TOKEN
        export BAO_ADDR=https://127.0.0.1:8200 BAO_TOKEN
        IFS= read -r ACCESS_KEY
        IFS= read -r SECRET_KEY
        bao kv put secret/platform/alicloud access_key="${ACCESS_KEY}" secret_key="${SECRET_KEY}"
      '
  elif [ -n "${existing_alicloud}" ]; then
    echo "  secret/platform/alicloud: already exists, skipping" >&2
  fi

  # AWS (new wizard schema; written only when present)
  local existing_aws
  existing_aws="$(bao_kv_get secret/platform/aws)" || existing_aws=""
  if [ -z "${existing_aws}" ] && [ -n "${aws_access_key_id}" ]; then
    echo "  Writing secret/platform/aws..." >&2
    printf '%s\n%s\n%s\n%s\n' "${BAO_ROOT_TOKEN}" "${aws_access_key_id}" "${aws_secret_access_key}" "${aws_region}" | \
      remote_kubectl exec -i -n openbao "${BAO_POD}" -- sh -c '
        IFS= read -r BAO_TOKEN
        export BAO_ADDR=https://127.0.0.1:8200 BAO_TOKEN
        IFS= read -r ACCESS_KEY_ID
        IFS= read -r SECRET_ACCESS_KEY
        IFS= read -r REGION
        bao kv put secret/platform/aws access_key_id="${ACCESS_KEY_ID}" secret_access_key="${SECRET_ACCESS_KEY}" region="${REGION}"
      '
  elif [ -n "${existing_aws}" ]; then
    echo "  secret/platform/aws: already exists, skipping" >&2
  fi

  # Cloudflare
  local existing_cf
  existing_cf="$(bao_kv_get secret/platform/cloudflare)" || existing_cf=""
  if [ -z "${existing_cf}" ] && [ -n "${cf_dns_token}" ]; then
    echo "  Writing secret/platform/cloudflare..." >&2
    printf '%s\n%s\n' "${BAO_ROOT_TOKEN}" "${cf_dns_token}" | \
      remote_kubectl exec -i -n openbao "${BAO_POD}" -- sh -c '
        IFS= read -r BAO_TOKEN
        export BAO_ADDR=https://127.0.0.1:8200 BAO_TOKEN
        IFS= read -r TOKEN
        bao kv put secret/platform/cloudflare dns_token="${TOKEN}"
      '
  elif [ -n "${existing_cf}" ]; then
    echo "  secret/platform/cloudflare: already exists, skipping" >&2
  fi

  # Tailscale
  local existing_ts
  existing_ts="$(bao_kv_get secret/platform/tailscale)" || existing_ts=""
  if [ -z "${existing_ts}" ] && [ -n "${ts_authkey}" ]; then
    echo "  Writing secret/platform/tailscale..." >&2
    printf '%s\n%s\n' "${BAO_ROOT_TOKEN}" "${ts_authkey}" | \
      remote_kubectl exec -i -n openbao "${BAO_POD}" -- sh -c '
        IFS= read -r BAO_TOKEN
        export BAO_ADDR=https://127.0.0.1:8200 BAO_TOKEN
        IFS= read -r TOKEN
        bao kv put secret/platform/tailscale authkey="${TOKEN}"
      '
  elif [ -n "${existing_ts}" ]; then
    echo "  secret/platform/tailscale: already exists, skipping" >&2
  fi

  # Notifications
  local existing_notif
  existing_notif="$(bao_kv_get secret/platform/notifications)" || existing_notif=""
  if [ -z "${existing_notif}" ]; then
    local has_notif=false
    if [ -n "${ntfy_url}" ] || [ -n "${healthchecks_url}" ]; then
      has_notif=true
    fi
    if [ "${has_notif}" = "true" ]; then
      echo "  Writing secret/platform/notifications..." >&2
      printf '%s\n%s\n%s\n' "${BAO_ROOT_TOKEN}" "${ntfy_url}" "${healthchecks_url}" | \
        remote_kubectl exec -i -n openbao "${BAO_POD}" -- sh -c '
          IFS= read -r BAO_TOKEN
          export BAO_ADDR=https://127.0.0.1:8200 BAO_TOKEN
          IFS= read -r NTFY_URL
          IFS= read -r HC_URL
          bao kv put secret/platform/notifications \
            ntfy_url="${NTFY_URL}" \
            healthchecks_url="${HC_URL}"
        '
    fi
  else
    echo "  secret/platform/notifications: already exists, skipping" >&2
  fi

  # Write app-local admin compatibility copies. Username is per-app
  # conventional — it must match what each app's installer creates in
  # the app's own auth backend. Otherwise consumers reading
  # `secret/apps/<app>/admin` from OpenBao end up with creds that don't
  # work against the app. Password is always the shared bootstrap admin
  # password.
  #
  #   authentik → akadmin   (Authentik role hardcodes this; matches
  #                          110-authentik.yml `app_admin_expected_username`)
  #   zot       → admin     (Zot role hardcodes this; matches
  #                          191-zot-oidc.yml `app_admin_expected_username`
  #                          and the htpasswd basic-auth that cms/awx/etc.
  #                          present when pushing images)
  #   netbox    → netbox-break-glass  (NetBox role superuser_username; ADR-0028
  #                          D3 rename, roles/.../netbox/defaults/main.yml)
  #   grafana   → admin     (Grafana Helm chart default; OIDC handles real
  #                          user auth, but local admin is `admin/<pw>`)
  #   forgejo   → forgejo-break-glass (forgejo role default; ADR-0028 D3)
  #   awx       → awx-break-glass     (awx role awx_admin_user; ADR-0028 D3)
  #
  # Per ADR-0024/0028 the operator/human identity (Authentik) and per-app
  # local admins are SEPARATE layers: the operator username
  # (vault_bootstrap_admin_username) must NEVER be the app-local admin here.
  # The operator identity is seeded only for the Authentik human/passkey user,
  # not in this loop. A path still holding the operator identity from an older
  # seed is auto-migrated to the canonical account (see below).
  #
  # If the existing path holds a different username it could be either
  # (a) data written by an earlier seed-bao that didn't apply the
  # per-app convention — which the operator can `bao kv metadata delete`
  # then rerun — or (b) a deliberate operator change, which the script
  # protects by failing closed.
  # Email is shared (= bootstrap_admin.email) for every app EXCEPT
  # authentik. Authentik's blueprint 15-ops-user-webauthn.yaml.j2 uses
  # the user row's `email` field as the upsert identifier — so giving
  # akadmin the same email as the operator's blueprint user causes the
  # blueprint to silently rename the akadmin row into the operator user,
  # leaving no `akadmin` for downstream tasks that look it up by
  # username (e.g. the bootstrap passkey invitation task setting
  # `created_by=akadmin`). Per Pre-Bao Bootstrap Secrets Design 2026-05-08
  # (Open Q9) and Bootstrap Implementation Handoff 2026-05-08 §51, akadmin
  # is meant to coexist with the shared admin, not be renamed.
  # Synthesise akadmin's email from metadata.base_domain (mirrors the
  # role default at vertical-security/110-authentik.yml line 16:
  # `akadmin@{{ cert_manager_cluster_domain }}`).
  for app in forgejo netbox grafana awx zot authentik; do
    local app_path="secret/apps/${app}/admin"
    local app_username app_email
    case "${app}" in
      authentik)   app_username="akadmin" ;;
      zot|grafana) app_username="admin" ;;
      netbox)      app_username="netbox-break-glass" ;;
      forgejo)     app_username="forgejo-break-glass" ;;
      awx)         app_username="awx-break-glass" ;;
      *)
        echo "ERROR: no canonical app-local admin username mapping for '${app}'." >&2
        echo "  Per ADR-0024/0028 the operator/human identity and per-app local" >&2
        echo "  admins are separate layers; app-local admin secrets use a fixed" >&2
        echo "  per-app account, never the operator identity. Add an explicit" >&2
        echo "  case above for this app." >&2
        exit 1
        ;;
    esac
    # ADR-0024/0028 canonical app-local-admin email: per-app, per-env synthetic
    # address that no real-world identity can claim. The OPERATOR's email must
    # NEVER appear at secret/apps/<app>/admin.email — app social_auth pipelines
    # (NetBox's associate_by_email, Forgejo's account_linking=auto, AWX SAML
    # default pipeline) would otherwise merge the operator's OIDC sign-in into
    # the pre-existing break-glass User row, hijacking the break-glass identity.
    # Spec set by the operator 2026-05-28 after a live hijack was observed on
    # zy9q-1015 (netbox-break-glass row showed operator name + email + superuser
    # ✓ after first OIDC sign-in). Pattern: <app>-<env>@<base-domain>.
    case "${app}" in
      authentik)
        if [ -n "${base_domain}" ]; then
          app_email="akadmin@${base_domain}"
        else
          app_email="akadmin@local.invalid"
        fi
        ;;
      *)
        if [ -n "${base_domain}" ]; then
          app_email="${app}-${env_name}@${base_domain}"
        else
          app_email="${app}-${env_name}@local.invalid"
        fi
        ;;
    esac

    local existing_app
    existing_app="$(bao_kv_get "${app_path}")" || existing_app=""

    if [ -n "${existing_app}" ]; then
      local existing_app_uname existing_app_email
      existing_app_uname="$(echo "${existing_app}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('data', {}).get('data', {}).get('username', ''))
" 2>/dev/null)" || existing_app_uname=""
      existing_app_email="$(echo "${existing_app}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('data', {}).get('data', {}).get('email', ''))
" 2>/dev/null)" || existing_app_email=""

      if [ "${existing_app_uname}" = "${app_username}" ] \
         && [ "${existing_app_email}" = "${app_email}" ]; then
        echo "  ${app_path}: same value, no-op" >&2
        continue
      fi

      # ADR-0024/0028 migration. A pre-convention seed-bao may have written a
      # non-canonical username into this app-local admin path (the OPERATOR
      # identity for forgejo/awx under the old `*` rule, or an old shared
      # default 'admin' for netbox / 'dmfadmin' anywhere), AND/OR the
      # OPERATOR'S EMAIL (the 2026-05-28 break-glass-email hijack class). Both
      # known legacy values are safe to rewrite to the canonical per-app
      # account. Any OTHER value looks like a deliberate operator change and
      # is left untouched (fail closed).
      if [ "${existing_app_uname}" != "${app_username}" ]; then
        case "${existing_app_uname}" in
          "${admin_username}"|admin|dmfadmin)
            echo "  ${app_path}: migrating legacy admin username '${existing_app_uname}' -> canonical '${app_username}' (ADR-0024/0028)" >&2
            ;;
          *)
            echo "ERROR: ${app_path} exists with username '${existing_app_uname}'," >&2
            echo "  which is neither the canonical app account ('${app_username}')" >&2
            echo "  nor a known legacy value. This looks like a deliberate change," >&2
            echo "  so it is not overwritten. Resolve by hand (purge + reseed):" >&2
            echo "    sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml -n openbao \\" >&2
            echo "      exec openbao-0 -- bao kv metadata delete '${app_path}'  # needs a bao token" >&2
            echo "  then rerun seed-bao." >&2
            exit 1
            ;;
        esac
      fi
      if [ "${existing_app_email}" != "${app_email}" ]; then
        case "${existing_app_email}" in
          ""|"${admin_email}"|admin@example.com|"${app_username}@example.com")
            echo "  ${app_path}: migrating legacy admin email '${existing_app_email}' -> canonical '${app_email}' (ADR-0024/0028)" >&2
            ;;
          *)
            echo "ERROR: ${app_path} exists with email '${existing_app_email}'," >&2
            echo "  which is neither the canonical app email ('${app_email}')" >&2
            echo "  nor a known legacy value (empty, operator email, admin@example.com)." >&2
            echo "  This looks like a deliberate change, so it is not overwritten." >&2
            echo "  Resolve by hand (purge + reseed)." >&2
            exit 1
            ;;
        esac
      fi
    fi
    # Write (new path) or overwrite (sanctioned operator-identity migration).
    echo "  Writing ${app_path} (username=${app_username})..." >&2
    printf '%s\n%s\n%s\n%s\n' "${BAO_ROOT_TOKEN}" "${app_username}" "${app_email}" "${admin_password}" | \
      remote_kubectl exec -i -n openbao "${BAO_POD}" -- sh -c '
        IFS= read -r BAO_TOKEN
        export BAO_ADDR=https://127.0.0.1:8200 BAO_TOKEN
        IFS= read -r UNAME
        IFS= read -r EMAIL
        IFS= read -r PASSWORD
        bao kv put '"${app_path}"' \
          username="${UNAME}" \
          email="${EMAIL}" \
          password="${PASSWORD}"
      ' || {
      echo "ERROR: failed to write ${app_path}" >&2
      exit 1
    }
  done

  # ── Zot machine-write service account (ADR-0033) ──────────────────────────
  # zot-svc is the scoped push account used by 331-registry-zot's htpasswd,
  # playbook 630, and zot-mirror — distinct from the break-glass `admin` seeded
  # above. Its password is an INDEPENDENT random secret stored in the bundle at
  # apps.zot.service_password (generated at `init`). It MUST live in the bundle
  # (not just OpenBao) because export-vars reads it from there to feed the Zot
  # htpasswd at pre-seed Layer 3, before OpenBao exists. Bundles predating
  # ADR-0033 lack it; generate + write it back here so existing envs migrate by
  # just re-running seed-bao (per ADR-0033 Consequences), then we copy the same
  # value into OpenBao at secret/apps/zot/service for ESO/zot-mirror to mount.
  local zot_service_password
  zot_service_password="$(bundle_field "${env_name}" apps.zot.service_password 2>/dev/null)" || zot_service_password=""
  if [ -z "${zot_service_password}" ]; then
    echo "  apps.zot.service_password: absent in bundle — generating (ADR-0033) and writing it back..." >&2
    zot_service_password="$(gen_secret 32 32)"
    bundle_set "${env_name}" apps.zot.service_password "${zot_service_password}"
    echo "  apps.zot.service_password: generated and persisted to the bundle." >&2
    echo "  NOTE: re-run the zot role (331-registry-zot) so the htpasswd picks up zot-svc." >&2
  fi

  local zot_svc_path="secret/apps/zot/service"
  local existing_zot_svc existing_zot_svc_uname
  existing_zot_svc="$(bao_kv_get "${zot_svc_path}")" || existing_zot_svc=""
  if [ -n "${existing_zot_svc}" ]; then
    existing_zot_svc_uname="$(echo "${existing_zot_svc}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('data', {}).get('data', {}).get('username', ''))
" 2>/dev/null)" || existing_zot_svc_uname=""
    if [ "${existing_zot_svc_uname}" = "zot-svc" ]; then
      echo "  ${zot_svc_path}: username already zot-svc, no-op" >&2
    else
      # Fail closed: a non-zot-svc username here is an unexpected, possibly
      # deliberate state — never silently overwrite it (mirrors the admin loop).
      echo "ERROR: ${zot_svc_path} exists with username '${existing_zot_svc_uname}'," >&2
      echo "  not the expected 'zot-svc'. Not overwriting. Resolve by hand:" >&2
      echo "    sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml -n openbao \\" >&2
      echo "      exec ${BAO_POD} -- bao kv metadata delete '${zot_svc_path}'  # needs a bao token" >&2
      echo "  then rerun seed-bao." >&2
      exit 1
    fi
  else
    echo "  Writing ${zot_svc_path} (username=zot-svc)..." >&2
    printf '%s\n%s\n' "${BAO_ROOT_TOKEN}" "${zot_service_password}" | \
      remote_kubectl exec -i -n openbao "${BAO_POD}" -- sh -c '
        IFS= read -r BAO_TOKEN
        export BAO_ADDR=https://127.0.0.1:8200 BAO_TOKEN
        IFS= read -r PASSWORD
        bao kv put secret/apps/zot/service \
          username="zot-svc" \
          password="${PASSWORD}"
      ' || {
      echo "ERROR: failed to write ${zot_svc_path}" >&2
      exit 1
    }
  fi

  # ── AWX autoscale internal bearer token (ADR-0008) ────────────────────────
  # The awx-autoscale helper validates POST /ensure-awake against this token;
  # dmf-cms sends it as the Authorization bearer. ESO materializes it from
  # secret/apps/awx-autoscale/runtime into the helper's pod env (ADR-0008).
  # NOT the awx_svc_token written by the awx-integration role 693.
  # Seed-once: never regenerate — rotation breaks dmf-cms/helper auth mid-flight.
  local awx_autoscale_path="secret/apps/awx-autoscale/runtime"
  local existing_awx_autoscale existing_awx_autoscale_bearer
  existing_awx_autoscale="$(bao_kv_get "${awx_autoscale_path}")" || existing_awx_autoscale=""
  if [ -n "${existing_awx_autoscale}" ]; then
    existing_awx_autoscale_bearer="$(echo "${existing_awx_autoscale}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('data', {}).get('data', {}).get('bearer_token', ''))
" 2>/dev/null)" || existing_awx_autoscale_bearer=""
    if [ -n "${existing_awx_autoscale_bearer}" ]; then
      echo "  ${awx_autoscale_path}: bearer_token present, no-op" >&2
    else
      echo "ERROR: ${awx_autoscale_path} exists but bearer_token is empty/missing." >&2
      echo "  Resolve by hand, then rerun seed-bao." >&2
      exit 1
    fi
  else
    # bao_kv_get returns empty for BOTH "not found" and a transient read
    # failure (it runs `bao kv get 2>/dev/null` and swallows the exit code).
    # Generating on a false "absent" would rotate the token out from under a
    # live dmf-cms/helper. Prove genuine absence before generating, in two
    # steps:
    #   1. Confirm reads work at all — read back a sentinel we wrote earlier
    #      this run (secret/platform/bootstrap_admin). Empty => reads broken =>
    #      fail closed.
    #   2. Re-read the awx-autoscale path itself. If a bearer now appears the
    #      first read was a transient blip => no-op. Only a confirmed-empty
    #      re-read (with reads proven working) counts as genuinely absent.
    if [ -z "$(bao_kv_get secret/platform/bootstrap_admin)" ]; then
      echo "ERROR: ${awx_autoscale_path} read empty AND the sentinel" >&2
      echo "  secret/platform/bootstrap_admin is also unreadable — OpenBao reads" >&2
      echo "  appear broken. Refusing to (re)generate the bearer token (it would" >&2
      echo "  rotate under a live dmf-cms). Fix OpenBao access, then rerun seed-bao." >&2
      exit 1
    fi
    local reread_awx_autoscale_bearer
    reread_awx_autoscale_bearer="$(bao_kv_get "${awx_autoscale_path}" | python3 -c "
import json, sys
try:
    print(json.load(sys.stdin).get('data', {}).get('data', {}).get('bearer_token', ''))
except Exception:
    print('')
" 2>/dev/null)" || reread_awx_autoscale_bearer=""
    if [ -n "${reread_awx_autoscale_bearer}" ]; then
      echo "  ${awx_autoscale_path}: bearer_token present on re-read (first read was transient), no-op" >&2
    else
      local bearer
      bearer="$(gen_secret 48 64)"
      echo "  Writing ${awx_autoscale_path} (bearer_token)..." >&2
      printf '%s\n%s\n' "${BAO_ROOT_TOKEN}" "${bearer}" | \
        remote_kubectl exec -i -n openbao "${BAO_POD}" -- sh -c '
          IFS= read -r BAO_TOKEN
          export BAO_ADDR=https://127.0.0.1:8200 BAO_TOKEN
          IFS= read -r BEARER
          bao kv put secret/apps/awx-autoscale/runtime bearer_token="${BEARER}"
        ' || {
        echo "ERROR: failed to write ${awx_autoscale_path}" >&2
        exit 1
      }
    fi
  fi

  # Write object-storage paths
  for os_logical in audit openbao_snapshots app_backups; do
    local os_bucket os_endpoint os_region os_access_key os_secret_key
    os_bucket="$(bundle_field "${env_name}" "object_storage.${os_logical}.bucket" 2>/dev/null)" || os_bucket=""
    os_endpoint="$(bundle_field "${env_name}" "object_storage.${os_logical}.endpoint" 2>/dev/null)" || os_endpoint=""
    os_region="$(bundle_field "${env_name}" "object_storage.${os_logical}.region" 2>/dev/null)" || os_region=""
    os_access_key="$(bundle_field "${env_name}" "object_storage.${os_logical}.access_key_id" 2>/dev/null)" || os_access_key=""
    os_secret_key="$(bundle_field "${env_name}" "object_storage.${os_logical}.secret_access_key" 2>/dev/null)" || os_secret_key=""

    # Skip if bucket is empty (not configured for this env)
    if [ -z "${os_bucket}" ]; then
      echo "  object_storage.${os_logical}: bucket empty, skipping" >&2
      continue
    fi

    local os_path="secret/platform/object-storage/${os_logical}"
    local existing_os
    existing_os="$(bao_kv_get "${os_path}")" || existing_os=""

    if [ -n "${existing_os}" ]; then
      echo "  ${os_path}: already exists, skipping" >&2
    else
      echo "  Writing ${os_path}..." >&2
      printf '%s\n%s\n%s\n%s\n%s\n%s\n' "${BAO_ROOT_TOKEN}" "${os_bucket}" "${os_endpoint}" "${os_region}" "${os_access_key}" "${os_secret_key}" | \
        remote_kubectl exec -i -n openbao "${BAO_POD}" -- sh -c '
          IFS= read -r BAO_TOKEN
          export BAO_ADDR=https://127.0.0.1:8200 BAO_TOKEN
          IFS= read -r BUCKET
          IFS= read -r ENDPOINT
          IFS= read -r REGION
          IFS= read -r ACCESS_KEY
          IFS= read -r SECRET_KEY
          bao kv put '"${os_path}"' \
            bucket="${BUCKET}" \
            endpoint="${ENDPOINT}" \
            region="${REGION}" \
            access_key_id="${ACCESS_KEY}" \
            secret_access_key="${SECRET_KEY}"
        ' || {
        echo "ERROR: failed to write ${os_path}" >&2
        exit 1
      }
    fi
  done

  # Update bundle metadata timestamp
  local tmp_yaml
  local tmp_yaml_dir
  tmp_yaml_dir="$(mktemp -d)"
  # Temp name = bundle basename so it matches the bundle's creation_rule (see
  # bundle_set for the full rationale).
  tmp_yaml="${tmp_yaml_dir}/$(basename "${DMF_ENV_BUNDLE_FILE}")"
  trap 'rm -rf "${tmp_yaml_dir}"' RETURN

  # sops's default output for a .sops.yaml input is YAML — round-trip via
  # JSON for the python edit, then encrypt-back-as-YAML to match the file
  # extension and the original on-disk format.
  sops --decrypt --output-type json "${DMF_ENV_BUNDLE_FILE}" 2>/dev/null | python3 -c "
import json, sys, datetime
data = json.load(sys.stdin)
data['metadata']['last_seeded_to_bao_at'] = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
print(json.dumps(data, indent=2))
" > "${tmp_yaml}"

  local meta_sops_cfg
  meta_sops_cfg="$(bundle_sops_config_file)"
  if [ -n "${meta_sops_cfg}" ]; then
    sops --config "${meta_sops_cfg}" --encrypt --input-type json --output-type yaml "${tmp_yaml}" > "${DMF_ENV_BUNDLE_FILE}.tmp" || { rm -f "${DMF_ENV_BUNDLE_FILE}.tmp"; echo "ERROR: sops --encrypt failed for metadata writeback (bundle left untouched)" >&2; return 1; }
  else
    sops --encrypt --input-type json --output-type yaml "${tmp_yaml}" > "${DMF_ENV_BUNDLE_FILE}.tmp" || { rm -f "${DMF_ENV_BUNDLE_FILE}.tmp"; echo "ERROR: sops --encrypt failed for metadata writeback (bundle left untouched)" >&2; return 1; }
  fi
  chmod 0600 "${DMF_ENV_BUNDLE_FILE}.tmp"
  mv "${DMF_ENV_BUNDLE_FILE}.tmp" "${DMF_ENV_BUNDLE_FILE}"
  chmod 0600 "${DMF_ENV_BUNDLE_FILE}"

  echo "" >&2
  echo "seed-bao complete for ${env_name}" >&2
}

cmd_seed_awx_ssh() {
  # TODO(adr-0011-trigger): bao kv put argv exposure inside the OpenBao pod.
  # Operator-side stdin transport is clean; pod-internal hardening defers
  # to move-2 or ADR-0011 triggers. See review §CONCERN 2.
  require_env_name "${1:-}"
  local env_name="$1"
  resolve_env_or_die "$env_name"

  # Require the SSH key path env var (fail-closed per A4)
  if [ -z "${DMF_AWX_CONTROL_NODE_SSH_PATH:-}" ]; then
    echo "ERROR: DMF_AWX_CONTROL_NODE_SSH_PATH is not set." >&2
    echo "  Set it to the path of the AWX control-node SSH private key." >&2
    echo "  Example: export DMF_AWX_CONTROL_NODE_SSH_PATH=${HOME}/secure/awx-control-node.privkey" >&2
    exit 1
  fi

  if [ ! -f "${DMF_AWX_CONTROL_NODE_SSH_PATH}" ]; then
    echo "ERROR: SSH key file not found: ${DMF_AWX_CONTROL_NODE_SSH_PATH}" >&2
    exit 1
  fi

  # Validate it's a private key
  if ! head -1 "${DMF_AWX_CONTROL_NODE_SSH_PATH}" | grep -q "PRIVATE KEY"; then
    echo "ERROR: file does not appear to be an SSH private key: ${DMF_AWX_CONTROL_NODE_SSH_PATH}" >&2
    exit 1
  fi

  resolve_remote_kubectl "${env_name}"

  local ssh_key_data
  ssh_key_data="$(cat "${DMF_AWX_CONTROL_NODE_SSH_PATH}")"

  # Find OpenBao pod
  BAO_POD="$(remote_kubectl get pods -n openbao -l app.kubernetes.io/name=openbao -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" || {
    echo "ERROR: no OpenBao pod found in namespace 'openbao'" >&2
    exit 1
  }

  # Check OpenBao is unsealed
  local seal_status
  seal_status="$(remote_kubectl exec -n openbao "${BAO_POD}" -- bao status -format=json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
print('sealed' if data.get('sealed', True) else 'unsealed')
")" || {
    echo "ERROR: cannot reach OpenBao" >&2
    exit 1
  }

  if [ "${seal_status}" = "sealed" ]; then
    echo "ERROR: OpenBao is sealed. Unseal it first." >&2
    exit 1
  fi

  # Acquire one-shot root token via Shamir share quorum (same pattern as
  # cmd_seed_bao). Strictly speaking secret/apps/awx/control_node_ssh is
  # within ops-admin's app-admin-writer policy scope, but using the temp
  # root keeps both seed paths consistent and avoids a second auth flow.
  echo "Acquiring temporary root token via Shamir share quorum..." >&2
  acquire_temp_root "${env_name}"
  trap 'revoke_temp_root' EXIT INT TERM

  # Check for existing value — idempotent
  local existing
  existing="$(bao_kv_get secret/apps/awx/control_node_ssh)" || existing=""

  if [ -n "${existing}" ]; then
    # Compare fingerprints (cheaper than comparing full key)
    local existing_fp new_fp
    existing_fp="$(echo "${existing}" | python3 -c "
import json, sys, hashlib
data = json.load(sys.stdin)
key = data.get('data', {}).get('data', {}).get('ssh_key_data', '')
if key:
    print(hashlib.sha256(key.encode()).hexdigest()[:16])
else:
    print('')
" 2>/dev/null)" || existing_fp=""

    new_fp="$(echo "${ssh_key_data}" | python3 -c "
import sys, hashlib
key = sys.stdin.read()
if key:
    print(hashlib.sha256(key.encode()).hexdigest()[:16])
" 2>/dev/null)" || new_fp=""

    if [ "${existing_fp}" = "${new_fp}" ] && [ -n "${existing_fp}" ]; then
      echo "secret/apps/awx/control_node_ssh: same key, no-op" >&2
      exit 0
    else
      echo "ERROR: secret/apps/awx/control_node_ssh exists with different key." >&2
      echo "  Existing fingerprint: ${existing_fp}" >&2
      echo "  New fingerprint:      ${new_fp}" >&2
      echo "  Deliberate operator action required to rotate." >&2
      exit 1
    fi
  fi

  echo "Writing secret/apps/awx/control_node_ssh..." >&2
  # Token first line, then the multi-line SSH key (read until EOF).
  { printf '%s\n' "${BAO_ROOT_TOKEN}"; printf '%s' "${ssh_key_data}"; } | \
    remote_kubectl exec -i -n openbao "${BAO_POD}" -- sh -c '
      IFS= read -r BAO_TOKEN
      export BAO_ADDR=https://127.0.0.1:8200 BAO_TOKEN
      SSH_KEY_DATA="$(cat)"
      bao kv put secret/apps/awx/control_node_ssh ssh_key_data="${SSH_KEY_DATA}"
    ' || {
    echo "ERROR: failed to write secret/apps/awx/control_node_ssh" >&2
    exit 1
  }

  echo "seed-awx-control-node-ssh complete for ${env_name}" >&2
}

cmd_status() {
  require_env_name "${1:-}"
  local env_name="$1"
  require_sops
  resolve_env_or_die "$env_name"

  local bundle="${DMF_ENV_BUNDLE_FILE}"

  echo "=== status: ${env_name} ===" >&2

  # Bundle existence
  if [ -f "${bundle}" ]; then
    echo "  bundle: exists (${bundle})" >&2
  else
    echo "  bundle: MISSING" >&2
    exit 1
  fi

  # Decryptable
  if sops --decrypt "${bundle}" &>/dev/null; then
    echo "  decryptable: yes" >&2
  else
    echo "  decryptable: NO" >&2
    exit 1
  fi

  # Metadata (no secret values). Tolerant of both legacy and new schemas:
  # legacy bundles set metadata.environment; new bundles set
  # metadata.env_id plus metadata.provider/architecture/env_label.
  sops --decrypt --output-type json "${bundle}" 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
meta = data.get('metadata', {})
env_label = meta.get('env_id') or meta.get('environment', 'unknown')
schema_version = meta.get('schema_version', data.get('schema_version', 'unknown'))
print(f'  schema_version:       {schema_version}')
print(f'  environment (env_id): {env_label}')
if meta.get('env_label'):
    print(f'  env_label:            {meta[\"env_label\"]}')
if meta.get('provider'):
    print(f'  provider:             {meta[\"provider\"]}')
if meta.get('architecture'):
    print(f'  architecture:         {meta[\"architecture\"]}')
print(f'  base_domain:          {meta.get(\"base_domain\", \"unknown\")}')
print(f'  created_at:           {meta.get(\"created_at\", \"unknown\")}')
print(f'  last_validated_at:    {meta.get(\"last_validated_at\", \"never\")}')
print(f'  last_seeded_to_bao_at:{meta.get(\"last_seeded_to_bao_at\", \"never\")}')

# Required fields presence check (no values printed)
admin = data.get('bootstrap_admin', {})
print(f'  bootstrap_admin.username: {\"present\" if admin.get(\"username\") else \"MISSING\"}')
print(f'  bootstrap_admin.email: {\"present\" if admin.get(\"email\") else \"MISSING\"}')
print(f'  bootstrap_admin.password: {\"present\" if admin.get(\"password\") else \"MISSING\"}')
print(f'  cluster.k3s_token: {\"present\" if data.get(\"cluster\", {}).get(\"k3s_token\") else \"MISSING\"}')

# Provider token presence (check both legacy and new key paths).
providers = data.get('providers', {})
hcloud_legacy = providers.get('hcloud', {}).get('token')
hetzner_new   = providers.get('hetzner', {}).get('cloud_token')
ali_legacy    = providers.get('alicloud', {}).get('access_key')
ali_new       = providers.get('aliyun', {}).get('access_key')
aws_new       = providers.get('aws', {}).get('access_key_id')
if hcloud_legacy or hetzner_new:
    label = 'providers.hetzner.cloud_token' if hetzner_new else 'providers.hcloud.token'
    print(f'  {label}: present')
elif ali_legacy or ali_new:
    label = 'providers.alicloud.access_key' if ali_legacy else 'providers.aliyun.access_key'
    print(f'  {label}: present')
elif aws_new:
    print('  providers.aws.access_key_id: present')
else:
    print('  provider token: MISSING (no hetzner/aliyun/aws keys found)')
"
}

cmd_rotate() {
  require_env_name "${1:-}"
  local env_name="$1"
  local field="${2:-}"

  if [ -z "${field}" ]; then
    echo "ERROR: field name required" >&2
    echo "  Usage: bin/bootstrap-secrets.sh rotate <env> <field>" >&2
    echo "  Fields: bootstrap_admin.password, cluster.k3s_token" >&2
    exit 1
  fi

  require_sops
  require_age_key
  resolve_env_or_die "$env_name"
  require_bundle_exists "${env_name}"
  require_bundle_decryptable "${env_name}"

  case "${field}" in
    bootstrap_admin.password)
      echo "Generating new bootstrap admin password..." >&2
      local new_pw
      new_pw="$(gen_secret 32 32)"
      bundle_set "${env_name}" bootstrap_admin.password "${new_pw}"
      echo "  bootstrap_admin.password rotated" >&2
      echo "  NOTE: you must also update apps that consumed the old value." >&2
      ;;
    cluster.k3s_token)
      echo "ERROR: rotating cluster.k3s_token requires node re-join." >&2
      echo "  This is NOT a bootstrap operation. See lifecycle-operate.yml." >&2
      exit 1
      ;;
    *)
      echo "ERROR: unknown field '${field}'" >&2
      echo "  Supported: bootstrap_admin.password, cluster.k3s_token" >&2
      exit 1
      ;;
  esac
}

# ──────────────────────────────────────────────────────────────
# Migration helpers
# ──────────────────────────────────────────────────────────────

cmd_set_base_domain() {
  require_env_name "${1:-}"
  local env_name="$1"
  local domain="${2:-}"

  if [ -z "${domain}" ]; then
    echo "ERROR: domain required" >&2
    echo "  Usage: bin/bootstrap-secrets.sh set-base-domain <env> <domain>" >&2
    exit 1
  fi

  require_sops
  resolve_env_or_die "$env_name"
  require_bundle_exists "${env_name}"

  local bundle="${DMF_ENV_BUNDLE_FILE}"

  # Normalize: strip protocol and path
  domain="$(echo "${domain}" | sed 's|^https\?://||; s|/.*||; s|^[[:space:]]*||; s|[[:space:]]*$||')"

  # Validate domain shape
  if ! echo "${domain}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$'; then
    echo "ERROR: invalid domain '${domain}'" >&2
    echo "  Must be a valid domain (e.g. lab.example.com)" >&2
    exit 1
  fi

  echo "Setting metadata.base_domain = ${domain} for ${env_name}..." >&2

  # Use sops set to update only this field without exposing the full bundle
  sops set "${bundle}" '["metadata"]["base_domain"]' ""${domain}""

  echo "Done. Verify with: bin/bootstrap-secrets.sh doctor ${env_name}" >&2
}

# ──────────────────────────────────────────────────────────────
# Dispatch (only when executed, not sourced)
# ──────────────────────────────────────────────────────────────

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  SUBCOMMAND="${1:-}"
  shift || true

  case "${SUBCOMMAND}" in
    init)
      cmd_init "$@"
      ;;
    doctor)
      cmd_doctor "$@"
      ;;
    export-vars)
      cmd_export_vars "$@"
      ;;
    seed-bao)
      cmd_seed_bao "$@"
      ;;
    seed-awx-control-node-ssh)
      cmd_seed_awx_ssh "$@"
      ;;
    status)
      cmd_status "$@"
      ;;
    rotate)
      cmd_rotate "$@"
      ;;
    set-base-domain)
      cmd_set_base_domain "$@"
      ;;
    *)
      echo "Usage: bin/bootstrap-secrets.sh <subcommand> [args...]" >&2
      echo "" >&2
      echo "Subcommands:" >&2
      echo "  init <env>                      Create or update encrypted bundle" >&2
      echo "  doctor <env>                    Validate bundle and prerequisites" >&2
      echo "  export-vars <env> <json-out>    Decrypt bundle to Ansible vars JSON" >&2
      echo "  seed-bao <env>                  Seed platform + admin paths into OpenBao" >&2
      echo "  seed-awx-control-node-ssh <env> Seed AWX SSH privkey into OpenBao" >&2
      echo "  status <env>                    Report bundle/seed metadata" >&2
      echo "  rotate <env> <field>            Regenerate a specific field" >&2
      echo "  set-base-domain <env> <domain>  Set metadata.base_domain for migration" >&2
      exit 1
      ;;
  esac
fi
