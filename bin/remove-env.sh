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
# Sandbox envs only. It reads metadata.provider from the env's manifest and refuses
# any other env before removing anything or calling a cloud API. Hetzner teardown
# is manual until dmfdeploy/dmfdeploy#997: delete the servers, network, load
# balancer and SSH key in the provider console, then remove the env dir.
#
# Removes the full environment directory (inventory/manifest/bundle/tfvars/ssh).
# The wizard never creates <env>/terraform-state for a sandbox, so anything at that path
# (dir, file, symlink or broken symlink) means the manifest may be wrong: the
# script refuses before removing anything.
#
# All steps are idempotent — re-running is a safe no-op.
# New-layout only (targets only ~/.dmfdeploy/envs/<env>/, never the repo).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

cd "$REPO_DIR"

# shellcheck source=bin/lib/_resolve_env_paths.sh
. "$SCRIPT_DIR/lib/_resolve_env_paths.sh"
# shellcheck source=bin/lib/_manifest_provider.sh
. "$SCRIPT_DIR/lib/_manifest_provider.sh"
# shellcheck source=bin/lib/_env_id.sh
. "$SCRIPT_DIR/lib/_env_id.sh"

DRY_RUN=0
CONFIRM=1
ENV_NAME=""

print_usage() {
  echo "Usage: bin/remove-env.sh [--check] [--yes] <env-id>" >&2
  echo "" >&2
  echo "Removes a sandbox env's directory (idempotent)." >&2
  echo "Refuses hetzner and unknown envs; tear those down by hand (#997)." >&2
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

# Reject a bad id before anything resolves, prompts or is removed: the id
# becomes a path under envs/.
dmf_is_env_id "$ENV_NAME" || {
  echo "ERROR: invalid env id '${ENV_NAME}' (lowercase letters, digits, hyphens; start and end alphanumeric; 63 chars or fewer). Nothing was removed." >&2
  exit 1
}

dmf_source_operator_config
if ! dmf_resolve_env_paths "$ENV_NAME"; then
  # A failed/aborted wizard run can leave a partial, unrecognised env dir
  # (e.g. only ssh/ with no bundle or inventory). Fall back to the new-layout
  # path. The provider check below still needs a manifest before it removes
  # anything.
  fallback="${_DMF_DATA_ROOT}/envs/${ENV_NAME}"
  if [ -d "$fallback" ]; then
    DMF_ENV_ROOT="$fallback"
    DMF_ENV_TF_STATE_DIR="${fallback}/terraform-state"
    DMF_ENV_MANIFEST_FILE="${fallback}/manifest.yaml"
    DMF_ENV_INVENTORY_DIR="${fallback}/inventory"
    echo "==> NOTE: '$ENV_NAME' is a partial/unrecognised env dir — checking its manifest." >&2
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

# The env dir must be exactly envs/<id> once symlinks resolve; a symlinked env
# dir or data root that points elsewhere is refused.
real_envs="$(cd -P "${_DMF_DATA_ROOT}/envs" 2>/dev/null && pwd -P)" || real_envs=""
real_root="$(cd -P "${DMF_ENV_ROOT}" 2>/dev/null && pwd -P)" || real_root=""
if [ -z "$real_envs" ] || [ "$real_root" != "${real_envs}/${ENV_NAME}" ]; then
  echo "ERROR: refusing rm -rf of unexpected path: '${DMF_ENV_ROOT}' (resolves to '${real_root}', expected '${real_envs}/${ENV_NAME}'). Nothing was removed." >&2
  exit 1
fi

# The manifest's metadata.provider gates teardown. Stop before removing anything
# unless the env is a sandbox; cloud envs are torn down by hand (#997).
dmf_manifest_provider "${DMF_ENV_MANIFEST_FILE}" || exit 1
[ "$PROVIDER" = sandbox ] || { dmf_hetzner_teardown_off; exit 1; }

# The wizard never creates terraform state for a sandbox. Anything at the standard path (a
# dir, a file, a symlink or a broken symlink) means the manifest may be wrong,
# and that state could be the only record of cloud resources.
tf_state="${DMF_ENV_ROOT}/terraform-state"
if [ -e "$tf_state" ] || [ -L "$tf_state" ]; then
  echo "ERROR: the manifest says sandbox, but ${tf_state} exists. The wizard never creates terraform-state for a sandbox. Nothing was removed." >&2
  echo "       Look at the env by hand. If it really is a disposable sandbox, remove the env dir yourself." >&2
  exit 1
fi

# ─────────────────────────────────────────────────────────────
# Dry-run mode: list what would be removed
# ─────────────────────────────────────────────────────────────

if [ "$DRY_RUN" -eq 1 ]; then
  echo "==> DRY-RUN: Would remove the following:"
  echo ""
  echo "  Environment root: ${DMF_ENV_ROOT}"
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
  echo "    This will remove the entire environment directory."
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

echo "==> Sandbox environment (no cloud resources)"
echo ""

# ─────────────────────────────────────────────────────────────
# Remove environment root directory
# ─────────────────────────────────────────────────────────────

echo "==> Removing environment directory..."
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
