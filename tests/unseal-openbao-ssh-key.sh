#!/usr/bin/env bash
# unseal-openbao-ssh-key.sh — verify OPENBAO_SSH_KEY is threaded into every ssh call.

set -euo pipefail

echo "=== unseal-openbao-ssh-key test ==="

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
export SSH_LOG="${WORK_DIR}/ssh.log"
export SSH_STATUS_COUNT_FILE="${WORK_DIR}/ssh-status-count"

ENV_ID="test-unseal-openbao"
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
ansible_ssh_private_key_file: /tmp/dmf-test-inventory-key
EOF

printf '{"key":"share-one"}\n' > "${SHARE_DIR}/share-1.json"
printf '{"key":"share-two"}\n' > "${SHARE_DIR}/share-2.json"
mkdir -p "${ENV_ROOT}"
touch "${ENV_ROOT}/bundle.sops.yaml"
touch "${WORK_DIR}/inventory-key"

cat > "${WORK_DIR}/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$SSH_LOG"

case "$*" in
  *"command -v curl"*)
    exit 0
    ;;
  *"get pod"*".status.podIP"*)
    printf '192.0.2.42'
    exit 0
    ;;
  *"bao status -format=json"*)
    count=0
    if [ -f "$SSH_STATUS_COUNT_FILE" ]; then
      count="$(cat "$SSH_STATUS_COUNT_FILE")"
    fi
    count=$((count + 1))
    printf '%s' "$count" > "$SSH_STATUS_COUNT_FILE"
    if [ "$count" -le 2 ]; then
      printf '{"sealed":true,"version":"1.17.0","t":5,"n":3,"progress":0,"ha_enabled":true,"cluster_name":"bao"}'
    else
      printf '{"sealed":false,"version":"1.17.0","t":5,"n":3,"progress":3,"ha_enabled":true,"cluster_name":"bao"}'
    fi
    exit 0
    ;;
  *"curl -sS"*)
    cat >/dev/null
    printf '{"sealed":false,"progress":1}'
    exit 0
    ;;
  *)
    printf 'unexpected ssh invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${WORK_DIR}/bin/ssh"

cat > "${WORK_DIR}/bin/security" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${WORK_DIR}/bin/security"

PATH="${WORK_DIR}/bin:${PATH}"

OPENBAO_SSH_TARGET="k3s-admin@127.0.0.1" \
OPENBAO_SSH_KEY="${WORK_DIR}/inventory-key" \
OPENBAO_SHARE_DIR="${SHARE_DIR}" \
"${SCRIPT}" "${ENV_ID}" --yes >/dev/null 2>&1

if [ ! -s "${SSH_LOG}" ]; then
  echo "FAIL: ssh was not invoked"
  exit 1
fi

if grep -v -- "-i ${WORK_DIR}/inventory-key" "${SSH_LOG}" >/dev/null 2>&1; then
  echo "FAIL: at least one ssh invocation missed -i"
  cat "${SSH_LOG}" >&2
  exit 1
fi

echo "PASS"
