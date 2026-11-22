#!/usr/bin/env bash
# playbook-timeout.sh — prove run-playbook.sh gives each playbook the right runtime cap.
#
# The install and upgrade stage playbooks rerun a whole install stage and take far
# longer than the short default, so they get the long cap. Other playbooks keep the
# short cap that guards against a ControlMaster hang.
#
# Cases:
#   A  the stage playbooks of both lanes get 7200
#   B  an ordinary playbook gets 900, bootstrap-sandbox-profile.yml (not a stage
#      playbook) 900, a lifecycle playbook 1800, site.yml 7200
#   C  RUNBOOK_TIMEOUT overrides every default

set -euo pipefail

echo "=== playbook-timeout test ==="

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

FAILS=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAILS=$((FAILS + 1)); }

# The cap logic, cut out of the script so no playbook, secret or env is needed.
snippet="${WORK_DIR}/snippet.sh"
sed -n '/^if \[ -n "\${RUNBOOK_TIMEOUT:-}" \]; then/,/^fi$/p' "${REPO_DIR}/bin/run-playbook.sh" > "${snippet}"
if ! grep -q TIMEOUT_SEC "${snippet}"; then
  echo "FAIL: could not find the cap logic in bin/run-playbook.sh"
  exit 1
fi

cap_for() {
  PLAYBOOK="/x/$1" RUNBOOK_TIMEOUT="${2:-}" bash -c '. "$1"; printf "%s" "${TIMEOUT_SEC}"' _ "${snippet}"
}

echo "[A] stage playbooks"
for name in \
  bootstrap-sandbox-provision-pre-seed.yml bootstrap-sandbox-provision-post-seed.yml \
  bootstrap-sandbox-configure.yml bootstrap-sandbox-verify.yml \
  bootstrap-provision-pre-seed.yml bootstrap-provision-post-seed.yml \
  bootstrap-configure.yml bootstrap-verify.yml; do
  got="$(cap_for "${name}")"
  if [ "${got}" = "7200" ]; then pass "${name} gets 7200"; else fail "${name} gets ${got}"; fi
done

echo "[B] other playbooks keep their caps"
for pair in 102-openbao-ha-guard.yml:900 verify-bootstrap-convergence.yml:900 \
            bootstrap-sandbox-profile.yml:900 \
            lifecycle-teardown.yml:1800 site.yml:7200; do
  name="${pair%%:*}"; want="${pair##*:}"
  got="$(cap_for "${name}")"
  if [ "${got}" = "${want}" ]; then pass "${name} gets ${want}"; else fail "${name} gets ${got}, want ${want}"; fi
done

echo "[C] RUNBOOK_TIMEOUT overrides"
got="$(cap_for bootstrap-sandbox-provision-pre-seed.yml 60)"
if [ "${got}" = "60" ]; then pass "override wins"; else fail "got ${got}"; fi

if [ "${FAILS}" -ne 0 ]; then
  echo "=== ${FAILS} failure(s) ==="
  exit 1
fi
echo "=== all passed ==="
