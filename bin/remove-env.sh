#!/usr/bin/env bash
# remove-env.sh — idempotent teardown + removal of new-layout envs.
#
# Usage:
#   bin/remove-env.sh [--check] [--yes] <env-id>
#
# Modes:
#   --check    Dry-run: list what WOULD be removed, exit 0 without changes.
#   --yes      Skip confirmation prompt (useful for automation).
#
# Removes:
#   1. Cloud resources (via tf-destroy.sh, if cloud + state exists)
#   2. Hetzner SSH key (${env}-operator, if cloud)
#   3. Terraform state directory
#   4. Full environment directory (inventory/manifest/bundle/tfvars/ssh)
#
# All steps are idempotent — re-running is a safe no-op.
# New-layout only (targets only ~/.dmfdeploy/envs/<env>/, never the repo).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

cd "$REPO_DIR"

# shellcheck source=bin/lib/_resolve_env_paths.sh
. "$SCRIPT_DIR/lib/_resolve_env_paths.sh"

DRY_RUN=0
CONFIRM=1
ENV_NAME=""

print_usage() {
  echo "Usage: bin/remove-env.sh [--check] [--yes] <env-id>" >&2
  echo "" >&2
  echo "Removes cloud resources, state, and environment directory (idempotent)." >&2
  echo "" >&2
  echo "Options:" >&2
  echo "  --check    Dry-run: list what WOULD be removed, exit 0." >&2
  echo "  --yes      Skip confirmation prompt." >&2
  echo "" >&2
  echo "Available environments:" >&2
  dmf_list_known_envs | sed 's/^/  /' >&2
  exit 1
}

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --check)
      DRY_RUN=1
      shift
      ;;
    --yes)
      CONFIRM=0
      shift
      ;;
    -*)
      echo "ERROR: unknown flag: $1" >&2
      print_usage
      ;;
    *)
      if [ -n "$ENV_NAME" ]; then
        echo "ERROR: unexpected extra argument: $1" >&2
        print_usage
      fi
      ENV_NAME="$1"
      shift
      ;;
  esac
done

if [ -z "$ENV_NAME" ]; then
  print_usage
fi

dmf_source_operator_config
if ! dmf_resolve_env_paths "$ENV_NAME"; then
  # A failed/aborted wizard run can leave a partial, unrecognised env dir
  # (e.g. only ssh/ with no bundle or inventory). Fall back to the new-layout
  # path so removal can still clean it up (local-only — treated as no-cloud).
  fallback="${_DMF_DATA_ROOT}/envs/${ENV_NAME}"
  if [ -d "$fallback" ]; then
    DMF_ENV_ROOT="$fallback"
    DMF_ENV_TF_STATE_DIR="${fallback}/terraform-state"
    DMF_ENV_MANIFEST_FILE="${fallback}/manifest.yaml"
    DMF_ENV_INVENTORY_DIR="${fallback}/inventory"
    echo "==> NOTE: '$ENV_NAME' is a partial/unrecognised env dir — cleaning local artifacts only." >&2
  else
    echo "ERROR: Unable to resolve environment $ENV_NAME" >&2
    print_usage
  fi
fi

# Only operate on new-layout (operator-local) envs
if [ -z "${DMF_ENV_ROOT:-}" ] || [ ! -d "${DMF_ENV_ROOT}" ]; then
  echo "ERROR: environment $ENV_NAME not found at ${_DMF_DATA_ROOT}/envs/$ENV_NAME/" >&2
  exit 1
fi

# Determine if sandbox or cloud
is_sandbox() {
  [ ! -f "${DMF_ENV_MANIFEST_FILE}" ]
}

# ─────────────────────────────────────────────────────────────
# Dry-run mode: list what would be removed
# ─────────────────────────────────────────────────────────────

if [ "$DRY_RUN" -eq 1 ]; then
  echo "==> DRY-RUN: Would remove the following:"
  echo ""
  echo "  Environment root: ${DMF_ENV_ROOT}"
  echo ""

  if [ -d "${DMF_ENV_TF_STATE_DIR}" ]; then
    echo "  Terraform state: ${DMF_ENV_TF_STATE_DIR}"
  else
    echo "  Terraform state: (not present)"
  fi
  echo ""

  if ! is_sandbox; then
    hcloud_context="$(grep -E '^\s*hcloud_context:' "${DMF_ENV_INVENTORY_DIR}/group_vars/all/main.yml" 2>/dev/null | awk -F': ' '{print $2}' | tr -d ' "'\'''  || true)"
    if [ -n "$hcloud_context" ]; then
      echo "  Hetzner SSH key: ${ENV_NAME}-operator (context: $hcloud_context)"
    else
      echo "  Hetzner SSH key: ${ENV_NAME}-operator (default context)"
    fi
  fi
  echo ""

  echo "==> No changes made. To proceed, run without --check."
  exit 0
