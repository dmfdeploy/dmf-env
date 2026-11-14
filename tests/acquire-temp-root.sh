#!/usr/bin/env bash
# acquire-temp-root.sh — prove that the temporary root token procedure of
# bootstrap-secrets.sh logs in as ops-admin first, sends the login token and the
# OTP to `bao operator generate-root` on stdin, and revokes both tokens.
#
# The script sources bootstrap-secrets.sh and replaces remote_kubectl with a fake
# OpenBao. The fake behaves like OpenBao 2.6 and later: it refuses every
# generate-root call whose token is missing, unknown or revoked. It logs the
# arguments of every call and the revoked tokens.
#
# Cases:
#   A  success: root token returned, every generate-root call carries the login
#      token, no secret value (token, OTP, share, password) in any argv, both
#      tokens revoked and cleared
#   B  wrong ops-admin password: exit 1, no generate-root call
#   C  break-glass file without ops-admin credentials: exit 1, no remote call
#   D  a share submission fails: exit 1, the login token is revoked on exit
#   E  the caller fails after the root token exists: both tokens are revoked on exit
#   F  the fake refuses a missing, an unknown and a revoked token
#   G  the root token revoke fails every try: three tries, exit 1, message with the accessor
#   H  the login token revoke fails every try: exit 1, message with the accessor
#   I  a failure between the last share and the decode: exit 1, message that a root
#      token may exist and how to recover
#   J  a revoke that fails once works on the retry: exit 0
#   L  the active pod is the second of three: find_active_bao_pod picks it, not the first
#   M  no pod is active, or two are: exit 1 with a message
#   K  the fake rejects a bao subcommand that the real CLI lacks (token lookup-self), and the
#      script calls only token subcommands that the real CLI has (lookup, revoke, capabilities)

# The cases set FAKE_* variables inside subshells on purpose: the fake reads them there.
# shellcheck disable=SC2030,SC2031
set -euo pipefail

echo "=== acquire-temp-root test ==="

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

PASSWORD="ops-admin-password-SECRET"
LOGIN_TOKEN="login-token-SECRET"
ROOT_TOKEN="root-token-SECRET"
OTP_VALUE="otp-value-SECRET"
SHARE_ONE="share-one-SECRET"
SHARE_TWO="share-two-SECRET"
SECRETS="${PASSWORD}|${LOGIN_TOKEN}|${ROOT_TOKEN}|${OTP_VALUE}|${SHARE_ONE}|${SHARE_TWO}"

export BAO_REVOKE_RETRY_DELAY=0
export DMF_ENV_INVENTORY_DIR="${WORK_DIR}/inventory"
mkdir -p "${DMF_ENV_INVENTORY_DIR}/group_vars/all"
BREAKGLASS="${WORK_DIR}/breakglass.json"
printf 'eso_openbao_breakglass_file: %s\n' "${BREAKGLASS}" > "${DMF_ENV_INVENTORY_DIR}/group_vars/all/vars.yml"

write_breakglass() {
  jq -n --arg user "$1" --arg password "$2" --arg one "${SHARE_ONE}" --arg two "${SHARE_TWO}" \
    '{shamir_threshold: 2, unseal_keys_hex: [$one, $two]}
     + (if $user == "" then {} else {ops_admin_username: $user, ops_admin_password: $password} end)' \
    > "${BREAKGLASS}"
}

# The authorization of the fake: the token must be the login token and must not be
# revoked. Case F calls it with other tokens, and a mutant that always allows breaks it.
fake_authorized() {
  [ "$1" = "${LOGIN_TOKEN}" ] && ! grep -qx "$1" "${STATE_DIR}/revoked.log"
}

