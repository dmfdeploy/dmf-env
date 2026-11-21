# shellcheck shell=bash
# _inventory_var.sh — sourceable reader for one scalar of an env's inventory.
#
# Usage (after dmf_resolve_env_paths has set DMF_ENV_INVENTORY_DIR):
#     # shellcheck source=lib/_inventory_var.sh
#     . "$SCRIPT_DIR/lib/_inventory_var.sh"
#     provider="$(inventory_var dmf_provider || true)"
#
# Prints the value of the first `<key>:` line of group_vars/all/main.yml, with
# one pair of outer quotes removed. Returns 1 when the file does not exist.

inventory_var() {
  local key="$1"
  local f="${DMF_ENV_INVENTORY_DIR}/group_vars/all/main.yml"
  [ -f "$f" ] || return 1
  awk -v key="$key" '
    $0 ~ "^[[:space:]]*" key ":[[:space:]]*" {
      sub("^[[:space:]]*" key ":[[:space:]]*", "", $0)
      gsub(/^"/, "", $0)
      gsub(/"$/, "", $0)
      gsub(/^'\''/, "", $0)
      gsub(/'\''$/, "", $0)
      print
      exit
    }
  ' "$f"
}
