#!/usr/bin/env bash
# upgrade-in-place-guard.sh — prove the upgrade wrapper checks every OpenBao pod
# and calls the restart guard before any stage that can restart a pod.
#
# Stubs ssh with a fake cluster (pod list and sealed pods come from the
# environment) and replaces run-playbook.sh and bootstrap-secrets.sh with loggers,
# so no playbook runs. The real upgrade-in-place.sh and unseal-openbao.sh run.
#
# Cases:
#   A  one pod, unsealed → exit 0; the guard playbook runs first, then the stages
#   B  three pods, one sealed → exit 2 before any playbook or seed-bao step
#   C  three pods unsealed, the guard refuses → exit 2, only the guard ran
#   D  --skip-unseal-check skips only the stage 1 seal check: the guard still runs, and
#      a refusing guard still stops the run before any other step
#   G  no flag skips the guard (--skip-unseal-check, --dry-run, --yes)
#   E  --status-all exit codes: 0 all unsealed, 6 one sealed, 4 no pod
#   F  --status-all reports each pod on its own line
#   H  the playbook set follows the env's lane: a sandbox env (dmf_provider: sandbox)
#      runs the bootstrap-sandbox-* playbooks (convergence runs inside the sandbox
#      verify), a hetzner env the cloud playbooks; a missing file, a missing, empty,
#      indented or unknown dmf_provider stops the run before any playbook

set -euo pipefail

echo "=== upgrade-in-place-guard test ==="

for cmd in bash jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "SKIP: $cmd not on PATH"
    exit 0
  fi
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# A private copy of bin/ so the two helper scripts can be replaced by stubs.
mkdir -p "${WORK_DIR}/repo"
cp -R "${REPO_DIR}/bin" "${WORK_DIR}/repo/bin"
BIN="${WORK_DIR}/repo/bin"

export DMF_DATA_ROOT="${WORK_DIR}/dmf-data"
ENV_ID="test-upgrade-guard"
ENV_ROOT="${DMF_DATA_ROOT}/envs/${ENV_ID}"
GROUP_VARS_DIR="${ENV_ROOT}/inventory/group_vars/all"
mkdir -p "${GROUP_VARS_DIR}" "${WORK_DIR}/stub" "${WORK_DIR}/state"
cat > "${ENV_ROOT}/inventory/hosts.ini" <<'EOF'
[k3s_control]
control-1

[k3s]
control-1 ansible_host=127.0.0.1 ansible_user=lima
EOF
cat > "${GROUP_VARS_DIR}/main.yml" <<'EOF'
openbao_key_path: /tmp/openbao/breakglass
dmf_provider: "hetzner"
EOF
touch "${ENV_ROOT}/bundle.sops.yaml"

# Fake cluster behind ssh. FAKE_PODS and FAKE_SEALED are space-separated pod names.
cat > "${WORK_DIR}/stub/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
case "$args" in
  *" get pods "*"-o name"*)
    for p in ${FAKE_PODS:-}; do printf 'pod/%s\n' "$p"; done
    exit 0
    ;;
  *" bao status"*)
    pod="$(printf '%s' "$args" | sed -E 's/.* exec -i ([^ ]+) .*/\1/')"
    case " ${FAKE_SEALED:-} " in
      *" $pod "*) printf '{"sealed":true,"version":"2.5.2","t":3,"n":5,"progress":0}'; exit 2 ;;
    esac
    printf '{"sealed":false,"version":"2.5.2","t":3,"n":5,"progress":0}'
    exit 0
    ;;
esac
echo "unexpected ssh invocation: $args" >&2
exit 1
EOF
chmod +x "${WORK_DIR}/stub/ssh"

# Stubs for the two helpers. They log the call and succeed, except for the guard
# playbook when FAKE_GUARD_FAIL=1.
cat > "${BIN}/run-playbook.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$2")" >> "$STATE_DIR/playbooks.log"
if [ "${FAKE_GUARD_FAIL:-0}" = 1 ] && [ "$(basename "$2")" = "102-openbao-ha-guard.yml" ]; then
  echo "Refusing to restart or drain an OpenBao pod: fake refusal" >&2
  exit 2
