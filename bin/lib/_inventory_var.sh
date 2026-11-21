# shellcheck shell=bash
# _inventory_var.sh — sourceable reader for one scalar of an env's inventory.
#
# Usage (after dmf_resolve_env_paths has set DMF_ENV_INVENTORY_DIR):
#     # shellcheck source=lib/_inventory_var.sh
#     . "$SCRIPT_DIR/lib/_inventory_var.sh"
#     provider="$(inventory_var dmf_provider || true)"
#
# Prints the value of the first `<key>:` line of group_vars/all/main.yml. The
# value is read as a YAML scalar on one line: a quoted value is the text between
# the quotes (a `#` inside quotes stays), and an unquoted value ends at a ` #`
# comment, with surrounding spaces removed. Anything after the closing quote is
# ignored. Returns 1 when the file does not exist.

inventory_var() {
  local key="$1"
  local f="${DMF_ENV_INVENTORY_DIR}/group_vars/all/main.yml"
  [ -f "$f" ] || return 1
  awk -v key="$key" '
    $0 ~ "^[[:space:]]*" key ":([[:space:]]|$)" {
      sub("^[[:space:]]*" key ":[[:space:]]*", "", $0)
      q = substr($0, 1, 1)
      if (q == "\"" || q == "\047") {
        rest = substr($0, 2)
        end = index(rest, q)
        if (end > 0) {
          print substr(rest, 1, end - 1)
          exit
        }
        # No closing quote: fall through and read it as a bare value.
      }
      if (substr($0, 1, 1) == "#") {
        $0 = ""
      }
      if (match($0, /[[:space:]]#/)) {
        $0 = substr($0, 1, RSTART - 1)
      }
      sub(/[[:space:]]+$/, "", $0)
      print
      exit
    }
  ' "$f"
}
