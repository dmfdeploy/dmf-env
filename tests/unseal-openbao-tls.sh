#!/usr/bin/env bash
# unseal-openbao-tls.sh — prove the unseal wrapper never skips TLS verification.
#
# Stubs ssh so each remote call is answered by a fake OpenBao. The fake has two
# endpoint modes: "verifiable" accepts verified requests; "unverifiable" fails
# every verified request with a certificate error and accepts only requests that
# skip verification (curl -k / --insecure, bao with *_SKIP_VERIFY=true). A
# wrapper that verifies TLS must therefore fail closed against "unverifiable",
# and must never send a request that skips verification in any mode.
#
# Cases:
#   A  unseal, the unseal endpoint is unverifiable → fails with a TLS message,
#      no share accepted, no insecure request
#   B  --status, the status endpoint is unverifiable → exit 7 with a TLS message
#   C  unseal, endpoint verifiable → exit 0, no insecure request, shares travel
#      on stdin only (present in request bodies, absent from every argv and
#      from the wrapper's output)
#   D  the script has no -k / --insecure / skip-verify path

set -euo pipefail

echo "=== unseal-openbao-tls test ==="

for cmd in bash jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "SKIP: $cmd not on PATH"
    exit 0
  fi
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_DIR}/bin/unseal-openbao.sh"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export DMF_DATA_ROOT="${WORK_DIR}/dmf-data"
ENV_ID="test-unseal-openbao-tls"
ENV_ROOT="${DMF_DATA_ROOT}/envs/${ENV_ID}"
GROUP_VARS_DIR="${ENV_ROOT}/inventory/group_vars/all"
SHARE_DIR="${WORK_DIR}/shares"
mkdir -p "${GROUP_VARS_DIR}" "${SHARE_DIR}" "${WORK_DIR}/bin"

cat > "${ENV_ROOT}/inventory/hosts.ini" <<'EOF'
[k3s_control]
control-1

[k3s]
control-1 ansible_host=127.0.0.1 ansible_user=lima
EOF

cat > "${GROUP_VARS_DIR}/main.yml" <<'EOF'
openbao_key_path: /tmp/openbao/breakglass
EOF
touch "${ENV_ROOT}/bundle.sops.yaml"

printf '{"key":"share-one-SECRET"}\n' > "${SHARE_DIR}/share-1.json"
printf '{"key":"share-two-SECRET"}\n' > "${SHARE_DIR}/share-2.json"

# Fake OpenBao behind ssh. State lives in $STATE_DIR so each case starts clean.
cat > "${WORK_DIR}/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
printf '%s\n' "$args" >> "$STATE_DIR/argv.log"

accepted() { cat "$STATE_DIR/accepted" 2>/dev/null || echo 0; }
accept() { echo $(( $(accepted) + 1 )) > "$STATE_DIR/accepted"; }
status_json() {
  local n sealed
  n="$(accepted)"
  sealed=true; [ "$n" -ge 3 ] && sealed=false
  printf '{"sealed":%s,"version":"2.0.0","t":3,"n":5,"progress":%s,"ha_enabled":false,"cluster_name":"bao"}' "$sealed" "$n"
}
x509() {
  printf 'Error: Put "https://127.0.0.1:8200/v1/sys/unseal": tls: failed to verify certificate: x509: certificate signed by unknown authority\n' >&2
}

insecure=0
case " $args " in
  *" -k "*|*" --insecure "*|*SKIP_VERIFY=true*|*SKIP_VERIFY=1*|*"-tls-skip-verify "*|*"-tls-skip-verify=true"*)
    insecure=1
    printf 'INSECURE: %s\n' "$args" >> "$STATE_DIR/insecure.log"
    ;;
esac

case "$args" in
  *"command -v curl"*) exit 0 ;;
  *"get pod"*"podIP"*) printf '192.0.2.42'; exit 0 ;;
  *" curl "*)
    cat >> "$STATE_DIR/bodies.log"; echo >> "$STATE_DIR/bodies.log"
    if [ "$ENDPOINT" = verifiable ] || [ "$insecure" -eq 1 ]; then
      accept; status_json; exit 0
    fi
    printf 'curl: (60) SSL certificate problem: unable to get local issuer certificate\n' >&2
    exit 60
    ;;
  *" bao status"*)
    if [ "$STATUS_ENDPOINT" = unverifiable ] && [ "$insecure" -eq 0 ]; then
      x509; exit 1
    fi
    status_json
    [ "$(accepted)" -ge 3 ] && exit 0
    exit 2
    ;;
  *" bao write"*"sys/unseal -"*)
    cat >> "$STATE_DIR/bodies.log"; echo >> "$STATE_DIR/bodies.log"
    if [ "$ENDPOINT" = verifiable ] || [ "$insecure" -eq 1 ]; then
      accept; printf '{}'; exit 0
    fi
    x509; exit 2
    ;;
  *)
    printf 'unexpected ssh invocation: %s\n' "$args" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${WORK_DIR}/bin/ssh"

