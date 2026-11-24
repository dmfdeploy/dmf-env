#!/usr/bin/env bash
# remove-env-provider.sh — remove-env.sh and tf-destroy.sh decide from the
# manifest's metadata.provider, never from the inventory (refs dmfdeploy#18,
# dmfdeploy#997). Automated Hetzner teardown is off.
#
# Cases:
#   1. hetzner manifest: both refuse with the #997 message, exit non-zero,
#      remove nothing and call no stub, with --yes and with --check.
#   2. sandbox manifest: tf-destroy refuses, and remove-env removes the env dir
#      locally even when the inventory says dmf_provider: hetzner (the manifest
#      decides).
#   3. missing manifest, missing provider, unknown provider: both refuse and
#      leave the env directory untouched (remove-env also with --check).
#   4. the same refusals, plus malformed YAML and `provider: null`, in a partial
#      env dir with no inventory and no bundle. dmf_resolve_env_paths fails for
#      it, so remove-env.sh takes its fallback path.
#   5. a partial sandbox dir: --check lists the removal and changes nothing;
#      --yes removes it locally with no hcloud or tf-destroy call.
#   6. an invalid env id (`../victim` next to a sandbox manifest outside envs/,
#      an id with a slash), and an env dir that is a symlink out of envs/: both
#      refuse with --yes and --check and the target survives. tf-destroy
#      refuses a bad id.
#   7. anything at <env>/terraform-state (a dir, a file, a symlink to a dir, a
#      broken symlink) in a sandbox env: remove-env refuses with --yes and
#      --check and the env dir survives.
#   8. custom state path: a sandbox env whose state is somewhere else (for
#      example <env>/tofu/terraform.tfstate) is REMOVED. This is the accepted
#      risk of trusting the manifest; the test documents it.
#
# Set REMOVE_ENV_SCRIPT and TF_DESTROY_SCRIPT to test other copies of the scripts.

set -euo pipefail

echo "=== remove-env provider test ==="

for cmd in bash yq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "SKIP: $cmd not on PATH"
    exit 0
  fi
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export DMF_DATA_ROOT="${WORK_DIR}/dmf-data"
mkdir -p "${DMF_DATA_ROOT}/envs" "${WORK_DIR}/bin"

# Run copies of the scripts next to stub tf-destroy.sh and tf-apply.sh, so no
# test can reach the real terraform. The stubs record their calls. The real
# tf-destroy.sh runs under a different name for the tf-destroy cases.
mkdir -p "${WORK_DIR}/repo/bin"
cp -R "${REPO_DIR}/bin/lib" "${WORK_DIR}/repo/bin/lib"
cp "${REMOVE_ENV_SCRIPT:-${REPO_DIR}/bin/remove-env.sh}" "${WORK_DIR}/repo/bin/remove-env.sh"
SCRIPT="${WORK_DIR}/repo/bin/remove-env.sh"
chmod +x "${SCRIPT}"
cat > "${WORK_DIR}/repo/bin/tf-destroy.sh" <<'STUB'
#!/usr/bin/env bash
printf 'tf-destroy %s\n' "$*" >> "$CALLS_LOG"
STUB
chmod +x "${WORK_DIR}/repo/bin/tf-destroy.sh"
cp "${TF_DESTROY_SCRIPT:-${REPO_DIR}/bin/tf-destroy.sh}" "${WORK_DIR}/repo/bin/tf-destroy-real.sh"
chmod +x "${WORK_DIR}/repo/bin/tf-destroy-real.sh"
cat > "${WORK_DIR}/repo/bin/tf-apply.sh" <<'STUB'
#!/usr/bin/env bash
printf 'tf-apply %s\n' "$*" >> "$CALLS_LOG"
STUB
chmod +x "${WORK_DIR}/repo/bin/tf-apply.sh"

CALLS_LOG="${WORK_DIR}/calls.log"
for tool in hcloud tofu; do
  cat > "${WORK_DIR}/bin/${tool}" <<STUB