# The fake OpenBao. STATE_DIR holds the logs. FAKE_FAIL_SHARE=1 makes a share fail,
# FAKE_DECODE_FAILS=1 makes the decode fail, FAKE_REVOKE_FAILS (root, login) makes that
# revoke fail every time, and FAKE_REVOKE_FAIL_FIRST=1 makes the first try of each fail.
remote_kubectl() {
  printf '%s\n' "$*" >> "${STATE_DIR}/argv.log"
  local line otp kind
  case "$*" in
    *"bao write -format=json auth/userpass/login/"*"password=-"*)
      line="$(cat)"
      if [ "${line}" = "${PASSWORD}" ]; then
        printf '{"auth":{"client_token":"%s","accessor":"login-accessor"}}' "${LOGIN_TOKEN}"
      else
        echo "Error: permission denied" >&2
        return 2
      fi
      ;;
    *"get pods -n openbao"*)
      printf '%s' "${FAKE_PODS-openbao-0 openbao-1 openbao-2}"
      ;;
    *"bao status -format=json"*)
      # Only the pods in FAKE_ACTIVE (default openbao-1) report is_self, as the active node
      # does. A standby leaves the field out, and the legacy generate-root endpoints answer
      # it with a 500.
      kind="$(printf '%s' "$*" | sed -E 's/.*exec -n openbao ([^ ]+) --.*/\1/')"
      case " ${FAKE_ACTIVE-openbao-1} " in
        *" ${kind} "*) printf '{"initialized":true,"sealed":false,"is_self":true}' ;;
        *) printf '{"initialized":true,"sealed":false}' ;;
      esac
      ;;
    *"bao token revoke -self"*)
      IFS= read -r line || true
      kind=login
      [ "${line}" != "${ROOT_TOKEN}" ] || kind=root
      printf '%s\n' "${kind}" >> "${STATE_DIR}/revoke-attempts.log"
      case " ${FAKE_REVOKE_FAILS:-} " in
        *" ${kind} "*) echo "Error revoking token: connection refused" >&2; return 2 ;;
      esac
      if [ -n "${FAKE_REVOKE_FAIL_FIRST:-}" ] && [ "$(grep -cx "${kind}" "${STATE_DIR}/revoke-attempts.log")" -le "${FAKE_REVOKE_FAIL_FIRST}" ]; then
        echo "Error revoking token: connection refused" >&2
        return 2
      fi
      printf '%s\n' "${line}" >> "${STATE_DIR}/revoked.log"
      ;;
    *"bao token lookup -format=json"*)
      IFS= read -r line || true
      printf '{"data":{"accessor":"root-accessor"}}'
      ;;
    *"bao_generate_root"*)
      IFS= read -r line || true
      printf 'call\n' >> "${STATE_DIR}/generate-root.log"
      if ! fake_authorized "${line}"; then
        echo "Error: 403 permission denied" >&2
        return 2
      fi
      case "$*" in
        *"read -r OTP"*) IFS= read -r otp || true ;;
      esac
      case "$*" in
        *" -cancel"*) ;;
        *" -generate-otp"*) printf '{"otp":"%s"}' "${OTP_VALUE}" ;;
        *" -init"*)
          [ "${otp}" = "${OTP_VALUE}" ] || return 2
          printf '{"nonce":"nonce-value"}'
          ;;
        *" -decode=-"*)
          cat > /dev/null
          [ "${otp}" = "${OTP_VALUE}" ] || return 2
          [ -z "${FAKE_DECODE_FAILS:-}" ] || { echo "Error decoding: internal error" >&2; return 2; }
          printf '{"token":"%s"}' "${ROOT_TOKEN}"
          ;;
        *" -nonce="*)
          line="$(cat)"
          if [ "${FAKE_FAIL_SHARE:-0}" = 1 ]; then
            echo "Error: share rejected" >&2
            return 2
          fi
          printf '%s\n' "${line}" >> "${STATE_DIR}/shares.log"
          if [ "$(wc -l < "${STATE_DIR}/shares.log")" -ge 2 ]; then
            printf '{"encoded_token":"encoded-value"}'
          else
            printf '{"progress":1}'
          fi
          ;;
        *) return 1 ;;
      esac
      ;;
    *)
      echo "unexpected call: $*" >&2
      return 1
      ;;
  esac
}

FAILS=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAILS=$((FAILS + 1)); }

