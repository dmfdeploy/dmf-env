#!/usr/bin/env bash
# controller-core-check.sh — prove run-playbook.sh fails closed when the controller's
# ansible-core minor differs from the pin in dmf-infra.
#
# A fake ansible-playbook and a fake dmf-infra pin file stand in for the real ones.
#
# Cases:
#   A  the same version passes and prints the one-line controller record
#   B  a different patch passes and says so
#   C  a different minor fails and names both versions and the pin file
#   D  a missing pin file fails and tells the operator to advance dmf-infra
#   E  a malformed pin file fails and names the file
#   E2 blank or unterminated pin lines fail
#   E3 a prerelease or development controller core fails and names the version
#   F  without a git checkout the record says "sha unknown" and still passes
#   G  run-playbook.sh stops before the secret fetch when the check fails

set -euo pipefail

echo "=== controller-core-check test ==="

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR:?}"' EXIT

FAILS=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAILS=$((FAILS + 1)); }

# A fake ansible-playbook that reports the version in FAKE_CORE.
FAKE_BIN="${WORK_DIR}/bin"
mkdir -p "${FAKE_BIN}"
cat > "${FAKE_BIN}/ansible-playbook" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  echo "ansible-playbook [core ${FAKE_CORE}]"
  echo "  config file = None"
  echo "  python version = 3.14.2 (main, Jan  1 2026, 00:00:00) [GCC 14.2.0] (/usr/bin/python3)"
  exit 0
fi
exit 0
FAKE
chmod +x "${FAKE_BIN}/ansible-playbook"

# A fake dmf-infra checkout holding one pin line. It sits next to the dmf-env copy
# used in case G, which is where the wrapper looks for it.
INFRA="${WORK_DIR}/dmf-infra"
PIN_FILE="${INFRA}/k3s-lab-bootstrap/requirements-ansible-core.txt"
mkdir -p "${INFRA}/k3s-lab-bootstrap"

# shellcheck source=../bin/lib/_controller_core.sh
. "${REPO_DIR}/bin/lib/_controller_core.sh"

# check <core> -> output in OUT, status in RC
check() {
  RC=0
  OUT="$(PATH="${FAKE_BIN}:${PATH}" FAKE_CORE="$1" dmf_check_controller_core "${INFRA}" 2>&1)" || RC=$?
}

echo "[A] same version"
echo "ansible-core==2.22.0" > "${PIN_FILE}"
check 2.22.0
if [ "${RC}" -eq 0 ] \
   && [ "$(printf '%s\n' "${OUT}" | wc -l | tr -d ' ')" = "1" ] \
   && printf '%s' "${OUT}" | grep -qF "controller: ansible-core 2.22.0, Python 3.14.2; pin 2.22.0 (${PIN_FILE}, dmf-infra "; then
  pass "passes with one record line"
else
  fail "rc=${RC} out=${OUT}"
fi

echo "[B] patch difference"
check 2.22.3
if [ "${RC}" -eq 0 ] && printf '%s' "${OUT}" | grep -q "ansible-core 2.22.3" \
   && printf '%s' "${OUT}" | grep -q "patch version differs"; then
  pass "passes and says the patch differs"
else
  fail "rc=${RC} out=${OUT}"
fi

echo "[C] minor mismatch"
check 2.21.3
if [ "${RC}" -ne 0 ] \
   && printf '%s' "${OUT}" | grep -qF "controller ansible-core 2.21.3 does not match pin 2.22.0 (${PIN_FILE})"; then
  pass "fails naming both versions and the file"
else
  fail "rc=${RC} out=${OUT}"
fi

echo "[D] missing pin file"
rm -f "${PIN_FILE}"
check 2.22.0
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -qF "${PIN_FILE}" \
   && printf '%s' "${OUT}" | grep -q "Advance the dmf-infra checkout"; then
  pass "fails and says to advance dmf-infra"
else
  fail "rc=${RC} out=${OUT}"
fi

