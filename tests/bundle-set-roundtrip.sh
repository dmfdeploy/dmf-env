#!/usr/bin/env bash
# bundle-set-roundtrip.sh — smoke test for bundle_set de-masking and CWD-independent
# .sops resolution (Task A+B from P3a fix). Validates round-trip encrypt/decrypt
# of dummy secrets WITHOUT a live cluster.
#
# Skip cleanly if sops/age/age-keygen are not available. Generates a throwaway
# age key and creates a cloud-style .sops.yaml layout, then proves CWD-independence
# by running bundle_set from a directory OUTSIDE the fake repo.

set -euo pipefail

echo "=== bundle-set-roundtrip test ==="

# Skip if required tools are missing
if ! command -v sops >/dev/null 2>&1; then
  echo "SKIP: sops not on PATH"
  exit 0
fi
if ! command -v age >/dev/null 2>&1; then
  echo "SKIP: age not on PATH"
  exit 0
fi
if ! command -v age-keygen >/dev/null 2>&1; then
  echo "SKIP: age-keygen not on PATH"
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not on PATH"
  exit 0
fi

# Create temporary workspace
WORK_DIR="$(mktemp -d)"
FAKE_REPO_DIR="${WORK_DIR}/fake-repo"
FAKE_BUNDLE_DIR="${WORK_DIR}/bundle-store"
AGE_KEY_DIR="${WORK_DIR}/age-keys"
EXEC_DIR="${WORK_DIR}/exec-outside-repo"
mkdir -p "$FAKE_REPO_DIR" "$FAKE_BUNDLE_DIR" "$AGE_KEY_DIR" "$EXEC_DIR"

trap 'rm -rf "$WORK_DIR"' EXIT

# Generate throwaway age key
AGE_KEY_FILE="${AGE_KEY_DIR}/keys.txt"
age-keygen -o "$AGE_KEY_FILE" >/dev/null 2>&1
AGE_PUBKEY="$(age-keygen -y "$AGE_KEY_FILE" 2>/dev/null)"
export SOPS_AGE_KEY_FILE="$AGE_KEY_FILE"

# Create new-layout .sops layout:
# - Co-located .sops.yaml beside the bundle (new-layout sandbox style)
# - No repo-level .sops.yaml needed
BUNDLE_FILE="${FAKE_BUNDLE_DIR}/bundle.sops.yaml"
SOPS_CONFIG="${FAKE_BUNDLE_DIR}/.sops.yaml"

cat > "$SOPS_CONFIG" <<EOF
creation_rules:
  - path_regex: '.*\.sops\.yaml\$'
    age: ${AGE_PUBKEY}
EOF

# Create initial bundle (minimal valid structure) - plaintext first
cat > "$BUNDLE_FILE" <<'BUNDLE_JSON'
{
  "metadata": {
    "environment": "test-fakeenv",
    "provider": "sandbox",
    "base_domain": "test.example.com"
  },
  "bootstrap_admin": {
    "username": "testadmin",
    "email": "testadmin@test.example.com",
    "password": "initial_password_123456"
  },
  "cluster": {
    "k3s_token": "test_k3s_token_123456789"
  },
  "apps": {
    "zot": {
      "service_password": "test_zot_pass"
    }
  },
  "providers": {},
  "notifications": {},
  "object_storage": {}
}
BUNDLE_JSON

# Encrypt with sops to create the encrypted bundle
sops --config "$SOPS_CONFIG" --encrypt "$BUNDLE_FILE" > "$BUNDLE_FILE.encrypted"
mv "$BUNDLE_FILE.encrypted" "$BUNDLE_FILE"

echo "Testing new-layout .sops resolution (co-located .sops.yaml beside bundle)..."
echo "  - Bundle: $BUNDLE_FILE"
echo "  - Co-located .sops.yaml: $(dirname "$BUNDLE_FILE")/.sops.yaml"
echo ""

# Source the real bootstrap-secrets.sh to get the real functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP_SCRIPT="${SCRIPT_DIR}/bin/bootstrap-secrets.sh"
if [ ! -f "$BOOTSTRAP_SCRIPT" ]; then
  echo "FAIL: bootstrap-secrets.sh not found at $BOOTSTRAP_SCRIPT"
  exit 1
fi
# Source the script — functions get defined, but dispatch is gated by BASH_SOURCE check
# shellcheck source=/dev/null
. "$BOOTSTRAP_SCRIPT"

# Run the test from EXEC_DIR (outside the fake repo)
cd "$EXEC_DIR" || exit 1

# Override the globals so sourced functions use the fake layout.
# DMF_ENV_BUNDLE_FILE is the bundle path.
# bundle_sops_config_file resolves co-located .sops.yaml from dirname(bundle).
export DMF_ENV_BUNDLE_FILE="$BUNDLE_FILE"

echo "Test 1: Read initial secret..."
if ! INITIAL_PASS="$(bundle_field test-fakeenv bootstrap_admin.password)"; then
  echo "FAIL: Could not read initial password"
  exit 1
fi
if [ "$INITIAL_PASS" != "initial_password_123456" ]; then
  echo "FAIL: Initial password mismatch. Got: $INITIAL_PASS"
  exit 1
fi
echo "  PASS: Initial password read correctly"

echo "Test 2: Update secret via bundle_set..."
NEW_PASS="new_test_password_999999"
# bundle_set takes the value as the third argument
if ! bundle_set test-fakeenv bootstrap_admin.password "$NEW_PASS"; then
  echo "FAIL: bundle_set failed"
  exit 1
fi
echo "  PASS: bundle_set completed without error"

echo "Test 3: Verify round-trip (decrypt and read back)..."
ROUNDTRIP_PASS="$(bundle_field test-fakeenv bootstrap_admin.password)" || {
  echo "FAIL: Could not read updated password"
  exit 1
}
if [ "$ROUNDTRIP_PASS" != "$NEW_PASS" ]; then
  echo "FAIL: Round-trip password mismatch"
  echo "  Expected: $NEW_PASS"
  echo "  Got:      $ROUNDTRIP_PASS"
  exit 1
fi
echo "  PASS: Round-trip password matches"

echo "Test 4: Verify other fields unchanged..."
OTHER_FIELD="$(bundle_field test-fakeenv bootstrap_admin.username)" || {
  echo "FAIL: Could not read username"
  exit 1
}
if [ "$OTHER_FIELD" != "testadmin" ]; then
  echo "FAIL: Username corrupted during bundle_set"
  exit 1
fi
echo "  PASS: Other fields preserved"

echo "Test 5: Failure path — undecryptable bundle (error de-masking)..."
# Create a garbage bundle that can't be decrypted
GARBAGE_BUNDLE="${FAKE_BUNDLE_DIR}/garbage.sops.yaml"
echo "garbage data that's not valid sops" > "$GARBAGE_BUNDLE"
export DMF_ENV_BUNDLE_FILE="$GARBAGE_BUNDLE"

# Call bundle_set on the garbage bundle and check exit code
# Use a guard to prevent set -e from aborting
BUNDLE_SET_FAILED=0
bundle_set test-fakeenv some.field test_value >/dev/null 2>&1 || BUNDLE_SET_FAILED=1

if [ "$BUNDLE_SET_FAILED" -eq 0 ]; then
  echo "FAIL: bundle_set should have failed for undecryptable bundle"
  exit 1
fi

echo "  PASS: Failure path de-masked (error reported, non-zero exit)"

# Restore original bundle for cleanup
export DMF_ENV_BUNDLE_FILE="$BUNDLE_FILE"

echo ""
echo "PASS: All tests passed (including failure-path de-masking)"
exit 0
