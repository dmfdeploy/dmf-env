#!/usr/bin/env bash
# remove-env-sandbox-noop.sh — regression test: remove-env on a sandbox
# (off-cloud) env must NOT invoke hcloud or the cloud teardown path. This
# locks the no-op invariant for the off-cloud path (refs dmfdeploy#20).
#
# Strategy: PATH-shim rm and hcloud; create a sandbox env (no manifest.yaml);
# assert that hcloud was never invoked AND that the script's STDOUT shows the
# sandbox branch (not the cloud teardown branch).

set -euo pipefail

echo "=== remove-env sandbox no-op test ==="

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

# ── Create a sandbox env (no manifest.yaml → is_sandbox returns true) ──
sandbox_env="sandbox-test"
sandbox_root="${DMF_DATA_ROOT}/envs/${sandbox_env}"
mkdir -p "${sandbox_root}/inventory/group_vars/all" \
         "${sandbox_root}/terraform-state" \
         "${sandbox_root}/ssh"

# ── Shim: rm (pass-through, log invocations) ──
accepted_rm_log="${WORK_DIR}/accepted-rm.log"
mkdir -p "${WORK_DIR}/bin"
cat > "${WORK_DIR}/bin/rm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$ACCEPTED_RM_LOG"
exit 0
EOF
chmod +x "${WORK_DIR}/bin/rm"

# ── Shim: hcloud (should NOT be called for sandbox) ──
hcloud_log="${WORK_DIR}/hcloud.log"
cat > "${WORK_DIR}/bin/hcloud" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HCLOUD_LOG"
exit 0
EOF
chmod +x "${WORK_DIR}/bin/hcloud"

# ── Run remove-env on sandbox ──
PATH="${WORK_DIR}/bin:${PATH}" \
ACCEPTED_RM_LOG="${accepted_rm_log}" \
HCLOUD_LOG="${hcloud_log}" \
  "${SCRIPT}" --yes "${sandbox_env}" >"${WORK_DIR}/remove-output.txt" 2>&1

# ── Assert: rm was called (state + root removed) ──
if ! grep -q -- "-rf" "${accepted_rm_log}"; then
  echo "FAIL: rm was not invoked"
  exit 1
fi

# ── Assert: hcloud was NOT called ──
if [ -s "${hcloud_log}" ]; then
  echo "FAIL: hcloud was invoked for sandbox env:"
  cat "${hcloud_log}" >&2
  exit 1
fi

# ── Assert: STDOUT shows sandbox branch (real signal of is_sandbox path) ──
if ! grep -q "Sandbox environment (no cloud resources)" "${WORK_DIR}/remove-output.txt"; then
  echo "FAIL: stdout missing sandbox message:"
  cat "${WORK_DIR}/remove-output.txt" >&2
  exit 1
fi

# ── Assert: STDOUT does NOT contain the Step 2 cloud key deletion ──
if grep -q "Deleting Hetzner SSH key" "${WORK_DIR}/remove-output.txt"; then
  echo "FAIL: stdout shows cloud SSH key deletion for sandbox env:"
  cat "${WORK_DIR}/remove-output.txt" >&2
  exit 1
fi

echo "PASS"