#!/usr/bin/env bash
printf '${tool} %s\\n' "\$*" >> "\$CALLS_LOG"
STUB
  chmod +x "${WORK_DIR}/bin/${tool}"
done

# new_env <id> <manifest-provider-block>: create an env with an ssh dir and,
# unless the block is "none", a wizard-shaped manifest.
new_env() {
  local id="$1" provider_line="$2" root="${DMF_DATA_ROOT}/envs/$1"
  mkdir -p "${root}/inventory/group_vars/all" "${root}/ssh"
  [ "$provider_line" = none ] && return 0
  {
    echo "apiVersion: dmf.example.test/v1alpha1"
    echo "kind: ResourceProfile"
    echo "metadata:"
    echo "  name: ${id}"
    # The wizard's shape: metadata.provider is a plain name; spec.provider is
    # written twice, a name first and then a mapping (which wins when parsed).
    [ -n "$provider_line" ] && echo "  provider: ${provider_line}"
    echo "spec:"
    [ -n "$provider_line" ] && echo "  provider: ${provider_line}"
    echo "  architecture: arm64"
    echo "  provider:"
    echo "    cloud:"
    echo "      kind: ${provider_line:-none}"
    echo "      node_address: node.example.test"
  } > "${root}/manifest.yaml"
}

run_remove() { # <args...>; output in $WORK_DIR/out.txt
  : > "${CALLS_LOG}"
  PATH="${WORK_DIR}/bin:${PATH}" CALLS_LOG="${CALLS_LOG}" \
    "${SCRIPT}" "$@" >"${WORK_DIR}/out.txt" 2>&1
}

run_destroy() { # <env-id>; output in $WORK_DIR/out.txt
  : > "${CALLS_LOG}"
  PATH="${WORK_DIR}/bin:${PATH}" CALLS_LOG="${CALLS_LOG}" \
    "${WORK_DIR}/repo/bin/tf-destroy-real.sh" "$@" >"${WORK_DIR}/out.txt" 2>&1
}

# no_calls <label>: fail if any stub recorded a call.
no_calls() {
  [ ! -s "${CALLS_LOG}" ] || { echo "FAIL: $1 called:"; cat "${CALLS_LOG}" >&2; exit 1; }
}

# refused <label> <dir>: the last run failed with an ERROR, called nothing and
# left the env dir in place.
refused() {
  grep -q "^ERROR:" "${WORK_DIR}/out.txt" || fail "$1: no error message"
  no_calls "$1"
  [ -d "$2/ssh" ] || fail "$1: env dir was touched"
}

fail() { echo "FAIL: $1"; cat "${WORK_DIR}/out.txt" >&2; exit 1; }

# ── 1. hetzner manifest: both scripts refuse ──
new_env hetzner-env hetzner
for mode in --yes --check; do
  run_remove "$mode" hetzner-env && fail "remove-env hetzner ${mode}: expected a non-zero exit"
  grep -q "dmfdeploy#997" "${WORK_DIR}/out.txt" || fail "remove-env hetzner ${mode}: no #997 message"
  refused "remove-env hetzner ${mode}" "${DMF_DATA_ROOT}/envs/hetzner-env"
done
run_destroy hetzner-env && fail "tf-destroy hetzner: expected a non-zero exit"
grep -q "dmfdeploy#997" "${WORK_DIR}/out.txt" || fail "tf-destroy hetzner: no #997 message"
refused "tf-destroy hetzner" "${DMF_DATA_ROOT}/envs/hetzner-env"

