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
ENV_KNOWN_HOSTS="${DMF_DATA_ROOT}/envs/${ENV_ID}/ssh/known_hosts"
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
# FAKE_GATE_ERR make the matching call fail with that stderr. ssh -G (resolve
# the config, never connect) goes to the real ssh. For each connection call the
# fake also logs which known-hosts sources the real ssh would use, with
# FAKE_USER_CONFIG standing in for the user's ~/.ssh/config: -F reads a file
# in its place, with the same precedence.
REAL_SSH="$(command -v ssh || true)"
export REAL_SSH
cat > "${WORK_DIR}/bin/ssh" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  [ "$a" = "-G" ] && exec "$REAL_SSH" "$@"
done
printf 'ARGS %s\n' "$*" >> "$SSH_LOG"
if [ -n "${REAL_SSH:-}" ]; then
  "$REAL_SSH" -G -F "${FAKE_USER_CONFIG:-/dev/null}" "$@" 2>/dev/null </dev/null |
    grep -iE '^(userknownhostsfile|globalknownhostsfile|knownhostscommand|stricthostkeychecking|verifyhostkeydns) ' |
    sed 's/^/RESOLVED /' >> "$SSH_LOG"
fi
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
[[ "$OUT" == *"enrollment failed"*"is not in ${ENV_KNOWN_HOSTS}"* ]] || fail "unknown key not named: ${OUT}"
[[ "$OUT" == *"out of band"* ]] || fail "no out-of-band verification step: ${OUT}"
[[ "$OUT" == *"differs from the one in"* ]] && fail "unknown key reported as changed: ${OUT}"
grep -q 'BatchMode=yes' "$SSH_LOG" && fail "gate ran after a failed enrollment"
echo "  PASS"

echo "Test 7: a changed host key fails before any password, named as changed..."
FAKE_ENROLL_ERR="@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
Host key for 192.0.2.10 has changed and you have requested strict checking.
Host key verification failed." run "$ENV_ID"
unset FAKE_ENROLL_ERR
[ "$RC" -ne 0 ] || fail "expected a non-zero exit"
[[ "$OUT" == *"differs from the one in ${ENV_KNOWN_HOSTS}"*"out of band"* ]] || fail "changed key not named: ${OUT}"
[[ "$OUT" == *"is not in "* ]] && fail "changed key reported as unknown: ${OUT}"
echo "  PASS"

echo "Test 8: a user ssh config cannot change where host keys are trusted from..."
if [ -z "$REAL_SSH" ]; then
  echo "  SKIP: no real ssh to resolve the config"
else
  # A user config that points every host at another known_hosts file (one
  # holding a key the env never verified) and adds the other trust sources.
  EVIL_KNOWN_HOSTS="${WORK_DIR}/elsewhere/known_hosts"
  cat > "${WORK_DIR}/user-ssh-config" <<CFG
Host *
  UserKnownHostsFile ${EVIL_KNOWN_HOSTS}
  GlobalKnownHostsFile ${EVIL_KNOWN_HOSTS}
  StrictHostKeyChecking no
  VerifyHostKeyDNS yes
CFG
  if "$REAL_SSH" -F /dev/null -G -o KnownHostsCommand=none localhost >/dev/null 2>&1; then
    echo "  KnownHostsCommand /bin/cat ${EVIL_KNOWN_HOSTS}" >> "${WORK_DIR}/user-ssh-config"
  fi
  FAKE_USER_CONFIG="${WORK_DIR}/user-ssh-config" run "$ENV_ID"
  [ "$RC" -eq 0 ] || fail "expected exit 0, got ${RC}: ${OUT}"
  resolved="$(grep '^RESOLVED' "$SSH_LOG")"
  [ "$(grep -c '^ARGS' "$SSH_LOG")" -eq 2 ] || fail "expected two connection calls"
  [ "$(grep -c "^RESOLVED userknownhostsfile ${ENV_KNOWN_HOSTS}\$" "$SSH_LOG")" -eq 2 ] \
    || fail "a call does not trust the env's known_hosts alone: ${resolved}"
  [ "$(grep -c '^RESOLVED globalknownhostsfile /dev/null$' "$SSH_LOG")" -eq 2 ] \
    || fail "a call reads another global known_hosts: ${resolved}"
  [ "$(grep -c '^RESOLVED stricthostkeychecking true$' "$SSH_LOG")" -eq 2 ] \
    || fail "a call does not check host keys strictly: ${resolved}"
  [ "$(grep -c '^RESOLVED verifyhostkeydns false$' "$SSH_LOG")" -eq 2 ] \
    || fail "a call trusts host keys from DNS: ${resolved}"
  grep -q "${EVIL_KNOWN_HOSTS}" <<< "$resolved" && fail "a call reads the user config's known_hosts: ${resolved}"
  echo "  PASS"
fi

echo "Test 9: an unknown env is refused without touching ssh..."
run no-such-env
[ "$RC" -ne 0 ] || fail "expected a non-zero exit"
[ ! -s "$SSH_LOG" ] || fail "ssh was called for an unknown env"
echo "  PASS"

echo "OK"
