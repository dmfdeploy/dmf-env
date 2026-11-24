#!/usr/bin/env bash
# seed-secrets-off-argv.sh — prove that bao_kv_put keeps secret values out of the
# arguments of the processes it starts and hands bao the exact values on stdin.
#
# A stand-in remote_kubectl runs the pod script on this machine, in place of the pod.
# A fake bao on PATH records its arguments, its stdin and BAO_TOKEN. A fake python3
# records its arguments and then runs the real one. Every nonempty value carries a
# marker, so one search covers all of them.
#
# The test watches the three process boundaries the helper uses today: its call to
# remote_kubectl (whose arguments carry the pod's sh -c script), the workstation's
# python3, and bao in the pod. It doesn't see a new external command added to the
# helper; review has to catch that.
#
# Cases:
#   1  several fields
#   2  an empty value next to a filled one
#   3  a multi-line value shaped like a PEM key, with a trailing newline
#   4  quotes, $, backticks, backslashes and = in one value
#   5  a single field
# Each case checks that no process argument holds the marker or the token, that bao got
# the token, and that the JSON on its stdin equals the values, compared through jq.
#
# Set SEED_SCRIPT to run the cases against another copy of bootstrap-secrets.sh.

# The stand-in and the cases set variables inside subshells on purpose, and the sourced
# helper reads BAO_WRITE_TOKEN and BAO_POD.
# shellcheck disable=SC2030,SC2031,SC2034,SC2329
set -euo pipefail

echo "=== seed-secrets-off-argv test ==="

for cmd in bash jq python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "SKIP: $cmd not on PATH"
    exit 0
  fi
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SEED_SCRIPT:-${REPO_DIR}/bin/bootstrap-secrets.sh}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

REAL_PYTHON="$(command -v python3)"
TOKEN="root-token-SEEDTEST-token"
MARK="SEEDTEST-marker"

mkdir -p "${WORK_DIR}/bin"
cat > "${WORK_DIR}/bin/bao" <<'FAKE'
#!/usr/bin/env bash
printf '%s\0' "$@" >> "${STATE_DIR}/bao.argv"
printf '%s' "${BAO_TOKEN-}" > "${STATE_DIR}/bao.token"
if [ "${*: -1}" = "-" ]; then cat > "${STATE_DIR}/bao.stdin"; fi
FAKE
cat > "${WORK_DIR}/bin/python3" <<FAKE
#!/usr/bin/env bash
printf '%s\0' "\$@" >> "\${STATE_DIR}/python.argv"
exec "${REAL_PYTHON}" "\$@"
FAKE
chmod +x "${WORK_DIR}/bin/bao" "${WORK_DIR}/bin/python3"

# run_put NAME PATH KEY VALUE... — call bao_kv_put with the fakes first on PATH.
run_put() {
  local name="$1"
  shift
  STATE_DIR="${WORK_DIR}/state-${name}"
  mkdir -p "${STATE_DIR}"
  (
    export STATE_DIR PATH="${WORK_DIR}/bin:${PATH}"
    # shellcheck source=../bin/bootstrap-secrets.sh disable=SC1090,SC1091
    . "${SCRIPT}"
    BAO_WRITE_TOKEN="${TOKEN}"
    BAO_POD=openbao-0
    # What kubectl exec would run in the pod: the arguments after "--". The
    # arguments of this call are what the workstation puts in a process list.
    remote_kubectl() {
      printf '%s\0' "$@" > "${STATE_DIR}/kubectl.argv"
      shift 6
      "$@"
    }
    bao_kv_put "$@"
  ) >"${STATE_DIR}/out.log" 2>&1 || echo "bao_kv_put exited non-zero" >> "${STATE_DIR}/out.log"
}

FAILS=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAILS=$((FAILS + 1)); }

# check NAME PATH KEY VALUE... — run the case and assert on what the fakes recorded.
check() {
  local name="$1" path="$2"
  shift 2
  run_put "${name}" "${path}" "$@"
  local dir="${WORK_DIR}/state-${name}" jq_args=() k v
  while [ "$#" -gt 0 ]; do
    k="$1" v="$2"
    shift 2
    jq_args+=(--arg "${k}" "${v}")
    # A value without the marker would leak unseen, so every case must mark each one.
    if [ -n "${v}" ] && [[ "${v}" != *"${MARK}"* ]]; then fail "case value for ${k} has no marker"; fi
  done

  local leaked=0 f
  for f in kubectl.argv python.argv bao.argv; do
    [ -e "${dir}/${f}" ] || continue
    if grep -qaF -e "${MARK}" -e "${TOKEN}" "${dir}/${f}"; then leaked=1; echo "    leak in ${f}"; fi
  done
  if [ "${leaked}" -eq 0 ]; then pass "no argument holds a value or the token"; else fail "a value reached an argument"; fi

  if [ "$(cat "${dir}/bao.token" 2>/dev/null)" = "${TOKEN}" ]; then pass "bao got the token"; else fail "bao did not get the token"; fi

  local want got
  want="$(jq -S -c -n '$ARGS.named' "${jq_args[@]}")"
  got="$(jq -S -c . "${dir}/bao.stdin" 2>/dev/null)" || got="(no JSON: $(cat "${dir}/out.log" 2>/dev/null))"
  if [ "${got}" = "${want}" ]; then pass "stdin JSON equals the values"; else fail "stdin JSON differs: got ${got}, want ${want}"; fi
}

echo "Case 1: several fields"
check one secret/t/one username "${MARK} admin" email "${MARK}@b.c" password "${MARK} pw"

echo "Case 2: an empty value"
check two secret/t/two filled "${MARK} x" empty ""

echo "Case 3: PEM-like value"
# PEM-shaped, with a neutral label so that secret scanners don't take it for a key.
pem_begin='-----BEGIN TEST BLOCK-----'
pem_end='-----END TEST BLOCK-----'
check three secret/t/three ssh_key_data "${pem_begin}"$'\nb3Blbn '"${MARK}"$' AAAA\n\nlast line\n'"${pem_end}"$'\n'

echo "Case 4: quotes, dollar, backticks, backslashes, ="
check four secret/t/four tricky "${MARK} \"dq\" 'sq' \$HOME \`id\` \\ \\n =eq= %s"

echo "Case 5: one field"
check five secret/t/five token "${MARK}-single"

if [ "${FAILS}" -ne 0 ]; then
  echo "FAILED: ${FAILS}"
  exit 1
fi
echo "ALL PASS"