# ── 2. sandbox manifest: tf-destroy refuses, remove-env removes locally ──
new_env sandbox-env sandbox
echo "dmf_provider: hetzner" > "${DMF_DATA_ROOT}/envs/sandbox-env/inventory/group_vars/all/main.yml"
run_destroy sandbox-env && fail "tf-destroy did not refuse a sandbox manifest"
grep -q "sandbox has no Terraform" "${WORK_DIR}/out.txt" || fail "tf-destroy sandbox: wrong refusal"
refused "tf-destroy sandbox" "${DMF_DATA_ROOT}/envs/sandbox-env"
# The manifest decides: an inventory that disagrees does not stop the removal.
run_remove --yes sandbox-env || fail "sandbox teardown did not succeed"
no_calls "sandbox env"
grep -q "Sandbox environment (no cloud resources)" "${WORK_DIR}/out.txt" || fail "sandbox branch message missing"
[ ! -d "${DMF_DATA_ROOT}/envs/sandbox-env" ] || fail "sandbox env dir was not removed"

# ── 3. no usable provider: refuse, leave everything in place ──
new_env no-manifest-env none
new_env no-provider-env ""
new_env unknown-env aliyun
for id in no-manifest-env no-provider-env unknown-env; do
  for mode in --yes "--check"; do
    if run_remove "$mode" "$id"; then
      fail "${id} ${mode}: expected a non-zero exit"
    fi
    refused "${id} ${mode}" "${DMF_DATA_ROOT}/envs/${id}"
  done
  run_destroy "$id" && fail "${id} tf-destroy: expected a non-zero exit"
  refused "${id} tf-destroy" "${DMF_DATA_ROOT}/envs/${id}"
done

# ── 4. partial env dir (no inventory, no bundle): fallback path ──
# new_partial <id> <manifest-body|none>: only ssh, plus a
# manifest holding the given text. Asserts the fixture really is unresolvable.
new_partial() {
  local id="$1" body="$2" root="${DMF_DATA_ROOT}/envs/$1"
  mkdir -p "${root}/ssh"
  [ "$body" = none ] || printf '%b' "$body" > "${root}/manifest.yaml"
}

new_partial partial-no-manifest none
new_partial partial-unknown 'metadata:\n  provider: aliyun\n'
new_partial partial-null 'metadata:\n  provider: null\n'
new_partial partial-malformed 'metadata: [unclosed\n  provider: sandbox\n'
for id in partial-no-manifest partial-unknown partial-null partial-malformed; do
  for mode in --yes "--check"; do
    if run_remove "$mode" "$id"; then
      fail "${id} ${mode}: expected a non-zero exit"
    fi
    grep -q "partial/unrecognised env dir" "${WORK_DIR}/out.txt" || fail "${id} ${mode}: fallback path was not used"
    refused "${id} ${mode}" "${DMF_DATA_ROOT}/envs/${id}"
  done
  run_destroy "$id" && fail "${id} tf-destroy: expected a non-zero exit"
  refused "${id} tf-destroy" "${DMF_DATA_ROOT}/envs/${id}"
done

# ── 5. partial sandbox dir ──
new_partial partial-sandbox 'metadata:\n  provider: sandbox\n'
run_remove --check partial-sandbox || fail "partial sandbox --check did not succeed"
grep -q "partial/unrecognised env dir" "${WORK_DIR}/out.txt" || fail "partial sandbox --check: fallback path was not used"
grep -q "DRY-RUN" "${WORK_DIR}/out.txt" || fail "partial sandbox --check: no dry-run listing"
[ ! -s "${CALLS_LOG}" ] || { echo "FAIL: partial sandbox --check called:"; cat "${CALLS_LOG}" >&2; exit 1; }
[ -d "${DMF_DATA_ROOT}/envs/partial-sandbox/ssh" ] || fail "partial sandbox --check removed files"
run_remove --yes partial-sandbox || fail "partial sandbox teardown did not succeed"
grep -q "partial/unrecognised env dir" "${WORK_DIR}/out.txt" || fail "partial sandbox: fallback path was not used"
[ ! -s "${CALLS_LOG}" ] || { echo "FAIL: partial sandbox called:"; cat "${CALLS_LOG}" >&2; exit 1; }
[ ! -d "${DMF_DATA_ROOT}/envs/partial-sandbox" ] || fail "partial sandbox dir was not removed"

