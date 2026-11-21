#!/usr/bin/env bash
# inventory-var.sh — bin/lib/_inventory_var.sh reads a one-line YAML scalar, and reads
# the dmf_provider lines that init-wizard.sh writes.
#
# The wizard fixtures are not typed here: the cloud line is cut out of
# init-wizard.sh, and the sandbox file is tests/fixtures/sandbox-main.yml.golden,
# which wizard-network-mode.sh holds equal to the wizard's own sandbox output.

set -euo pipefail

echo "=== inventory-var test ==="

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export DMF_ENV_INVENTORY_DIR="${WORK_DIR}/inventory"
MAIN_YML="${DMF_ENV_INVENTORY_DIR}/group_vars/all/main.yml"
mkdir -p "$(dirname "$MAIN_YML")"

# shellcheck source=../bin/lib/_inventory_var.sh
. "${REPO_DIR}/bin/lib/_inventory_var.sh"

FAILS=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAILS=$((FAILS + 1)); }

# expect <label> <expected value> <file line>
expect() {
  local got
  printf '%s\n' "$3" > "$MAIN_YML"
  got="$(inventory_var dmf_provider || true)"
  [ "$got" = "$2" ] && pass "$1" || fail "$1: got [$got], want [$2]"
}

echo "[unit] scalar forms"
expect "bare" "sandbox" 'dmf_provider: sandbox'
expect "double quoted" "sandbox" 'dmf_provider: "sandbox"'
expect "single quoted" "sandbox" "dmf_provider: 'sandbox'"
expect "comment after a quoted value" "sandbox" 'dmf_provider: "sandbox"          # generic SSH host; not a cloud provider'
expect "comment after a single-quoted value" "sandbox" "dmf_provider: 'sandbox' # note"
expect "comment after a bare value" "sandbox" 'dmf_provider: sandbox   # note'
expect "hash inside double quotes" "a # b" 'dmf_provider: "a # b"'
expect "hash inside single quotes, then a comment" "a # b" "dmf_provider: 'a # b'  # note"
expect "hash that is not a comment" "a#b" 'dmf_provider: a#b'
expect "trailing spaces, bare" "sandbox" 'dmf_provider: sandbox   '
expect "trailing spaces, quoted" "sandbox" 'dmf_provider: "sandbox"   '
expect "only a comment" "" 'dmf_provider: # nothing'
expect "empty value" "" 'dmf_provider:'
expect "indented key" "sandbox" '  dmf_provider: sandbox'

echo "[wizard] the lines init-wizard.sh writes"
cloud_line="$(grep -E '^dmf_provider: "\$\{PROVIDER\}"' "${REPO_DIR}/bin/init-wizard.sh" | head -1)"
if [ -z "$cloud_line" ]; then
  fail "no dmf_provider line with \${PROVIDER} in init-wizard.sh"
else
  expect "wizard cloud line, provider hetzner" "hetzner" "${cloud_line//\$\{PROVIDER\}/hetzner}"
fi
sandbox_line="$(grep -E '^dmf_provider:' "${REPO_DIR}/tests/fixtures/sandbox-main.yml.golden" | head -1)"
expect "wizard sandbox line (golden file)" "sandbox" "$sandbox_line"
grep -qF "$sandbox_line" "${REPO_DIR}/bin/init-wizard.sh" && pass "the wizard source still writes that sandbox line" || fail "init-wizard.sh no longer writes: $sandbox_line"
cp "${REPO_DIR}/tests/fixtures/sandbox-main.yml.golden" "$MAIN_YML"
[ "$(inventory_var dmf_provider)" = "sandbox" ] && pass "whole golden sandbox main.yml" || fail "whole golden file"

if [ "$FAILS" -ne 0 ]; then
  echo "=== inventory-var: $FAILS failure(s) ==="
  exit 1
fi
echo "=== inventory-var: all cases passed ==="
