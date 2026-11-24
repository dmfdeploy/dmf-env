# shellcheck shell=bash
# _manifest_provider.sh — sourceable teardown gate for remove-env.sh and
# tf-destroy.sh. Both scripts decide from the env's manifest, never from the
# inventory.
#
# Usage:
#     # shellcheck source=lib/_manifest_provider.sh
#     . "$SCRIPT_DIR/lib/_manifest_provider.sh"
#     dmf_manifest_provider "$DMF_ENV_MANIFEST_FILE" || exit 1
#
# dmf_manifest_provider reads metadata.provider from the manifest and sets
# PROVIDER to sandbox or hetzner. It prints an error that says what to do by
# hand and returns 1 for a missing or unreadable manifest, and for a missing,
# null or unknown provider.
#
# It reads metadata.provider, not spec.provider: the wizard writes spec.provider
# twice (a plain name, then a mapping), and parsers differ on which one wins.
#
# dmf_hetzner_teardown_off prints the refusal for a hetzner env and returns 1.
# Automated Hetzner teardown is off until dmfdeploy/dmfdeploy#997.
#
# A caller runs no removal and no cloud call before this check passes.

dmf_manifest_provider() {
  local manifest="$1"
  if [ ! -f "$manifest" ]; then
    echo "ERROR: no manifest at ${manifest}; cannot tell sandbox from cloud. Nothing was removed." >&2
    echo "       Check the env by hand, then remove the env dir yourself." >&2
    return 1
  fi
  command -v yq >/dev/null 2>&1 || { echo "ERROR: missing dependency: yq" >&2; return 1; }
  PROVIDER="$(yq -r '.metadata.provider // ""' "$manifest")" || {
    echo "ERROR: cannot read ${manifest}. Nothing was removed." >&2
    return 1
  }
  case "$PROVIDER" in
    sandbox|hetzner) ;;
    *)
      echo "ERROR: unknown or missing metadata.provider ('${PROVIDER}') in ${manifest} (expected sandbox or hetzner). Nothing was removed." >&2
      echo "       Check the env by hand, then remove the env dir yourself." >&2
      return 1
      ;;
  esac
}

dmf_hetzner_teardown_off() {
  echo "ERROR: automated Hetzner teardown is off until dmfdeploy/dmfdeploy#997. Nothing was removed." >&2
  echo "       Delete the servers, network, load balancer and SSH key in the Hetzner console," >&2
  echo "       then remove the env dir by hand." >&2
  return 1
}
