# _resolve_env_paths.sh — sourceable env path resolver for dmf-env bin/ scripts.
#
# Resolves paths for operator-local envs under `~/.dmfdeploy/envs/<env_id>/`.
# DMF_ENV_LAYOUT is always "new" (the legacy repo-rooted layout has been removed).
#
# Usage (in a caller script):
#     SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#     REPO_DIR="$(dirname "$SCRIPT_DIR")"
#     # shellcheck source=lib/_resolve_env_paths.sh
#     . "$SCRIPT_DIR/lib/_resolve_env_paths.sh"
#
#     dmf_source_operator_config              # idempotent
#     dmf_resolve_env_paths "$ENV_NAME"       # populates DMF_ENV_* globals
#
# After dmf_resolve_env_paths succeeds, the caller may read:
#
#     DMF_ENV_LAYOUT          always "new" → ~/.dmfdeploy/envs/<env>/
#     DMF_ENV_ROOT            ~/.dmfdeploy/envs/<env>
#     DMF_ENV_INVENTORY_DIR   full path to inventory tree
#     DMF_ENV_BUNDLE_FILE     full path to bundle.sops.yaml
#     DMF_ENV_MANIFEST_FILE   full path to manifest.yaml
#     DMF_ENV_SOPS_CONFIG     per-env .sops.yaml
#     DMF_ENV_OPENBAO_KEYS    break-glass JSON path
#     DMF_ENV_TFVARS_DIR      operator-local tfvars dir; callers form <provider>.tfvars
#     DMF_ENV_TF_STATE_DIR    per-env tofu local-backend state dir
#     DMF_ENV_SSH_DIR         per-env SSH artefact dir
#     DMF_ENV_SSH_PUBKEY      per-env public key path (privkey from sops bundle)
#
# The resolver does NOT verify the contents (bundle decryptable, inventory
# parseable, etc.) — callers do that. It only locates the on-disk artifacts.
#
# The optional [repo_dir] arg to dmf_resolve_env_paths is accepted-but-unused
# (vestigial, to avoid touching every caller). Do NOT delete callers' REPO_DIR
# setup.

# Guard against multiple sourcing in the same shell.
if [ "${DMF_RESOLVE_ENV_PATHS_LOADED:-}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
DMF_RESOLVE_ENV_PATHS_LOADED=1

# Where the new layout lives. Single $HOME-rooted dot-dir, deliberately not
# XDG/Library/AppData — that mess only matters for apps that need a published
# config-spec home. Operator-private state has no such audience.
#
# Honors DMF_DATA_ROOT (default ~/.dmfdeploy) so a wrapper can redirect ALL env
# state to an alternate root — this MUST match init-wizard.sh's
# `DMF_DATA_ROOT="${DMF_DATA_ROOT:-${HOME}/.dmfdeploy}"`, otherwise the wizard
# renders into the alternate root but bin/ scripts look in ~/.dmfdeploy and
# can't find the env (the dmf-init thin-container tmpfs model depends on this).
_DMF_DATA_ROOT="${DMF_DATA_ROOT:-${HOME}/.dmfdeploy}"

# dmf_source_operator_config — idempotently source the operator's env config.
# Preferred: ~/.dmfdeploy/env; one-time fallback: ~/.config/dmf/env (the
# pre-consolidation location). Both files are optional. If both exist, the
# new location wins; the legacy file is left alone (operator can migrate at
# their leisure).
dmf_source_operator_config() {
    [ "${_DMF_OPERATOR_CONFIG_SOURCED:-}" = "1" ] && return 0
    _DMF_OPERATOR_CONFIG_SOURCED=1
    local f
    for f in "${_DMF_DATA_ROOT}/env" "${HOME}/.config/dmf/env"; do
        if [ -r "$f" ]; then
            # shellcheck disable=SC1090
            . "$f"
            return 0
        fi
    done
    return 0
}

# _dmf_env_paths_set_new <env_id> — populate DMF_ENV_* for the new layout.
_dmf_env_paths_set_new() {
    local env_id="$1"
    DMF_ENV_LAYOUT="new"
    DMF_ENV_ROOT="${_DMF_DATA_ROOT}/envs/${env_id}"
    DMF_ENV_INVENTORY_DIR="${DMF_ENV_ROOT}/inventory"
    DMF_ENV_BUNDLE_FILE="${DMF_ENV_ROOT}/bundle.sops.yaml"
    DMF_ENV_MANIFEST_FILE="${DMF_ENV_ROOT}/manifest.yaml"
    DMF_ENV_SOPS_CONFIG="${DMF_ENV_ROOT}/.sops.yaml"
    DMF_ENV_OPENBAO_KEYS="${DMF_ENV_ROOT}/openbao-keys.json"
    DMF_ENV_TFVARS_DIR="${DMF_ENV_ROOT}"
    DMF_ENV_TF_STATE_DIR="${DMF_ENV_ROOT}/terraform-state"
    DMF_ENV_SSH_DIR="${DMF_ENV_ROOT}/ssh"
    DMF_ENV_SSH_PUBKEY="${DMF_ENV_SSH_DIR}/operator.pub"
    export DMF_ENV_LAYOUT DMF_ENV_ROOT DMF_ENV_INVENTORY_DIR \
        DMF_ENV_BUNDLE_FILE DMF_ENV_MANIFEST_FILE DMF_ENV_SOPS_CONFIG \
        DMF_ENV_OPENBAO_KEYS DMF_ENV_TFVARS_DIR DMF_ENV_TF_STATE_DIR \
        DMF_ENV_SSH_DIR DMF_ENV_SSH_PUBKEY
}

# dmf_resolve_env_paths <env_id> [repo_dir]
#
# Populates DMF_ENV_* globals for the new layout.
# Returns 0 if the env exists on disk, 1 if not found (the caller decides
# whether to error or proceed with a fresh init).
#
# repo_dir is accepted-but-unused (vestigial — avoids touching every caller).
dmf_resolve_env_paths() {
    local env_id="$1"
    if [ -z "$env_id" ]; then
        echo "dmf_resolve_env_paths: env_id is required" >&2
        return 2
    fi

    local new_root="${_DMF_DATA_ROOT}/envs/${env_id}"
    if [ -d "${new_root}/inventory" ] || [ -f "${new_root}/bundle.sops.yaml" ]; then
        _dmf_env_paths_set_new "$env_id"
        return 0
    fi

    # Not present. Set placeholders so callers that want to surface a "not
    # found" error have something to print; return non-zero so they can decide
    # whether to proceed (e.g. wizard-driven init).
    _dmf_env_paths_set_new "$env_id"
    return 1
}

# dmf_list_known_envs — print one env_id per line, deduplicated, from the
# new layout only.
dmf_list_known_envs() {
    {
        if [ -d "${_DMF_DATA_ROOT}/envs" ]; then
            local d
            for d in "${_DMF_DATA_ROOT}/envs"/*/; do
                [ -d "$d" ] || continue
                basename "$d"
            done
        fi
    } | LC_ALL=C sort -u
}

# dmf_env_exists <env_id> — quick boolean, no var pollution.
dmf_env_exists() {
    local env_id="$1"
    [ -n "$env_id" ] || return 1
    [ -d "${_DMF_DATA_ROOT}/envs/${env_id}/inventory" ] && return 0
    [ -f "${_DMF_DATA_ROOT}/envs/${env_id}/bundle.sops.yaml" ] && return 0
    return 1
}
