# shellcheck shell=bash
# _env_id.sh — the one definition of a valid env id (and sandbox label).
#
# An env id is a lowercase DNS label: lowercase letters, digits and hyphens,
# starting and ending with a letter or digit, at most 63 characters. The wizard's
# generated ids (`xxxx-xxxx`) and its sandbox labels both match.
#
# Usage:
#     # shellcheck source=lib/_env_id.sh
#     . "$SCRIPT_DIR/lib/_env_id.sh"
#     dmf_is_env_id "$id" || { echo "ERROR: invalid env id: $id" >&2; exit 1; }
#
# Scripts that build a path from an env id call this before they resolve or
# remove anything, so an id cannot contain `/` or `..`.

dmf_is_env_id() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] && [ "${#1}" -le 63 ]
}