new_case() {
  STATE_DIR="${WORK_DIR}/state-$1"
  mkdir -p "${STATE_DIR}"
  : > "${STATE_DIR}/argv.log"
  : > "${STATE_DIR}/revoked.log"
  : > "${STATE_DIR}/revoke-attempts.log"
  : > "${STATE_DIR}/generate-root.log"
  : > "${STATE_DIR}/shares.log"
  # The sourced functions read BAO_POD and the token globals.
  # shellcheck disable=SC2034
  BAO_POD="openbao-0"
  BAO_ROOT_TOKEN=""
  BAO_LOGIN_TOKEN=""
  # shellcheck disable=SC2034
  BAO_LOGIN_ACCESSOR=""
  # shellcheck disable=SC2034
  BAO_ROOT_ACCESSOR=""
  # shellcheck disable=SC2034
  BAO_ISSUANCE_UNCERTAIN=0
  # shellcheck disable=SC2034
  BAO_REVOKE_FAILED=0
}

# run_acquire [VAR=value...] — acquire_temp_root in a subshell, as a caller that
# succeeds, so its EXIT trap runs. Sets RC and ERR (the text on stderr).
run_acquire() {
  RC=0
  ERR="$( ( for assignment in "$@"; do export "${assignment%%=*}=${assignment#*=}"; done; acquire_temp_root fake-env ) 2>&1 >/dev/null )" || RC=$?
}

echo "Case A: success"
new_case a
write_breakglass ops-admin "${PASSWORD}"
if acquire_temp_root fake-env; then pass "acquire_temp_root exits 0"; else fail "acquire_temp_root failed"; fi
if [ "${BAO_ROOT_TOKEN}" = "${ROOT_TOKEN}" ]; then pass "root token decoded"; else fail "root token not decoded"; fi
if [ "${BAO_LOGIN_TOKEN}" = "${LOGIN_TOKEN}" ]; then pass "login token kept"; else fail "login token missing"; fi
if [ "$(wc -l < "${STATE_DIR}/generate-root.log")" -ge 5 ]; then pass "generate-root ran each step"; else fail "generate-root steps missing"; fi
if grep -qE "${SECRETS}" "${STATE_DIR}/argv.log"; then
  fail "a secret value is in an argument list"
else
  pass "no secret value in any argument list (token, OTP, share, password)"
fi
revoke_temp_root
if [ "$(sort "${STATE_DIR}/revoked.log" | tr '\n' ' ')" = "$(printf '%s\n%s\n' "${LOGIN_TOKEN}" "${ROOT_TOKEN}" | sort | tr '\n' ' ')" ]; then
  pass "both tokens revoked"
else
  fail "revoked tokens: $(tr '\n' ' ' < "${STATE_DIR}/revoked.log")"
fi
if [ -z "${BAO_ROOT_TOKEN}${BAO_LOGIN_TOKEN}" ]; then pass "both tokens cleared"; else fail "a token was not cleared"; fi

echo "Case B: wrong ops-admin password"
new_case b
write_breakglass ops-admin "wrong-password"
rc=0
( acquire_temp_root fake-env ) 2>/dev/null || rc=$?
if [ "${rc}" -eq 1 ]; then pass "exit 1"; else fail "exit ${rc}"; fi
if [ ! -s "${STATE_DIR}/generate-root.log" ]; then pass "no generate-root call"; else fail "generate-root ran without a login"; fi

echo "Case C: break-glass file without ops-admin credentials"
new_case c
write_breakglass "" ""
rc=0
( acquire_temp_root fake-env ) 2>/dev/null || rc=$?
if [ "${rc}" -eq 1 ]; then pass "exit 1"; else fail "exit ${rc}"; fi
if [ ! -s "${STATE_DIR}/argv.log" ]; then pass "no remote call"; else fail "remote call made"; fi

echo "Case D: a share submission fails"
new_case d
write_breakglass ops-admin "${PASSWORD}"
rc=0
( FAKE_FAIL_SHARE=1 acquire_temp_root fake-env ) 2>/dev/null || rc=$?
if [ "${rc}" -eq 1 ]; then pass "exit 1"; else fail "exit ${rc}"; fi
if grep -qx "${LOGIN_TOKEN}" "${STATE_DIR}/revoked.log"; then pass "login token revoked on exit"; else fail "login token not revoked"; fi

echo "Case E: the caller fails after the root token exists"
new_case e
write_breakglass ops-admin "${PASSWORD}"
rc=0
( acquire_temp_root fake-env; exit 7 ) 2>/dev/null || rc=$?
if [ "${rc}" -eq 7 ]; then pass "exit 7"; else fail "exit ${rc}"; fi
if grep -qx "${ROOT_TOKEN}" "${STATE_DIR}/revoked.log" && grep -qx "${LOGIN_TOKEN}" "${STATE_DIR}/revoked.log"; then
  pass "root token and login token revoked on exit"
else
  fail "revoked tokens: $(tr '\n' ' ' < "${STATE_DIR}/revoked.log")"
fi

echo "Case F: the fake refuses a missing, an unknown and a revoked token"
new_case f
for token in "" "unknown-token"; do
  rc=0
  BAO_LOGIN_TOKEN="${token}" bao_generate_root -generate-otp </dev/null >/dev/null 2>&1 || rc=$?
  if [ "${rc}" -ne 0 ]; then pass "refused token '${token:-<missing>}'"; else fail "accepted token '${token:-<missing>}'"; fi
done
printf '%s\n' "${LOGIN_TOKEN}" >> "${STATE_DIR}/revoked.log"
rc=0
BAO_LOGIN_TOKEN="${LOGIN_TOKEN}" bao_generate_root -generate-otp </dev/null >/dev/null 2>&1 || rc=$?
if [ "${rc}" -ne 0 ]; then pass "refused a revoked token"; else fail "accepted a revoked token"; fi
: > "${STATE_DIR}/revoked.log"
rc=0
BAO_LOGIN_TOKEN="${LOGIN_TOKEN}" bao_generate_root -generate-otp </dev/null >/dev/null 2>&1 || rc=$?
if [ "${rc}" -eq 0 ]; then pass "accepted the live login token"; else fail "refused the live login token"; fi

echo "Case G: the root token revoke fails every try"
new_case g
write_breakglass ops-admin "${PASSWORD}"
run_acquire FAKE_REVOKE_FAILS=root
if [ "${RC}" -eq 1 ]; then pass "exit 1"; else fail "exit ${RC}"; fi
if [ "$(grep -cx root "${STATE_DIR}/revoke-attempts.log")" -eq 3 ]; then pass "three tries"; else fail "tries: $(grep -cx root "${STATE_DIR}/revoke-attempts.log")"; fi
if grep -q "could not revoke the temporary root token" <<<"${ERR}" && grep -q "root-accessor" <<<"${ERR}"; then
  pass "message names the live token and its accessor"
else
  fail "message: ${ERR}"
fi
if grep -qx "${LOGIN_TOKEN}" "${STATE_DIR}/revoked.log"; then pass "login token still revoked"; else fail "login token not revoked"; fi
if grep -qE "${SECRETS}" <<<"${ERR}"; then fail "the message holds a secret value"; else pass "the message holds no secret value"; fi

echo "Case H: the login token revoke fails every try"
new_case h
write_breakglass ops-admin "${PASSWORD}"
run_acquire FAKE_REVOKE_FAILS=login
if [ "${RC}" -eq 1 ]; then pass "exit 1"; else fail "exit ${RC}"; fi
if grep -q "could not revoke the ops-admin login token" <<<"${ERR}" && grep -q "login-accessor" <<<"${ERR}"; then
  pass "message names the login token accessor"
else
  fail "message: ${ERR}"
fi
if grep -qx "${ROOT_TOKEN}" "${STATE_DIR}/revoked.log"; then pass "root token still revoked"; else fail "root token not revoked"; fi

echo "Case I: a failure between the last share and the decode"
new_case i
write_breakglass ops-admin "${PASSWORD}"
run_acquire FAKE_DECODE_FAILS=1
if [ "${RC}" -eq 1 ]; then pass "exit 1"; else fail "exit ${RC}"; fi
if grep -q "a root token may exist" <<<"${ERR}" && grep -q "bao list auth/token/accessors" <<<"${ERR}"; then
  pass "message says a root token may exist and how to recover"
else
  fail "message: ${ERR}"
fi
if grep -qx "${LOGIN_TOKEN}" "${STATE_DIR}/revoked.log"; then pass "login token revoked"; else fail "login token not revoked"; fi

echo "Case J: a revoke that fails once works on the retry"
new_case j
write_breakglass ops-admin "${PASSWORD}"
run_acquire FAKE_REVOKE_FAIL_FIRST=1
if [ "${RC}" -eq 0 ]; then pass "exit 0"; else fail "exit ${RC}: ${ERR}"; fi
if grep -qx "${ROOT_TOKEN}" "${STATE_DIR}/revoked.log" && grep -qx "${LOGIN_TOKEN}" "${STATE_DIR}/revoked.log"; then
  pass "both tokens revoked after a retry"
else
  fail "revoked tokens: $(tr '\n' ' ' < "${STATE_DIR}/revoked.log")"
fi

echo "Case L: the active pod is the second of three"
new_case l
find_active_bao_pod
if [ "${BAO_POD}" = "openbao-1" ]; then pass "picked openbao-1"; else fail "picked '${BAO_POD}'"; fi
BAO_POD=""
( export FAKE_ACTIVE="openbao-2"; find_active_bao_pod; printf '%s' "${BAO_POD}" > "${STATE_DIR}/picked" ) 2>/dev/null
if [ "$(cat "${STATE_DIR}/picked")" = "openbao-2" ]; then pass "follows the active pod when it moves"; else fail "picked '$(cat "${STATE_DIR}/picked")'"; fi

echo "Case M: no active pod, or two"
new_case m
for active in "" "openbao-0 openbao-1"; do
  rc=0
  ERR="$( ( export FAKE_ACTIVE="${active}"; find_active_bao_pod ) 2>&1 >/dev/null )" || rc=$?
  if [ "${rc}" -eq 1 ] && grep -q "expected exactly one active OpenBao pod" <<<"${ERR}"; then
    pass "refused with active pods '${active:-none}'"
  else
    fail "active pods '${active:-none}': rc ${rc}: ${ERR}"
  fi
done
rc=0
( export FAKE_PODS=""; find_active_bao_pod ) >/dev/null 2>&1 || rc=$?
if [ "${rc}" -eq 1 ]; then pass "refused with no pod"; else fail "no pod: rc ${rc}"; fi
invented="$(grep -c "items\[0\]" "${REPO_DIR}/bin/bootstrap-secrets.sh" || true)"
if [ "${invented}" = "0" ]; then pass "no caller takes the first pod of the list"; else fail "items[0] in bootstrap-secrets.sh: ${invented}"; fi

echo "Case K: the fake rejects a subcommand that the real CLI lacks"
new_case k
rc=0
printf '%s\n' "${ROOT_TOKEN}" | remote_kubectl exec -i -n openbao openbao-0 -- sh -c 'bao token lookup-self -format=json' >/dev/null 2>&1 || rc=$?
if [ "${rc}" -ne 0 ]; then pass "token lookup-self rejected"; else fail "token lookup-self accepted"; fi
invented="$(grep -oE 'bao token [a-z-]+' "${REPO_DIR}/bin/bootstrap-secrets.sh" | grep -vE '^bao token (lookup|revoke|capabilities|create|renew)$' || true)"
if [ -z "${invented}" ]; then pass "every bao token subcommand in the script exists"; else fail "unknown subcommand: ${invented}"; fi

if [ "${FAILS}" -ne 0 ]; then
  echo "=== ${FAILS} failure(s) ==="
  exit 1
fi
echo "=== all passed ==="