# ── 6. path escapes: invalid ids and a symlinked env dir ──
# victim_dir <dir>: a sandbox env outside envs/, with an inventory.
victim_dir() {
  mkdir -p "$1/inventory/group_vars/all" "$1/ssh"
  printf 'metadata:\n  provider: sandbox\n' > "$1/manifest.yaml"
}

victim_dir "${DMF_DATA_ROOT}/victim"
mkdir -p "${DMF_DATA_ROOT}/envs/a"
victim_dir "${DMF_DATA_ROOT}/envs/a/b"
victim_dir "${WORK_DIR}/outside/target"
ln -s "${WORK_DIR}/outside/target" "${DMF_DATA_ROOT}/envs/linked-env"
for pair in "../victim:${DMF_DATA_ROOT}/victim" "a/b:${DMF_DATA_ROOT}/envs/a/b" \
            "linked-env:${WORK_DIR}/outside/target"; do
  id="${pair%%:*}"; target="${pair#*:}"
  for mode in --yes --check; do
    run_remove "$mode" "$id" && fail "remove-env ${id} ${mode}: expected a non-zero exit"
    refused "remove-env ${id} ${mode}" "$target"
    [ -f "${target}/manifest.yaml" ] || fail "remove-env ${id} ${mode}: target manifest was touched"
  done
done
for id in ../victim a/b; do
  run_destroy "$id" && fail "tf-destroy ${id}: expected a non-zero exit"
  grep -q "invalid env id" "${WORK_DIR}/out.txt" || fail "tf-destroy ${id}: no invalid-id message"
  refused "tf-destroy ${id}" "${DMF_DATA_ROOT}/victim"
done
run_destroy && fail "tf-destroy with no id: expected a non-zero exit"
grep -q "dmfdeploy#997" "${WORK_DIR}/out.txt" || fail "tf-destroy no-arg: no #997 message"
no_calls "tf-destroy no-arg"

# ── 7. anything at <env>/terraform-state: refuse ──
# state_case <label> <setup-command...>: a sandbox env, then the command run
# with the state path as its last argument.
state_case() {
  local label="$1"; shift
  local root="${DMF_DATA_ROOT}/envs/state-env"
  rm -rf "$root" "${WORK_DIR}/elsewhere"
  new_env state-env sandbox
  mkdir -p "${WORK_DIR}/elsewhere"
  "$@" "${root}/terraform-state"
  for mode in --yes --check; do
    run_remove "$mode" state-env && fail "${label} ${mode}: expected a non-zero exit"
    grep -q "never creates terraform-state for a sandbox" "${WORK_DIR}/out.txt" || fail "${label} ${mode}: wrong refusal"
    refused "${label} ${mode}" "$root"
    [ -f "${root}/manifest.yaml" ] || fail "${label} ${mode}: manifest was touched"
  done
}
state_case "state dir" mkdir
state_case "state file" touch
state_case "symlink to a dir" ln -s "${WORK_DIR}/elsewhere"
state_case "broken symlink" ln -s "${WORK_DIR}/does-not-exist"
[ -d "${WORK_DIR}/elsewhere" ] || fail "symlink target was touched"

# ── 8. custom state path: removed (accepted risk) ──
# A sandbox manifest with state somewhere other than <env>/terraform-state is
# treated as a sandbox. The whole env dir goes, including that state.
root="${DMF_DATA_ROOT}/envs/custom-state-env"
new_env custom-state-env sandbox
mkdir -p "${root}/tofu"
echo '{}' > "${root}/tofu/terraform.tfstate"
run_remove --yes custom-state-env || fail "custom state path: teardown did not succeed"
no_calls "custom state path"
[ ! -e "$root" ] || fail "custom state path: env dir was not removed"

echo "PASS"
