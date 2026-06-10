#!/usr/bin/env bash
# tf-render-inventory.sh — re-render the env's hosts.ini from current
# tofu state without touching upstream Hetzner / Cloudflare resources.
#
# Usage:
#   bin/tf-render-inventory.sh <ENV_NAME>
#
# ENV_NAME is required (current id in umbrella STATUS.md).
#
# Implementation: thin wrapper over `tofu apply -target=local_file.hosts_ini`
# with -refresh=false so no provider API calls are made. The hosts.ini file
# is regenerated from existing state — useful after a manual edit or to
# verify the template against committed inventory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck source=lib/_resolve_env_paths.sh
. "$SCRIPT_DIR/lib/_resolve_env_paths.sh"

if [ $# -gt 0 ]; then
  ENV_NAME="$1"
  shift
else
  echo "ERROR: <ENV_NAME> is required as the first positional arg." >&2
  echo "(current live env id is in the umbrella's STATUS.md)" >&2
  exit 1
fi

cd "$REPO_DIR"
dmf_source_operator_config
dmf_resolve_env_paths "$ENV_NAME" || {
  echo "ERROR: Unable to resolve environment $ENV_NAME" >&2
  exit 1
}

echo "==> Re-rendering hosts.ini from tofu state ($ENV_NAME)" >&2

exec "$SCRIPT_DIR/tf-apply.sh" "$ENV_NAME" \
  apply \
  -target=local_file.hosts_ini \
  -refresh=false \
  -auto-approve \
  "$@"
