#!/usr/bin/env bash
# validate-env.sh — pre-apply validation for cloud envs.
#
# Runs the validation chain that the init-wizard uses before applying:
#   - bootstrap-secrets.sh doctor (validate bundle/prereqs)
#   - tf-apply.sh init (per-env state init)
#   - tf-apply.sh plan (saved plan)
#
# Usage:
#   bin/validate-env.sh <env-id>
#
# On success, prints next steps. Aborts on any failure (set -euo pipefail).
# Cloud-only — sandbox envs skip the tofu steps (they have no terraform).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

cd "$REPO_DIR"

# shellcheck source=lib/_resolve_env_paths.sh
. "$SCRIPT_DIR/lib/_resolve_env_paths.sh"

print_usage() {
  echo "Usage: bin/validate-env.sh <env-id>" >&2
  echo "" >&2
  echo "Runs validation chain (doctor → init → plan -out)." >&2
  echo "Cloud-only; sandbox envs skip terraform steps." >&2
  echo "" >&2
  echo "Available environments:" >&2
  dmf_list_known_envs | sed 's/^/  /' >&2
  exit 1
}

if [ $# -eq 0 ]; then
  print_usage
fi

ENV_NAME="$1"

dmf_source_operator_config
dmf_resolve_env_paths "$ENV_NAME" || {
  echo "ERROR: Unable to resolve environment $ENV_NAME" >&2
  print_usage
}

# Determine if sandbox or cloud (sandbox has no manifest)
is_sandbox() {
  [ ! -f "${DMF_ENV_MANIFEST_FILE}" ]
}

echo "==> Validating environment: $ENV_NAME"
echo ""

# Step 1: doctor (all envs)
echo "==> Step 1: bootstrap-secrets.sh doctor"
if ! "$SCRIPT_DIR/bootstrap-secrets.sh" doctor "$ENV_NAME"; then
  echo "ERROR: bootstrap-secrets.sh doctor failed" >&2
  exit 1
fi
echo "✓ doctor passed"
echo ""

# Steps 2+3: init + plan (cloud only)
if is_sandbox; then
  echo "==> Sandbox environment (no terraform); skipping init + plan"
  echo ""
  echo "==> Validation complete."
  echo ""
  echo "Next steps:"
  echo "  bin/run-playbook.sh $ENV_NAME ../dmf-infra/k3s-lab-bootstrap/bootstrap-provision-pre-seed.yml"
  echo "  (then seed-bao → post-seed → configure → verify)"
else
  echo "==> Step 2: terraform init"
  if ! "$SCRIPT_DIR/tf-apply.sh" "$ENV_NAME" init; then
    echo "ERROR: terraform init failed" >&2
    exit 1
  fi
  echo "✓ init passed"
  echo ""

  echo "==> Step 3: terraform plan -out"
  if ! "$SCRIPT_DIR/tf-apply.sh" "$ENV_NAME" plan -out="${DMF_ENV_ROOT}/plan.bin"; then
    echo "ERROR: terraform plan failed" >&2
    exit 1
  fi
  echo "✓ plan passed"
  echo ""

  echo "==> Validation + plan complete."
  echo ""
  echo "Next steps:"
  echo "  bin/tf-apply.sh $ENV_NAME apply              # creates cloud resources"
  echo "  bin/run-playbook.sh $ENV_NAME ../dmf-infra/k3s-lab-bootstrap/bootstrap-provision-pre-seed.yml"
  echo "  (then seed-bao → post-seed → configure → verify)"
fi
