#!/usr/bin/env bash
# seed-stdin-order.sh — prove that seed-bao and seed-awx-control-node-ssh read the
# installer's token from stdin before they make any remote call.
#
# remote_kubectl runs ssh, and ssh reads stdin. A remote call made ahead of the token
# read can drain the pipe that holds the token, and the read then sees EOF. This test
# puts a fake ssh on PATH that reads all of its stdin, as a real ssh does when nothing
# stops it, and runs each command with the token piped in. The real remote_kubectl runs.
#
# Cases:
#   A  seed-bao: the token reaches the pod write although every ssh drains stdin
#      The active pod is the second of three, so a status call that drained the pod list
#      would leave no active pod.
#   B  seed-awx-control-node-ssh: the same
#   C  seed-bao: no remote call is made when stdin holds no token

# The cases set FAKE_* variables inside subshells on purpose: the fake reads them there.
# shellcheck disable=SC2030,SC2031,SC2329
set -euo pipefail

echo "=== seed-stdin-order test ==="

for cmd in bash jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "SKIP: $cmd not on PATH"
    exit 0
  fi
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

TOKEN="installer-token-SECRET"

# The fake ssh drains stdin into a file, then answers by the remote command. Each call
# adds a file to STATE_DIR, so a call that ran before the token read is visible.
mkdir -p "${WORK_DIR}/bin"
cat > "${WORK_DIR}/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
n="$(find "${STATE_DIR}" -name 'call-*' | wc -l | tr -d ' ')"
cat > "${STATE_DIR}/call-${n}.stdin"
cmd="${*: -1}"
printf '%s\n' "${cmd}" > "${STATE_DIR}/call-${n}.cmd"
case "${cmd}" in
  *"get pods"*) printf 'openbao-0 openbao-1 openbao-2' ;;
  *openbao-1*"bao status"*) printf '{"initialized":true,"sealed":false,"is_self":true}' ;;
  *"bao status"*) printf '{"initialized":true,"sealed":false}' ;;
esac
exit 0
FAKE
chmod +x "${WORK_DIR}/bin/ssh"

printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nkey\n' > "${WORK_DIR}/key"

# run_case NAME COMMAND [STDIN] — run the command with the fake ssh first on PATH.
run_case() {
  STATE_DIR="${WORK_DIR}/state-$1"
  mkdir -p "${STATE_DIR}"
  (
    export DMF_ENV_INVENTORY_DIR="${WORK_DIR}/inventory"
    export STATE_DIR PATH="${WORK_DIR}/bin:${PATH}"
    export DMF_KUBECTL_SSH_TARGET=fake@host DMF_AWX_CONTROL_NODE_SSH_PATH="${WORK_DIR}/key"
    # shellcheck source=../bin/bootstrap-secrets.sh disable=SC1091
    . "${REPO_DIR}/bin/bootstrap-secrets.sh"
    # The checks that need a real bundle and key store are not under test.
    require_sops() { :; }
    require_age_key() { :; }
    resolve_env_or_die() { :; }
    require_bundle_exists() { :; }
    require_bundle_decryptable() { :; }
    validate_bundle_schema() { :; }
    bundle_field() { printf 'x'; }
    printf '%s' "${3-}" | "$2" fake-env
  ) >"${STATE_DIR}/out.log" 2>&1 || true
}

FAILS=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAILS=$((FAILS + 1)); }

# True when a call that runs a script in the pod got the token on its stdin. A call
# that only lists pods or reads the status may drain the pipe and so shows the token too.
token_reached_pod() {
  local f
  for f in "${STATE_DIR}"/call-*.cmd; do
    [ -e "${f}" ] || continue
    grep -q "sh -c" "${f}" || continue
    if grep -q "^${TOKEN}\$" "${f%.cmd}.stdin"; then return 0; fi
  done
  return 1
}

echo "Case A: seed-bao"
run_case a cmd_seed_bao "${TOKEN}"$'\n'
if token_reached_pod; then pass "the token reaches a pod write"; else fail "token lost: $(cat "${STATE_DIR}/out.log")"; fi
if grep -q "stdin holds no token" "${STATE_DIR}/out.log"; then fail "read saw EOF"; else pass "no EOF on the token read"; fi

echo "Case B: seed-awx-control-node-ssh"
run_case b cmd_seed_awx_ssh "${TOKEN}"$'\n'
if token_reached_pod; then pass "the token reaches a pod write"; else fail "token lost: $(cat "${STATE_DIR}/out.log")"; fi
if grep -q "stdin holds no token" "${STATE_DIR}/out.log"; then fail "read saw EOF"; else pass "no EOF on the token read"; fi

echo "Case C: seed-bao with no token"
run_case c cmd_seed_bao ""
if grep -q "stdin holds no token" "${STATE_DIR}/out.log"; then pass "stops with the no-token message"; else fail "out: $(cat "${STATE_DIR}/out.log")"; fi
if ! compgen -G "${STATE_DIR}/call-*" >/dev/null; then pass "no remote call"; else fail "remote call made"; fi

if [ "${FAILS}" -ne 0 ]; then
  echo "FAILED: ${FAILS}"
  exit 1
fi
echo "ALL PASS"
