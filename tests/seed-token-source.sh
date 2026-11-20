#!/usr/bin/env bash
# seed-token-source.sh — prove which token the OpenBao writes of bootstrap-secrets.sh use,
# that the seed runs as one step of the install, and that no helper makes a root token.
#
# After an install, only the approval executor generates root tokens, and ops-admin never
# holds the generate-root policy. So:
#   - seed-bao and seed-awx-control-node-ssh read the installer's initial root token from
#     stdin and revoke nothing;
#   - seed-install reads the token once and runs the OpenBao seed with it, and never the
#     AWX seed (the AWX role of the install writes that key);
#   - bin/run-playbook.sh names seed-install for the playbooks that run the install;
#   - no function of the script calls `bao operator generate-root`.
#
# The script sources bootstrap-secrets.sh and replaces remote_kubectl with a fake that logs
# the arguments of every call.
#
# Cases:
#   A  the installer's token on stdin is taken as it is: no remote call
#   B  empty stdin: exit 1 with a message that says the seed runs inside the install
#   C  a token that is set already is not read again from stdin
#   D  seed-install reads stdin once and runs the seed; it never runs the AWX seed, even
#      with a key path set
#   E  a failing seed step gives seed-install the same exit status
#   F  run-playbook.sh passes the seed command to the install playbooks and to no other
#   G  the retired helpers are gone, and no code of the script calls generate-root
#   H  the active pod is the second of three; no active pod, or two, stops the script
#   I  the fake rejects a bao subcommand that the real CLI lacks

# The cases set FAKE_* variables inside subshells on purpose: the fake reads them there.
# shellcheck disable=SC2030,SC2031
set -euo pipefail

echo "=== seed-token-source test ==="

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

# The fake kubectl. STATE_DIR holds the log. FAKE_ACTIVE (default openbao-1) lists the
# pods that report is_self, as the active node does. A standby leaves the field out.
remote_kubectl() {
  printf '%s\n' "$*" >> "${STATE_DIR}/argv.log"
  local kind
  case "$*" in
    *"get pods -n openbao"*)
      printf '%s' "${FAKE_PODS-openbao-0 openbao-1 openbao-2}"
      ;;
    *"bao status -format=json"*)
      kind="$(printf '%s' "$*" | sed -E 's/.*exec -n openbao ([^ ]+) --.*/\1/')"
      case " ${FAKE_ACTIVE-openbao-1} " in
        *" ${kind} "*) printf '{"initialized":true,"sealed":false,"is_self":true}' ;;
        *) printf '{"initialized":true,"sealed":false}' ;;
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
  # The sourced functions read these globals.
  # shellcheck disable=SC2034
  BAO_POD="openbao-0"
  BAO_WRITE_TOKEN=""
}

echo "Case A: the installer's token on stdin"
new_case a
read_installer_token <<<"${INSTALLER_TOKEN}"
if [ "${BAO_WRITE_TOKEN}" = "${INSTALLER_TOKEN}" ]; then pass "the write token is the installer's token"; else fail "write token '${BAO_WRITE_TOKEN}'"; fi
if [ ! -s "${STATE_DIR}/argv.log" ]; then pass "no remote call"; else fail "remote call made"; fi

echo "Case B: empty stdin"
new_case b
rc=0
ERR="$( ( read_installer_token </dev/null ) 2>&1 >/dev/null )" || rc=$?
if [ "${rc}" -eq 1 ] && grep -q "stdin holds no token" <<<"${ERR}"; then pass "exit 1 with a message"; else fail "rc ${rc}: ${ERR}"; fi
if grep -q "inside the install" <<<"${ERR}" || grep -q "from the install" <<<"${ERR}"; then pass "the message names the install"; else fail "message: ${ERR}"; fi
if [ ! -s "${STATE_DIR}/argv.log" ]; then pass "no remote call"; else fail "remote call made"; fi

echo "Case C: a token that is set already is not read again"
new_case c
BAO_WRITE_TOKEN="${INSTALLER_TOKEN}"
read_installer_token </dev/null
if [ "${BAO_WRITE_TOKEN}" = "${INSTALLER_TOKEN}" ]; then pass "the token stays"; else fail "token '${BAO_WRITE_TOKEN}'"; fi

