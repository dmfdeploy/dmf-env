# shellcheck shell=bash
# _controller_core.sh — sourceable check that the controller runs the ansible-core
# that dmf-infra pins.
#
# Usage (before any secret fetch or playbook run):
#     # shellcheck source=lib/_controller_core.sh
#     . "$SCRIPT_DIR/lib/_controller_core.sh"
#     dmf_check_controller_core "${REPO_DIR}/../dmf-infra" || exit 1
#
# dmf-infra pins the version in k3s-lab-bootstrap/requirements-ansible-core.txt,
# one line: ansible-core==X.Y.Z. The function compares it with the
# `ansible-playbook` found on PATH, which is the one the caller runs next.
#   - A different minor (X.Y) fails: it names both versions and the pin file.
#   - A different patch passes, and the output says so.
#   - A missing or malformed pin file fails and names the file.
# On success it prints one line to stderr with both versions, Python, and the
# dmf-infra commit, so every run log records the controller side.

dmf_check_controller_core() {
  local infra_dir="$1"
  local pin_file="${infra_dir}/k3s-lab-bootstrap/requirements-ansible-core.txt"

  if [ ! -f "$pin_file" ]; then
    echo "ERROR: ${pin_file} not found. Advance the dmf-infra checkout; older checkouts have no ansible-core pin and are not supported." >&2
    return 1
  fi
  # Same rule as dmf-infra's ee/scripts/build.sh --check-pin: exactly one
  # newline-terminated line, ansible-core==X.Y.Z.
  local line pin=""
  if [ "$(wc -l <"$pin_file" | tr -d ' ')" = "1" ]; then
    line="$(cat "$pin_file")"
    [[ "$line" =~ ^ansible-core==([0-9]+\.[0-9]+\.[0-9]+)$ ]] && pin="${BASH_REMATCH[1]}"
  fi
  if [ -z "$pin" ]; then
    echo "ERROR: ${pin_file} must contain exactly one line, ansible-core==X.Y.Z." >&2
    return 1
  fi

  local out core py
  if ! out="$(ansible-playbook --version 2>&1)"; then
    echo "ERROR: could not run ansible-playbook --version (is ansible-core installed on PATH?)." >&2
    return 1
  fi
  core="$(printf '%s\n' "$out" | sed -n '1s/^[^[]*\[core \([^]]*\)\].*/\1/p')"
  py="$(printf '%s\n' "$out" | sed -n 's/^ *python version = \([0-9][0-9.]*\).*/\1/p' | head -n 1)"
  if ! [[ "$core" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: controller ansible-core version '${core:-unreadable}' is not a plain X.Y.Z release; prerelease and development builds are not supported (first line: $(printf '%s\n' "$out" | head -n 1))." >&2
    return 1
  fi

  if [ "${core%.*}" != "${pin%.*}" ]; then
    echo "ERROR: controller ansible-core ${core} does not match pin ${pin} (${pin_file})." >&2
    return 1
  fi

  local sha
  sha="$(git -C "$infra_dir" rev-parse --short HEAD 2>/dev/null)" || sha="sha unknown"
  [ -n "$sha" ] || sha="sha unknown"
  echo "controller: ansible-core ${core}, Python ${py:-unknown}; pin ${pin} (${pin_file}, dmf-infra ${sha})" >&2
  if [ "$core" != "$pin" ]; then
    echo "controller: patch version differs from the pin (${core} vs ${pin}); the minor matches, so the run continues." >&2
  fi
}