cat > "${WORK_DIR}/bin/security" <<'EOF'
#!/usr/bin/env bash
case " $* " in *" -w "*) printf 'share-three-SECRET\n' ;; esac
exit 0
EOF
chmod +x "${WORK_DIR}/bin/security"

PATH="${WORK_DIR}/bin:${PATH}"
unset OPENBAO_API_ADDR OPENBAO_CACERT

FAILS=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAILS=$((FAILS + 1)); }

# run_case <endpoint> <status-endpoint> <wrapper args...>; sets RC, OUT_FILE.
run_case() {
  local endpoint="$1" status_endpoint="$2"
  shift 2
  export STATE_DIR="${WORK_DIR}/state-${CASE}"
  mkdir -p "$STATE_DIR"
  : > "$STATE_DIR/argv.log"; : > "$STATE_DIR/insecure.log"; : > "$STATE_DIR/bodies.log"
  OUT_FILE="$STATE_DIR/out.log"
  RC=0
  ENDPOINT="$endpoint" STATUS_ENDPOINT="$status_endpoint" \
  OPENBAO_SSH_TARGET="k3s-admin@127.0.0.1" \
  OPENBAO_SHARE_DIR="${SHARE_DIR}" \
  OPENBAO_PROFILE=hetzner \
    "${SCRIPT}" "${ENV_ID}" "$@" </dev/null >"$OUT_FILE" 2>&1 || RC=$?
}

no_insecure() {
  if [ -s "$STATE_DIR/insecure.log" ]; then
    fail "case $CASE sent a request that skips TLS verification:"
    sed 's/^/        /' "$STATE_DIR/insecure.log"
  else
    pass "case $CASE sent no request that skips TLS verification"
  fi
}

echo "case A: unseal against an unverifiable unseal endpoint"
CASE=A; run_case unverifiable verifiable --yes
if [ "$RC" -ne 0 ] && [ "$RC" -ne 2 ]; then pass "exit $RC (failed closed)"; else fail "exit $RC (expected a failure, not 0 or 2)"; fi
if grep -q "TLS verification failed" "$OUT_FILE"; then pass "TLS failure message printed"; else fail "no TLS failure message"; fi
if [ "$(cat "$STATE_DIR/accepted" 2>/dev/null || echo 0)" -eq 0 ]; then pass "no share accepted"; else fail "fake OpenBao accepted $(cat "$STATE_DIR/accepted") share(s)"; fi
no_insecure

echo "case B: --status against an unverifiable status endpoint"
CASE=B; run_case unverifiable unverifiable --status
if [ "$RC" -eq 7 ]; then pass "exit 7"; else fail "exit $RC (expected 7)"; fi
if grep -q "TLS verification failed" "$OUT_FILE"; then pass "TLS failure message printed"; else fail "no TLS failure message"; fi
no_insecure

echo "case C: unseal against a verifiable endpoint"
CASE=C; run_case verifiable verifiable --yes
if [ "$RC" -eq 0 ]; then pass "exit 0"; else fail "exit $RC (expected 0)"; sed 's/^/        /' "$OUT_FILE"; fi
no_insecure
for share in share-one-SECRET share-two-SECRET share-three-SECRET; do
  if grep -q "$share" "$STATE_DIR/bodies.log"; then pass "$share reached OpenBao on stdin"; else fail "$share never reached OpenBao"; fi
  if grep -q "$share" "$STATE_DIR/argv.log"; then fail "$share appeared in an argv"; else pass "$share absent from every argv"; fi
  if grep -q "$share" "$OUT_FILE"; then fail "$share appeared in the wrapper's output"; else pass "$share absent from the wrapper's output"; fi
done

echo "case D: no verification bypass in the script"
if grep -nE -- '(^|[[:space:]"(])(-k|--insecure)([[:space:]")]|$)|SKIP_VERIFY=(1|true)|tls-skip-verify' "$SCRIPT"; then
  fail "the script above contains a verification bypass"
else
  pass "no -k, --insecure, or skip-verify path"
fi

if [ "$FAILS" -ne 0 ]; then
  echo "FAIL ($FAILS check(s))"
  exit 1
fi
echo "PASS"