echo "[E] malformed pin file"
for body in "ansible-core>=2.22.0" "ansible-core==2.22" "ansible-core==2.22.0 # note" "" \
            "$(printf 'ansible-core==2.22.0\nrequests')"; do
  printf '%s\n' "${body}" > "${PIN_FILE}"
  check 2.22.0
  if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -qF "${PIN_FILE}"; then
    pass "rejects: $(printf '%s' "${body}" | head -n 1)"
  else
    fail "accepted or unnamed (rc=${RC}): ${body} -> ${OUT}"
  fi
done

echo "[E2] blank or unterminated pin lines"
for body in 'ansible-core==2.22.0\n\n' 'ansible-core==2.22.0\n\n\n' '\nansible-core==2.22.0\n' 'ansible-core==2.22.0'; do
  # shellcheck disable=SC2059
  printf "${body}" > "${PIN_FILE}"
  check 2.22.0
  if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -qF "${PIN_FILE}"; then
    pass "rejects: ${body}"
  else
    fail "accepted or unnamed (rc=${RC}): ${body} -> ${OUT}"
  fi
done

echo "[E3] prerelease and development controller cores"
echo "ansible-core==2.22.0" > "${PIN_FILE}"
for v in 2.22.0rc1 2.22.0.dev0 2.22.0b1; do
  check "${v}"
  if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -qF "'${v}'"; then
    pass "rejects ${v} and names it"
  else
    fail "accepted or unnamed (rc=${RC}): ${v} -> ${OUT}"
  fi
done

echo "[F] no git checkout"
echo "ansible-core==2.22.0" > "${PIN_FILE}"
check 2.22.0
if [ "${RC}" -eq 0 ] && printf '%s' "${OUT}" | grep -q "dmf-infra sha unknown)"; then
  pass "prints sha unknown and passes"
else
  fail "rc=${RC} out=${OUT}"
fi

echo "[G] no secret fetch on failure"
# A copy of the wrapper next to a stub bootstrap-secrets.sh that leaves a marker.
SANDBOX="${WORK_DIR}/dmf-env"
mkdir -p "${SANDBOX}/bin" "${WORK_DIR}/data/envs/t/inventory"
cp "${REPO_DIR}/bin/run-playbook.sh" "${SANDBOX}/bin/"
cp -R "${REPO_DIR}/bin/lib" "${SANDBOX}/bin/lib"
cat > "${SANDBOX}/bin/bootstrap-secrets.sh" <<STUB
#!/usr/bin/env bash
touch "${WORK_DIR}/secrets-fetched"
exit 1
STUB
chmod +x "${SANDBOX}/bin/bootstrap-secrets.sh"
touch "${WORK_DIR}/play.yml"
run_wrapper() {
  RC=0
  OUT="$(HOME="${WORK_DIR}" DMF_DATA_ROOT="${WORK_DIR}/data" ANSIBLE_CONFIG="${WORK_DIR}/ansible.cfg" \
         PATH="${FAKE_BIN}:${PATH}" FAKE_CORE="$1" \
         "${SANDBOX}/bin/run-playbook.sh" t "${WORK_DIR}/play.yml" 2>&1)" || RC=$?
}
run_wrapper 2.21.3
if [ "${RC}" -ne 0 ] && [ ! -e "${WORK_DIR}/secrets-fetched" ] \
   && printf '%s' "${OUT}" | grep -q "does not match pin"; then
  pass "mismatch stops before the secret fetch"
else
  fail "rc=${RC} fetched=$([ -e "${WORK_DIR}/secrets-fetched" ] && echo yes || echo no) out=${OUT}"
fi
rm -f "${PIN_FILE}"
run_wrapper 2.22.0
if [ "${RC}" -ne 0 ] && [ ! -e "${WORK_DIR}/secrets-fetched" ]; then
  pass "missing pin stops before the secret fetch"
else
  fail "rc=${RC} out=${OUT}"
fi
# With a matching pin the wrapper reaches the (stub) secret fetch, which exits 1.
echo "ansible-core==2.22.0" > "${PIN_FILE}"
run_wrapper 2.22.0
if [ -e "${WORK_DIR}/secrets-fetched" ]; then
  pass "a matching controller reaches the secret fetch"
else
  fail "matching controller did not reach the secret fetch: ${OUT}"
fi

if [ "${FAILS}" -ne 0 ]; then
  echo "=== ${FAILS} failure(s) ==="
  exit 1
fi
echo "=== all passed ==="
