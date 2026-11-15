#!/usr/bin/env bash
# check.sh — run the dmf-env checks that CI runs.
#
# Usage: scripts/check.sh [STEP...]
#   Steps: shellcheck, review-comments, tests, tofu
#   With no step, every step runs. CI runs each step as its own job.
#
# The tests step stops at the first failing script. Before any step runs, the
# script checks the tools that the chosen steps need, because the test scripts
# exit 0 with a SKIP line when a tool is missing.
#
# CONTRIBUTING.md lists the prerequisites and which checks run only in CI.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

ALL_STEPS="shellcheck review-comments tests tofu"

TMP_WORK=""
trap 'rm -rf "${TMP_WORK}"' EXIT

die() {
  echo "check.sh: $*" >&2
  exit 1
}

need_tool() {
  command -v "$1" >/dev/null 2>&1 || die "missing tool: $1 ($2)"
}

# The tests call `yq -o=json`, which only the Go yq v4 accepts.
need_go_yq() {
  need_tool yq "install the Go yq v4 from https://github.com/mikefarah/yq"
  case "$(yq --version 2>&1)" in
    *mikefarah/yq*) ;;
    *) die "yq is not the Go yq v4 (yq --version shows: $(yq --version 2>&1 | head -n 1))" ;;
  esac
}

preflight() {
  local step
  for step in "$@"; do
    case "$step" in
      shellcheck)
        need_tool shellcheck "used by the shellcheck step"
        ;;
      review-comments)
        need_tool python3 "used by the review-comments step"
        ;;
      tests)
        local tool
        for tool in bash jq sops age age-keygen python3 ssh ssh-keygen; do
          need_tool "$tool" "used by the tests step"
        done
        need_go_yq
        ;;
      tofu)
        need_tool tofu "used by the tofu step"
        ;;
      *)
        die "unknown step: $step (steps: ${ALL_STEPS})"
        ;;
    esac
  done
}

run_shellcheck() {
  # -S error gates on real errors only; the tree has older info and style notes.
  shellcheck -S error bin/*.sh scripts/*.sh
}

run_review_comments() {
  bin/check-review-comments.sh
  bin/check-review-comments.sh --self-test
}

run_tests() {
  local t
  for t in tests/*.sh; do
    echo "=== ${t} ==="
    bash "$t"
  done
}

run_tofu() {
  local dir work
  tofu fmt -check -recursive terraform/hetzner terraform/modules/hetzner/cluster
  # tofu init edits the provider lock files for your platform. Validate a copy
  # so the working tree stays clean. The copy holds the tracked files that
  # still exist plus untracked files that .gitignore doesn't exclude, so the
  # ignored provider caches and state files stay out. An untracked file that
  # git doesn't ignore, such as a new .tf or .tfvars file, is copied.
  work="$(mktemp -d)"
  TMP_WORK="$work"
  git ls-files -z --cached --others --exclude-standard -- terraform |
    while IFS= read -r -d '' f; do
      if [ -e "$f" ]; then printf '%s\0' "$f"; fi
    done |
    tar --null -T - -cf - | tar -xf - -C "$work"
  for dir in terraform/hetzner terraform/modules/hetzner/cluster; do
    echo "=== tofu validate: ${dir} ==="
    (cd "${work}/${dir}" && tofu init -backend=false && tofu validate)
  done
}

if [ "$#" -eq 0 ]; then
  # shellcheck disable=SC2086
  set -- $ALL_STEPS
fi

preflight "$@"

for step in "$@"; do
  echo "##### ${step}"
  case "$step" in
    shellcheck) run_shellcheck ;;
    review-comments) run_review_comments ;;
    tests) run_tests ;;
    tofu) run_tofu ;;
  esac
done

echo "check.sh: all steps passed: $*"
