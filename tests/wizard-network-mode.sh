#!/usr/bin/env bash
# wizard-network-mode.sh — the sandbox network mode and the approval page name.
#
# Hermetic: temp DMF_DATA_ROOT and SOPS_AGE_KEY_FILE; skips cleanly if a
# required tool is missing.
#
# Checks:
#   - no sandbox.network_mode key: lan, dmf-<env_id>.local
#   - public with sslip.io addressing: unlock.<dashed-ip>.sslip.io
#   - public with hosts addressing: rejected
#   - an unknown mode: rejected
#   - a key-less answers file renders the golden file plus the two new lines

set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "SKIP: $1 not on PATH"; exit 0; }
}

echo "=== wizard-network-mode test ==="

for cmd in sops age age-keygen yq python3 ssh-keygen bash; do
  need_cmd "$cmd"
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WIZARD="${REPO_DIR}/bin/init-wizard.sh"
GOLDEN="${REPO_DIR}/tests/fixtures/sandbox-main.yml.golden"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export DMF_DATA_ROOT="${WORK_DIR}/dmf-data"
export SOPS_AGE_KEY_FILE="${WORK_DIR}/age/keys.txt"
mkdir -p "${DMF_DATA_ROOT}" "${WORK_DIR}/age"
age-keygen -o "${SOPS_AGE_KEY_FILE}" >/dev/null 2>&1

# write_answers FILE [EXTRA_SANDBOX_LINE...]
write_answers() {
  local file="$1"
  shift
  {
    cat <<EOF
schema_version: 1
provider: sandbox
operator:
  username: marty-mcfly
  email: marty@dmf.test
  display: "Marty McFly"
sandbox:
  label: sandbox-demo
  node_ip: 203.0.113.10
  ansible_user: lima
  iface: lima0
  ssh_private_key_path: /fixed/key
EOF
    local line
    for line in "$@"; do
      printf '  %s\n' "$line"
    done
  } > "$file"
}

# run_wizard NAME [EXTRA_SANDBOX_LINE...]
# Sets RUN_STATUS, RUN_LOG and (on success) RUN_ENV_ID and RUN_MAIN.
run_wizard() {
  local name="$1"
  shift
  write_answers "${WORK_DIR}/${name}.yaml" "$@"
  RUN_LOG="${WORK_DIR}/${name}.log"
  RUN_STATUS=0
  bash "${WIZARD}" --non-interactive "${WORK_DIR}/${name}.yaml" >"${RUN_LOG}" 2>&1 || RUN_STATUS=$?
  RUN_ENV_ID=""
  RUN_MAIN=""
  if [ "${RUN_STATUS}" -eq 0 ]; then
    RUN_ENV_ID="$(grep -m1 '^  env_id:' "${RUN_LOG}" | awk '{print $2}')"
    [ -n "${RUN_ENV_ID}" ] || fail "${name}: could not parse env_id"
    RUN_MAIN="${DMF_DATA_ROOT}/envs/${RUN_ENV_ID}/inventory/group_vars/all/main.yml"
    [ -f "${RUN_MAIN}" ] || fail "${name}: main.yml missing"
  fi
}

# var_of FILE KEY: the value of a top-level scalar in the rendered group_vars.
var_of() {
  yq -r ".$2" "$1"
}

# ── Default: lan, dmf-<env_id>.local ──
# Catches: a default of public, or a name built from the base domain.
run_wizard default
[ "${RUN_STATUS}" -eq 0 ] || { cat "${RUN_LOG}" >&2; fail "default run failed"; }
[ "$(var_of "${RUN_MAIN}" dmf_network_mode)" = "lan" ] || fail "default mode is not lan"
[ "$(var_of "${RUN_MAIN}" dmf_approval_page_name)" = "dmf-${RUN_ENV_ID}.local" ] \
  || fail "default approval page is not dmf-${RUN_ENV_ID}.local"
# Catches: lan mode moving the console and other apps off the base domain.
[ "$(var_of "${RUN_MAIN}" dmf_sandbox_base_domain)" = "203-0-113-10.sslip.io" ] \
  || fail "lan mode changed the base domain"
DEFAULT_MAIN="${RUN_MAIN}"
DEFAULT_ENV_ID="${RUN_ENV_ID}"

# ── Explicit lan equals the default ──
# Catches: the key being read but ignored, or a different path for explicit lan.
run_wizard explicit-lan "network_mode: lan"
[ "${RUN_STATUS}" -eq 0 ] || { cat "${RUN_LOG}" >&2; fail "explicit lan run failed"; }
[ "$(var_of "${RUN_MAIN}" dmf_approval_page_name)" = "dmf-${RUN_ENV_ID}.local" ] \
  || fail "explicit lan approval page is wrong"

# ── Public with sslip.io: unlock.<base> ──
# Catches: public using the .local name, or a name that omits the base domain.
run_wizard public "network_mode: public"
[ "${RUN_STATUS}" -eq 0 ] || { cat "${RUN_LOG}" >&2; fail "public run failed"; }
[ "$(var_of "${RUN_MAIN}" dmf_network_mode)" = "public" ] || fail "public mode not rendered"
[ "$(var_of "${RUN_MAIN}" dmf_approval_page_name)" = "unlock.203-0-113-10.sslip.io" ] \
  || fail "public approval page is not unlock.203-0-113-10.sslip.io"

# ── Public with hosts addressing is rejected ──
# Catches: accepting a mode that has no public name.
run_wizard public-hosts "network_mode: public" "addressing: hosts"
[ "${RUN_STATUS}" -ne 0 ] || fail "public with hosts addressing was accepted"
grep -q "public needs sslip.io addressing" "${RUN_LOG}" || fail "public with hosts: message missing"

# ── Lan with hosts addressing still works ──
# Catches: a check that rejects hosts addressing in every mode.
run_wizard lan-hosts "addressing: hosts"
[ "${RUN_STATUS}" -eq 0 ] || { cat "${RUN_LOG}" >&2; fail "lan with hosts run failed"; }

# ── An unknown mode is rejected ──
# Catches: a case statement that falls through to lan or public.
run_wizard bad-mode "network_mode: wan"
[ "${RUN_STATUS}" -ne 0 ] || fail "invalid mode was accepted"
grep -q "invalid sandbox.network_mode: wan" "${RUN_LOG}" || fail "invalid mode: message missing"

# ── A key-less answers file renders as before, plus two lines ──
# Catches: any other change to the rendered group_vars.
sed -e "s|${DEFAULT_ENV_ID}|<ENV_ID>|g" \
    -e "s|${DMF_DATA_ROOT}|<DATA_ROOT>|g" \
    -e '/Generated by init-wizard.sh on/d' \
    "${DEFAULT_MAIN}" |
  # Mask private-range addresses so the fixture holds no network literals.
  sed -E 's/(^|[^0-9.])(10|192\.168)\.[0-9]+\.[0-9]+(\.[0-9]+)?/\1<PRIVATE-ADDR>/g' \
  > "${WORK_DIR}/default.norm"
added="$(diff "${GOLDEN}" "${WORK_DIR}/default.norm" | grep '^[<>]' || true)"
expected="$(printf '%s\n%s' \
  '> dmf_network_mode: lan' \
  '> dmf_approval_page_name: dmf-<ENV_ID>.local')"
[ "${added}" = "${expected}" ] || {
  diff -u "${GOLDEN}" "${WORK_DIR}/default.norm" >&2 || true
  fail "key-less render differs from the golden file by more than the two new lines"
}

echo "PASS: wizard-network-mode"
