#!/usr/bin/env bash
# remove-env-data-root.sh — verify remove-env honors DMF_DATA_ROOT and still
# refuses paths outside the resolved data root.

set -euo pipefail

echo "=== remove-env-data-root test ==="

for cmd in bash; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "SKIP: $cmd not on PATH"
    exit 0
  fi
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_DIR}/bin/remove-env.sh"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export DMF_DATA_ROOT="${WORK_DIR}/dmf-data"
mkdir -p "${DMF_DATA_ROOT}/envs"

accepted_env="accepted-env"
accepted_root="${DMF_DATA_ROOT}/envs/${accepted_env}"
accepted_state="${accepted_root}/terraform-state"
mkdir -p "${accepted_root}/inventory/group_vars/all" "${accepted_state}"

accepted_log="${WORK_DIR}/accepted-rm.log"
mkdir -p "${WORK_DIR}/bin"
cat > "${WORK_DIR}/bin/rm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$ACCEPTED_RM_LOG"
exit 0
EOF
chmod +x "${WORK_DIR}/bin/rm"

PATH="${WORK_DIR}/bin:${PATH}" \
ACCEPTED_RM_LOG="${accepted_log}" \
"${SCRIPT}" --yes "${accepted_env}" >/dev/null 2>&1

if ! grep -Fq -- "-rf ${accepted_state}" "${accepted_log}"; then
  echo "FAIL: accepted terraform-state path was not removed"
  cat "${accepted_log}" >&2
  exit 1
fi

if ! grep -Fq -- "-rf ${accepted_root}" "${accepted_log}"; then
  echo "FAIL: accepted env root path was not removed"
  cat "${accepted_log}" >&2
  exit 1
fi

refused_env="refused-env"
refused_root="${WORK_DIR}/outside/envs/${refused_env}"
mkdir -p "${refused_root}/inventory/group_vars/all" "${refused_root}/terraform-state"

refused_output="${WORK_DIR}/refused.out"

export DMF_RESOLVE_ENV_PATHS_LOADED=1
export _DMF_DATA_ROOT="${DMF_DATA_ROOT}"
export REFUSED_ROOT="${refused_root}"

dmf_source_operator_config() { :; }
dmf_resolve_env_paths() {
  DMF_ENV_ROOT="${REFUSED_ROOT}"
  DMF_ENV_TF_STATE_DIR="${REFUSED_ROOT}/terraform-state"
  DMF_ENV_MANIFEST_FILE="${REFUSED_ROOT}/manifest.yaml"
  DMF_ENV_INVENTORY_DIR="${REFUSED_ROOT}/inventory"
  export DMF_ENV_ROOT DMF_ENV_TF_STATE_DIR DMF_ENV_MANIFEST_FILE DMF_ENV_INVENTORY_DIR
  return 0
}
export -f dmf_source_operator_config
export -f dmf_resolve_env_paths

if "${SCRIPT}" --yes "${refused_env}" >"${refused_output}" 2>&1; then
  echo "FAIL: outside-root env unexpectedly succeeded"
  cat "${refused_output}" >&2
  exit 1
fi

if ! grep -q "refusing rm -rf of unexpected path" "${refused_output}"; then
  echo "FAIL: outside-root rejection message missing"
  cat "${refused_output}" >&2
  exit 1
fi

echo "PASS"
