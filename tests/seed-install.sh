#!/usr/bin/env bash
# seed-install.sh — prove the seed-install command of bootstrap-secrets.sh and the way
# bin/run-playbook.sh names it for the install playbooks.
#
# seed-install reads the installer's token from the first line of stdin and runs the
# OpenBao seed with it. It never revokes that token: the installer owns it. The seeds
# still make their own temporary root token when no installer token is set. The AWX
# control-node key is not seeded here: the AWX role of the install writes it.
#
# Cases:
#   A  take_write_token with an installer token uses it, makes no root token, sets no trap
#   B  take_write_token without one calls acquire_temp_root and sets the revoke trap
#   C  seed-install with empty stdin exits 1 and runs no seed
#   D  seed-install runs the OpenBao seed with the token
#   E  a failing seed gives seed-install the same exit status
#   G  seed-install never runs the AWX seed, even with a key path set
#   F  run-playbook.sh passes the seed command to the install playbooks and to no other

# The cases run the code under test in subshells on purpose.
# shellcheck disable=SC2030,SC2031
set -euo pipefail

echo "=== seed-install test ==="

for cmd in bash jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "SKIP: $cmd not on PATH"
    exit 0
  fi
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# shellcheck source=../bin/bootstrap-secrets.sh disable=SC1091
. "${REPO_DIR}/bin/bootstrap-secrets.sh"

INSTALLER_TOKEN="installer-token-SECRET"
FAILS=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAILS=$((FAILS + 1)); }

echo "Case A: an installer token is used as it is"
out="$(
  acquire_temp_root() { echo "acquire called"; }
  BAO_INSTALL_TOKEN="${INSTALLER_TOKEN}" BAO_ROOT_TOKEN=""
  take_write_token fake-env >/dev/null
  printf 'token=%s\n' "${BAO_ROOT_TOKEN}"
  printf 'trap=%s\n' "$(trap -p EXIT INT TERM)"
)"
if grep -qx "token=${INSTALLER_TOKEN}" <<<"${out}"; then pass "the write token is the installer's token"; else fail "output: ${out}"; fi
if grep -q "revoke_temp_root" <<<"${out}"; then fail "the revoke trap is set"; else pass "no revoke trap"; fi
if grep -q "acquire called" <<<"${out}"; then fail "acquire_temp_root ran"; else pass "no temporary root token"; fi

echo "Case B: no installer token, the seed makes its own"
out="$(
  acquire_temp_root() { echo "acquire called for $1"; }
  unset BAO_INSTALL_TOKEN
  take_write_token fake-env 2>/dev/null
  printf 'trap=%s\n' "$(trap -p EXIT)"
)"
if grep -q "acquire called for fake-env" <<<"${out}"; then pass "acquire_temp_root ran"; else fail "output: ${out}"; fi
if grep -q "revoke_temp_root" <<<"${out}"; then pass "the revoke trap is set"; else fail "output: ${out}"; fi

echo "Case C: empty stdin"
rc=0
ran="${WORK_DIR}/ran-c"
: > "${ran}"
ERR="$( ( cmd_seed_bao() { echo bao >> "${ran}"; }; cmd_seed_install fake-env </dev/null ) 2>&1 >/dev/null )" || rc=$?
if [ "${rc}" -eq 1 ] && grep -q "stdin holds no token" <<<"${ERR}"; then pass "exit 1 with a message"; else fail "rc ${rc}: ${ERR}"; fi
if [ ! -s "${ran}" ]; then pass "no seed ran"; else fail "a seed ran"; fi

echo "Case D: the seed"
seen="${WORK_DIR}/seen-d"
: > "${seen}"
cmd_seed_bao() { printf 'bao %s %s\n' "$1" "${BAO_INSTALL_TOKEN}" >> "${seen}"; }
printf '%s\nextra-line\n' "${INSTALLER_TOKEN}" | cmd_seed_install fake-env 2>/dev/null
if [ "$(cat "${seen}")" = "bao fake-env ${INSTALLER_TOKEN}" ]; then pass "OpenBao seed with the installer's token"; else fail "seen: $(cat "${seen}")"; fi

echo "Case E: a failing seed"
: > "${seen}"
cmd_seed_bao() { printf 'bao\n' >> "${seen}"; exit 3; }
rc=0
printf '%s\n' "${INSTALLER_TOKEN}" | cmd_seed_install fake-env >/dev/null 2>&1 || rc=$?
if [ "${rc}" -eq 3 ] && [ "$(cat "${seen}")" = "bao" ]; then pass "exit 3"; else fail "rc ${rc}, seen: $(cat "${seen}")"; fi

echo "Case G: no AWX seed"
: > "${seen}"
cmd_seed_bao() { printf 'bao\n' >> "${seen}"; }
cmd_seed_awx_ssh() { printf 'awx\n' >> "${seen}"; }
printf '%s\n' "${INSTALLER_TOKEN}" | (DMF_AWX_CONTROL_NODE_SSH_PATH=/some/key cmd_seed_install fake-env) >/dev/null 2>&1
if [ "$(cat "${seen}")" = "bao" ]; then pass "the AWX seed does not run with a key path set"; else fail "seen: $(cat "${seen}")"; fi

echo "Case F: run-playbook.sh"
snippet="${WORK_DIR}/snippet.sh"
sed -n '/^SEED_ARGS=()/,/^esac/p' "${REPO_DIR}/bin/run-playbook.sh" > "${snippet}"
for name in bootstrap-provision-pre-seed.yml bootstrap-sandbox-provision-pre-seed.yml 100-openbao.yml; do
  out="$(PLAYBOOK="/x/${name}" SCRIPT_DIR=/dmf-env/bin ENV_NAME=fake-env bash -c '. "$1"; printf "%s\n" "${SEED_ARGS[@]}"' _ "${snippet}")"
  if [ "$(printf '%s\n' "${out}" | sed -n 1p)" = "-e" ] && [ "$(printf '%s\n' "${out}" | sed -n 2p | jq -c '.openbao_install_seed_command')" = '["/dmf-env/bin/bootstrap-secrets.sh","seed-install","fake-env"]' ]; then
    pass "${name} gets the seed command"
  else
    fail "${name}: ${out}"
  fi
done
for name in bootstrap-provision-post-seed.yml 120-network-policies.yml bootstrap-sandbox-verify.yml; do
  out="$(PLAYBOOK="/x/${name}" SCRIPT_DIR=/dmf-env/bin ENV_NAME=fake-env bash -c '. "$1"; printf "%s" "${#SEED_ARGS[@]}"' _ "${snippet}")"
  if [ "${out}" = "0" ]; then pass "${name} gets none"; else fail "${name} got ${out} words"; fi
done

if [ "${FAILS}" -ne 0 ]; then
  echo "=== ${FAILS} failure(s) ==="
  exit 1
fi
echo "=== all passed ==="