fi
exit 0
EOF
cat > "${BIN}/bootstrap-secrets.sh" <<'EOF'
#!/usr/bin/env bash
printf 'seed-bao\n' >> "$STATE_DIR/playbooks.log"
exit 0
EOF
chmod +x "${BIN}/run-playbook.sh" "${BIN}/bootstrap-secrets.sh"

export PATH="${WORK_DIR}/stub:${PATH}"
export STATE_DIR="${WORK_DIR}/state"

FAILS=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAILS=$((FAILS + 1)); }

# run_case <pods> <sealed> <guard-fail> <args...> — sets RC and OUT.
run_case() {
  FAKE_PODS="$1" FAKE_SEALED="$2" FAKE_GUARD_FAIL="$3"
  export FAKE_PODS FAKE_SEALED FAKE_GUARD_FAIL
  shift 3
  rm -f "${STATE_DIR}/playbooks.log"
  RC=0
  OUT="$("${BIN}/upgrade-in-place.sh" "$ENV_ID" --yes "$@" 2>&1)" || RC=$?
}
logged() { cat "${STATE_DIR}/playbooks.log" 2>/dev/null || true; }

echo "[A] one pod, unsealed"
run_case "openbao-0" "" 0
[ "$RC" -eq 0 ] && pass "exit 0" || fail "exit $RC: $OUT"
[ "$(logged | head -1)" = "102-openbao-ha-guard.yml" ] && pass "guard ran first" || fail "order: $(logged | tr '\n' ' ')"
logged | grep -q "bootstrap-provision-pre-seed.yml" && pass "stages ran after the guard" || fail "no stage ran"

echo "[B] three pods, openbao-1 sealed"
run_case "openbao-0 openbao-1 openbao-2" "openbao-1" 0
[ "$RC" -eq 2 ] && pass "exit 2" || fail "exit $RC"
[ -z "$(logged)" ] && pass "no playbook and no seed-bao ran" || fail "ran: $(logged | tr '\n' ' ')"
printf '%s' "$OUT" | grep -q "openbao-1: sealed" && pass "names the sealed pod" || fail "sealed pod not named"

echo "[C] three pods unsealed, guard refuses"
run_case "openbao-0 openbao-1 openbao-2" "" 1
[ "$RC" -eq 2 ] && pass "exit 2" || fail "exit $RC"
[ "$(logged)" = "102-openbao-ha-guard.yml" ] && pass "only the guard ran" || fail "ran: $(logged | tr '\n' ' ')"

echo "[D] --skip-unseal-check skips the seal check, not the guard"
run_case "openbao-0 openbao-1 openbao-2" "openbao-1" 0 --skip-unseal-check
[ "$RC" -eq 0 ] && pass "the seal precheck is skipped (exit 0 with a sealed pod, the stub guard passing)" || fail "exit $RC: $OUT"
[ "$(logged | head -1)" = "102-openbao-ha-guard.yml" ] && pass "guard still ran first" || fail "order: $(logged | tr '\n' ' ')"
run_case "openbao-0 openbao-1 openbao-2" "" 1 --skip-unseal-check
[ "$RC" -eq 2 ] && pass "a refusing guard exits 2 under --skip-unseal-check" || fail "exit $RC"
[ "$(logged)" = "102-openbao-ha-guard.yml" ] && pass "nothing else ran" || fail "ran: $(logged | tr '\n' ' ')"

echo "[G] no flag skips the guard"
for flag in --skip-unseal-check --dry-run --yes; do
  run_case "openbao-0" "" 0 "$flag"
  logged | grep -q "102-openbao-ha-guard.yml" && pass "guard ran with $flag" || fail "guard did not run with $flag"
done

echo "[H] the playbook set follows the env's lane, and an unreadable lane stops the run"
MAIN_YML="${GROUP_VARS_DIR}/main.yml"
EXPECT_CLOUD="102-openbao-ha-guard.yml bootstrap-provision-pre-seed.yml bootstrap-provision-post-seed.yml bootstrap-configure.yml verify-bootstrap-convergence.yml bootstrap-verify.yml"
EXPECT_SANDBOX="102-openbao-ha-guard.yml bootstrap-sandbox-provision-pre-seed.yml bootstrap-sandbox-provision-post-seed.yml bootstrap-sandbox-configure.yml bootstrap-sandbox-verify.yml"
ran() { logged | grep -v '^seed-bao$' | tr '\n' ' ' | sed 's/ $//'; }

