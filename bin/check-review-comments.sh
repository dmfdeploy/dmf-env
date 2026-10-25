#!/usr/bin/env bash
# check-review-comments.sh — fail when a comment records review history.
#
# A comment should say why the code is the way it is. Which review, round,
# reviewer, agent or work order prompted a change belongs in the PR and the
# issue, not in the file: it goes stale, means nothing to a new reader, and
# hides the actual reason. See dmfdeploy/dmfdeploy#768.
#
# The check runs one case-insensitive extended regex over every tracked text
# file: a comment leader (#, //, --, *, {#) followed later on the same line by
# a review-history marker. Hits listed in the allowlist pass; any other hit
# fails. An allowlist entry that no longer matches any hit also fails, so the
# list shrinks as the lines it covers go away.
#
# Allowlist format (.review-comment-allow at the repo root), one entry per
# line, blank lines and lines starting with # ignored:
#
#   <path>:<fixed substring of the line>  # <reason>
#
# The reason is required. The substring is matched literally, not as a regex.
#
# Usage: bin/check-review-comments.sh [--tree <tree-ish>]
#   --tree   check a commit or branch instead of the working tree, for example
#            --tree origin/main. The allowlist is read from the same tree.
#
# Dependencies: bash and git. Runs the same way locally and in CI.
set -euo pipefail

# No \b: BSD regex (macOS git grep -E) does not support it, so a pattern
# using it silently matches less on a laptop than on Linux CI.
PATTERN='(#|//|--|\*).*(codex|lkirc|claude[0-9]|(claude|qwen|gemini)[-a-z0-9]*'"'"'s|round[- ]?[0-9]|[0-9](st|nd|rd|th) round|fix[- ]round|work[- ]order|gate finding|review finding|adversarial (gate|round)|PR ?#[0-9]+\))'
ALLOW_FILE=.review-comment-allow

tree=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tree) tree="${2:?--tree needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

cd "$(git rev-parse --show-toplevel)"

# This script and its allowlist quote the markers by design.
exclude=(":(exclude)bin/check-review-comments.sh" ":(exclude)$ALLOW_FILE")

if [ -n "$tree" ]; then
  hits=$(git grep -nIiE "$PATTERN" "$tree" -- . "${exclude[@]}" | sed "s|^$tree:||" || true)
  allow=$(git show "$tree:$ALLOW_FILE" 2>/dev/null || true)
else
  hits=$(git grep -nIiE "$PATTERN" -- . "${exclude[@]}" || true)
  allow=$(cat "$ALLOW_FILE" 2>/dev/null || true)
fi

# Parse the allowlist into parallel arrays (bash 3.2 has no associative ones).
allow_path=(); allow_text=(); allow_used=()
bad_entries=0
while IFS= read -r entry; do
  case "$entry" in ''|'#'*) continue ;; esac
  body=${entry%%  # *}
  if [ "$body" = "$entry" ] || [ "${body#*:}" = "$body" ]; then
    echo "::error file=$ALLOW_FILE::malformed entry (want '<path>:<substring>  # <reason>'): $entry"
    bad_entries=$((bad_entries + 1))
    continue
  fi
  allow_path+=("${body%%:*}")
  allow_text+=("${body#*:}")
  allow_used+=(0)
done <<< "$allow"

failures=0
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  path=${hit%%:*}
  rest=${hit#*:}
  line=${rest%%:*}
  content=${rest#*:}
  allowed=0
  for ((i = 0; i < ${#allow_path[@]}; i++)); do
    if [ "${allow_path[$i]}" = "$path" ] && [[ "$content" == *"${allow_text[$i]}"* ]]; then
      allowed=1; allow_used[i]=1
    fi
  done
  if [ "$allowed" -eq 0 ]; then
    echo "::error file=$path,line=$line::comment records review history; keep the reason, drop the provenance: $content"
    failures=$((failures + 1))
  fi
done <<< "$hits"

stale=0
for ((i = 0; i < ${#allow_path[@]}; i++)); do
  if [ "${allow_used[$i]}" -eq 0 ]; then
    echo "::error file=$ALLOW_FILE::entry matches nothing, remove it: ${allow_path[$i]}:${allow_text[$i]}"
    stale=$((stale + 1))
  fi
done

total=$((failures + stale + bad_entries))
if [ "$total" -gt 0 ]; then
  echo "review-comment check: $failures unallowed hit(s), $stale stale and $bad_entries malformed allowlist entr(ies)." >&2
  exit 1
fi
echo "review-comment check: OK (${#allow_path[@]} allowlisted)."