fi

# ─────────────────────────────────────────────────────────────
# Confirmation (unless --yes or non-TTY + --yes required)
# ─────────────────────────────────────────────────────────────

if [ "$CONFIRM" -eq 1 ]; then
  if [ ! -t 0 ]; then
    echo "ERROR: stdin is not a TTY and --yes was not provided." >&2
    echo "       Use --yes for non-interactive removal, or --check to preview." >&2
    exit 1
  fi

  echo "==> About to remove environment: $ENV_NAME"
  echo "    Root: ${DMF_ENV_ROOT}"
  echo ""
  echo "    This will:"
  echo "      - Destroy cloud resources (if any)"
  echo "      - Delete Hetzner SSH key (${ENV_NAME}-operator, if cloud)"
  echo "      - Remove terraform state directory"
  echo "      - Remove the entire environment directory"
  echo ""
  read -p "    Proceed? (type 'yes' to confirm): " -r confirm_text || confirm_text=""

  if [ "$confirm_text" != "yes" ]; then
    echo "Aborted."
    exit 0
  fi
  echo ""
fi

echo "==> Removing environment: $ENV_NAME"
echo ""

# ─────────────────────────────────────────────────────────────
# Step 1: Destroy cloud resources (tf-destroy.sh)
# ─────────────────────────────────────────────────────────────

if ! is_sandbox; then
  if [ -d "${DMF_ENV_TF_STATE_DIR}" ]; then
    echo "==> Step 1: Destroying cloud resources..."
    if "$SCRIPT_DIR/tf-destroy.sh" "$ENV_NAME" 2>/dev/null || true; then
      echo "✓ Cloud resources destroyed"
    else
      echo "⚠ tf-destroy.sh had issues (continuing; state will be removed)"
    fi
  else
    echo "==> Step 1: No terraform state found (skipping destroy)"
  fi
  echo ""
else
  echo "==> Sandbox environment (no cloud resources)"
  echo ""
fi

# ─────────────────────────────────────────────────────────────
# Step 2: Delete Hetzner SSH key (if cloud)
# ─────────────────────────────────────────────────────────────

if ! is_sandbox; then
  echo "==> Step 2: Deleting Hetzner SSH key..."
  hcloud_context="$(grep -E '^\s*hcloud_context:' "${DMF_ENV_INVENTORY_DIR}/group_vars/all/main.yml" 2>/dev/null | awk -F': ' '{print $2}' | tr -d ' "'\''' || true)"

  if [ -z "$hcloud_context" ]; then
    hcloud_cmd=(hcloud)
  else
    hcloud_cmd=(hcloud --context "$hcloud_context")
  fi

  if "${hcloud_cmd[@]}" ssh-key delete "${ENV_NAME}-operator" 2>/dev/null || true; then
    echo "✓ SSH key deleted"
  else
    echo "✓ SSH key not found (or already deleted)"
  fi
  echo ""
fi

# ─────────────────────────────────────────────────────────────
# Step 3: Remove state directory
# ─────────────────────────────────────────────────────────────

echo "==> Step 3: Removing terraform state..."
if [ -d "${DMF_ENV_TF_STATE_DIR}" ]; then
  # Sanity check: path must be non-empty and under the env root
  case "$DMF_ENV_TF_STATE_DIR" in
    "${_DMF_DATA_ROOT}/envs/"?*/terraform-state) ;;
    *) echo "ERROR: refusing rm -rf of unexpected path: '$DMF_ENV_TF_STATE_DIR'" >&2; exit 1 ;;
  esac
  rm -rf "${DMF_ENV_TF_STATE_DIR}"
  echo "✓ State removed"
else
  echo "✓ State not present"
fi
echo ""

# ─────────────────────────────────────────────────────────────
# Step 4: Remove environment root directory
# ─────────────────────────────────────────────────────────────

echo "==> Step 4: Removing environment directory..."
if [ -d "${DMF_ENV_ROOT}" ]; then
  # Sanity check: path must be non-empty and under ~/.dmfdeploy/envs/
  case "$DMF_ENV_ROOT" in
    "${_DMF_DATA_ROOT}/envs/"?*) ;;
    *) echo "ERROR: refusing rm -rf of unexpected path: '$DMF_ENV_ROOT'" >&2; exit 1 ;;
  esac
  rm -rf "${DMF_ENV_ROOT}"
  echo "✓ Environment removed: ${DMF_ENV_ROOT}"
else
  echo "✓ Environment not present"
fi
echo ""

echo "==> Removal complete."