# lane_case <label> <expected playbooks> <main.yml line>
lane_case() {
  printf 'openbao_key_path: /tmp/openbao/breakglass\n%s\n' "$3" > "$MAIN_YML"
  run_case "openbao-0" "" 0
  [ "$RC" -eq 0 ] && [ "$(ran)" = "$2" ] && pass "$1" || fail "$1: rc=$RC ran: $(ran)"
}
# refuse_case <label> — the main.yml is already in place.
refuse_case() {
  run_case "openbao-0" "" 0
  if [ "$RC" -eq 1 ] && [ -z "$(logged)" ] && printf '%s' "$OUT" | grep -q "dmf_provider" && printf '%s' "$OUT" | grep -q "main.yml"; then
    pass "$1: exit 1, no playbook ran, message names the key and the file"
  else
    fail "$1: rc=$RC ran: $(logged | tr '\n' ' ') out: $OUT"
  fi
}

lane_case "double-quoted hetzner" "$EXPECT_CLOUD" 'dmf_provider: "hetzner"'
lane_case "unquoted hetzner" "$EXPECT_CLOUD" 'dmf_provider: hetzner'
lane_case "double-quoted sandbox" "$EXPECT_SANDBOX" 'dmf_provider: "sandbox"'
lane_case "unquoted sandbox" "$EXPECT_SANDBOX" 'dmf_provider: sandbox'
lane_case "sandbox (single quotes)" "$EXPECT_SANDBOX" "dmf_provider: 'sandbox'"

printf 'openbao_key_path: /tmp/openbao/breakglass\n' > "$MAIN_YML"
refuse_case "key missing"
printf 'openbao_key_path: /tmp/openbao/breakglass\ndmf_provider:\n' > "$MAIN_YML"
refuse_case "empty value"
printf 'openbao_key_path: /tmp/openbao/breakglass\ndmf_provider: aws\n' > "$MAIN_YML"
refuse_case "unknown value"
printf 'openbao_key_path: /tmp/openbao/breakglass\nnested:\n  dmf_provider: sandbox\n' > "$MAIN_YML"
refuse_case "leading-indented key"
rm -f "$MAIN_YML"
refuse_case "inventory file missing"
printf 'openbao_key_path: /tmp/openbao/breakglass\ndmf_provider: "hetzner"\n' > "$MAIN_YML"

echo "[E] --status-all exit codes"
export FAKE_PODS="openbao-0 openbao-1 openbao-2" FAKE_SEALED=""
RC=0; "${BIN}/unseal-openbao.sh" "$ENV_ID" --status-all >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] && pass "all unsealed → 0" || fail "all unsealed → $RC"
export FAKE_SEALED="openbao-2"
RC=0; "${BIN}/unseal-openbao.sh" "$ENV_ID" --status-all >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 6 ] && pass "one sealed → 6" || fail "one sealed → $RC"
export FAKE_PODS="" FAKE_SEALED=""
RC=0; "${BIN}/unseal-openbao.sh" "$ENV_ID" --status-all >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 4 ] && pass "no pod → 4" || fail "no pod → $RC"

echo "[F] --status-all reports each pod"
export FAKE_PODS="openbao-0 openbao-1 openbao-2" FAKE_SEALED="openbao-2"
OUT="$("${BIN}/unseal-openbao.sh" "$ENV_ID" --status-all 2>&1 || true)"
for line in "openbao-0: unsealed" "openbao-1: unsealed" "openbao-2: sealed"; do
  printf '%s' "$OUT" | grep -q "$line" && pass "$line" || fail "missing: $line"
done

if [ "$FAILS" -ne 0 ]; then
  echo "=== upgrade-in-place-guard: $FAILS failure(s) ==="
  exit 1
fi
echo "=== upgrade-in-place-guard: all cases passed ==="