echo "Case D: seed-install"
new_case d
SEEN="${STATE_DIR}/seen.log"
# Stand-ins for the seeds: they record the token that they would write with.
cmd_seed_bao() { printf 'bao %s %s\n' "$1" "${BAO_WRITE_TOKEN}" >> "${SEEN}"; }
cmd_seed_awx_ssh() { printf 'awx %s %s\n' "$1" "${BAO_WRITE_TOKEN}" >> "${SEEN}"; }
printf '%s\nextra-line\n' "${INSTALLER_TOKEN}" | (unset DMF_AWX_CONTROL_NODE_SSH_PATH; cmd_seed_install fake-env) 2>/dev/null
if [ "$(cat "${SEEN}")" = "bao fake-env ${INSTALLER_TOKEN}" ]; then pass "seeds OpenBao with the token"; else fail "seen: $(cat "${SEEN}")"; fi
: > "${SEEN}"
printf '%s\n' "${INSTALLER_TOKEN}" | (DMF_AWX_CONTROL_NODE_SSH_PATH=/some/key cmd_seed_install fake-env) 2>/dev/null
if [ "$(cat "${SEEN}")" = "bao fake-env ${INSTALLER_TOKEN}" ]; then pass "never seeds AWX, even with a key path set"; else fail "seen: $(cat "${SEEN}")"; fi
rc=0
(DMF_AWX_CONTROL_NODE_SSH_PATH=/some/key cmd_seed_install fake-env </dev/null) >/dev/null 2>&1 || rc=$?
if [ "${rc}" -eq 1 ]; then pass "no token on stdin stops seed-install"; else fail "rc ${rc}"; fi

echo "Case E: a failing seed step"
new_case e
SEEN="${STATE_DIR}/seen.log"
: > "${SEEN}"
cmd_seed_bao() { printf 'bao\n' >> "${SEEN}"; exit 3; }
rc=0
printf '%s\n' "${INSTALLER_TOKEN}" | (DMF_AWX_CONTROL_NODE_SSH_PATH=/some/key cmd_seed_install fake-env) >/dev/null 2>&1 || rc=$?
if [ "${rc}" -eq 3 ] && [ "$(cat "${SEEN}")" = "bao" ]; then pass "exit 3"; else fail "rc ${rc}, seen: $(cat "${SEEN}")"; fi

echo "Case F: run-playbook.sh passes the seed command to the install playbooks only"
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

echo "Case G: the retired helpers are gone"
for name in acquire_temp_root revoke_temp_root bao_generate_root bao_generate_root_otp login_ops_admin revoke_login_token; do
  if declare -F "${name}" >/dev/null; then fail "${name} is defined"; else pass "${name} is gone"; fi
done
calls="$(grep -vE '^[[:space:]]*#' "${REPO_DIR}/bin/bootstrap-secrets.sh" | grep -cE 'generate-root|generate_root' || true)"
if [ "${calls}" = "0" ]; then pass "no code line of the script names generate-root"; else fail "generate-root in ${calls} code line(s)"; fi
if grep -vE '^[[:space:]]*#' "${REPO_DIR}/bin/bootstrap-secrets.sh" | grep -q 'token revoke'; then fail "the script revokes a token"; else pass "the script revokes no token"; fi
# No message may send the operator to a step that cannot seed: a rerun of seed-bao has no token to read.
repair="$(grep -nE '(echo|printf|die) .*((re-?run|run)[^a-z]*seed-bao|(^|[^a-z])re-?seed)' "${REPO_DIR}/bin/bootstrap-secrets.sh" || true)"
if [ -z "${repair}" ]; then pass "no message tells the operator to rerun seed-bao or reseed"; else fail "message sends the operator to seed-bao: ${repair}"; fi

echo "Case H: the active pod"
new_case h
find_active_bao_pod
if [ "${BAO_POD}" = "openbao-1" ]; then pass "picked openbao-1"; else fail "picked '${BAO_POD}'"; fi
BAO_POD=""
( export FAKE_ACTIVE="openbao-2"; find_active_bao_pod; printf '%s' "${BAO_POD}" > "${STATE_DIR}/picked" ) 2>/dev/null
if [ "$(cat "${STATE_DIR}/picked")" = "openbao-2" ]; then pass "follows the active pod when it moves"; else fail "picked '$(cat "${STATE_DIR}/picked")'"; fi
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

echo "Case I: the fake rejects a subcommand that the real CLI lacks"
new_case i
rc=0
remote_kubectl exec -i -n openbao openbao-0 -- sh -c 'bao token lookup-self -format=json' >/dev/null 2>&1 || rc=$?
if [ "${rc}" -ne 0 ]; then pass "token lookup-self rejected"; else fail "token lookup-self accepted"; fi
invented="$(grep -oE 'bao token [a-z-]+' "${REPO_DIR}/bin/bootstrap-secrets.sh" | grep -vE '^bao token (lookup|revoke|capabilities|create|renew)$' || true)"
if [ -z "${invented}" ]; then pass "every bao token subcommand in the script exists"; else fail "unknown subcommand: ${invented}"; fi

if [ "${FAILS}" -ne 0 ]; then
  echo "=== ${FAILS} failure(s) ==="
  exit 1
fi
echo "=== all passed ==="
