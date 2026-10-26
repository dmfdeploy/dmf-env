#!/usr/bin/env bash
# enroll-ssh-key.sh — verify bin/enroll-ssh-key.sh enrolls over one password
# attempt, gates on key-only login, and names the cause when either step fails.
# Hermetic: fake ssh on PATH, temp DMF_DATA_ROOT, throwaway key.

set -euo pipefail

echo "=== enroll-ssh-key test ==="

for cmd in bash ssh-keygen; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "SKIP: $cmd not on PATH"
    exit 0
  fi
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_DIR}/bin/enroll-ssh-key.sh"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export DMF_DATA_ROOT="${WORK_DIR}/dmf-data"
export SSH_LOG="${WORK_DIR}/ssh.log"
ENV_ID="test-enroll"
INV_DIR="${DMF_DATA_ROOT}/envs/${ENV_ID}/inventory"
mkdir -p "${INV_DIR}/group_vars/all" "${WORK_DIR}/bin"

ssh-keygen -t ed25519 -N "" -f "${WORK_DIR}/node-key" -C "enroll-test" >/dev/null 2>&1
PUBKEY="$(cat "${WORK_DIR}/node-key.pub")"

cat > "${INV_DIR}/hosts.ini" <<'EOF'
[k3s]
test-enroll-01 ansible_host=192.0.2.10 k3s_node_ip=192.0.2.10 ansible_user=debian
EOF
printf 'ansible_ssh_private_key_file: "%s"\n' "${WORK_DIR}/node-key" \
  > "${INV_DIR}/group_vars/all/main.yml"

# Fake ssh: the gate call is the one carrying BatchMode=yes. FAKE_ENROLL_ERR /
# FAKE_GATE_ERR make the matching call fail with that stderr.
cat > "${WORK_DIR}/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ARGS %s\n' "$*" >> "$SSH_LOG"
case "$*" in
  *BatchMode=yes*) err="${FAKE_GATE_ERR:-}" ;;
  *)               err="${FAKE_ENROLL_ERR:-}"; printf 'STDIN %s\n' "$(cat)" >> "$SSH_LOG" ;;
esac
if [ -n "$err" ]; then
  printf '%s\n' "$err" >&2
  exit 255
fi
EOF
chmod +x "${WORK_DIR}/bin/ssh"
export PATH="${WORK_DIR}/bin:${PATH}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run() {
  : > "$SSH_LOG"
  set +e
  OUT="$(bash "$SCRIPT" "$@" 2>&1)"
  RC=$?
  set -e
}

echo "Test 1: enrolls with one password attempt, then gates on key-only login..."
run "$ENV_ID"
[ "$RC" -eq 0 ] || fail "expected exit 0, got ${RC}: ${OUT}"
enroll_call="$(grep '^ARGS' "$SSH_LOG" | grep -v 'BatchMode=yes')"
gate_call="$(grep '^ARGS' "$SSH_LOG" | grep 'BatchMode=yes')"
[[ "$enroll_call" == *"NumberOfPasswordPrompts=1"* ]] || fail "enroll call allows more than one password attempt"
[[ "$enroll_call" == *"debian@192.0.2.10"* ]] || fail "enroll call has the wrong target"
[[ "$gate_call" == *"PasswordAuthentication=no"* ]] || fail "gate call may fall back to a password"
grep -qxF "STDIN ${PUBKEY}" "$SSH_LOG" || fail "public key was not piped to the node"
echo "  PASS"

echo "Test 2: a rejected password names the credentials..."
FAKE_ENROLL_ERR="debian@192.0.2.10: Permission denied (publickey,password)." run "$ENV_ID"
unset FAKE_ENROLL_ERR
[ "$RC" -ne 0 ] || fail "expected a non-zero exit"
[[ "$OUT" == *"enrollment failed"*"rejected our credentials"* ]] || fail "cause not named: ${OUT}"
grep -q 'BatchMode=yes' "$SSH_LOG" && fail "gate ran after a failed enrollment"
echo "  PASS"

echo "Test 3: a refused port after enrollment names fail2ban..."
FAKE_GATE_ERR="ssh: connect to host 192.0.2.10 port 22: Connection refused" run "$ENV_ID"
unset FAKE_GATE_ERR
[ "$RC" -ne 0 ] || fail "expected a non-zero exit"
[[ "$OUT" == *"connectivity gate failed"*"fail2ban"* ]] || fail "cause not named: ${OUT}"
echo "  PASS"

echo "Test 4: an unreachable node names the network path..."
FAKE_ENROLL_ERR="ssh: connect to host 192.0.2.10 port 22: Connection timed out" run "$ENV_ID"
unset FAKE_ENROLL_ERR
[[ "$OUT" == *"did not answer on port 22"* ]] || fail "cause not named: ${OUT}"
echo "  PASS"

echo "Test 5: both calls refuse a host key that is not already trusted..."
run "$ENV_ID"
[ "$(grep -c '^ARGS.*StrictHostKeyChecking=yes' "$SSH_LOG")" -eq 2 ] \
  || fail "a call does not require a known host key: $(grep '^ARGS' "$SSH_LOG")"
grep -q 'accept-new\|StrictHostKeyChecking=no' "$SSH_LOG" && fail "a call trusts a first-seen host key"
echo "  PASS"

# The stderr below is what OpenSSH prints with StrictHostKeyChecking=yes.
echo "Test 6: an unknown host key fails before any password, named as unknown..."
FAKE_ENROLL_ERR="No ED25519 host key is known for 192.0.2.10 and you have requested strict checking.
Host key verification failed." run "$ENV_ID"
unset FAKE_ENROLL_ERR
[ "$RC" -ne 0 ] || fail "expected a non-zero exit"
[[ "$OUT" == *"enrollment failed"*"not in known_hosts"* ]] || fail "unknown key not named: ${OUT}"
[[ "$OUT" == *"out of band"* ]] || fail "no out-of-band verification step: ${OUT}"
[[ "$OUT" == *"differs from the one in known_hosts"* ]] && fail "unknown key reported as changed: ${OUT}"
grep -q 'BatchMode=yes' "$SSH_LOG" && fail "gate ran after a failed enrollment"
echo "  PASS"

echo "Test 7: a changed host key fails before any password, named as changed..."
FAKE_ENROLL_ERR="@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
Host key for 192.0.2.10 has changed and you have requested strict checking.
Host key verification failed." run "$ENV_ID"
unset FAKE_ENROLL_ERR
[ "$RC" -ne 0 ] || fail "expected a non-zero exit"
[[ "$OUT" == *"differs from the one in known_hosts"*"out of band"* ]] || fail "changed key not named: ${OUT}"
[[ "$OUT" == *"is not in known_hosts"* ]] && fail "changed key reported as unknown: ${OUT}"
echo "  PASS"

echo "Test 8: an unknown env is refused without touching ssh..."
run no-such-env
[ "$RC" -ne 0 ] || fail "expected a non-zero exit"
[ ! -s "$SSH_LOG" ] || fail "ssh was called for an unknown env"
echo "  PASS"

echo "OK"
