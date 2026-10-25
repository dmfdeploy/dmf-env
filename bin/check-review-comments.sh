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
# Python docstrings are checked too: a docstring has no comment leader, so its
# lines are matched on the markers alone. They are found with Python's ast
# module, which needs python3 whenever a tracked *.py file is in scope; the
# check fails rather than skip them. A docstring line is reported and
# allowlisted as <path>:<line> like any other. Ordinary string literals (log
# messages, error text) are data, not commentary, and are not scanned.
#
# Allowlist format (.review-comment-allow at the repo root), one entry per
# line, blank lines and lines starting with # ignored:
#
#   <path>:<fixed substring of the line>  # <reason>
#
# The path, substring and reason are all required and must not be blank. The
# path must equal the file's path exactly and the substring is matched
# literally, not as a glob or regex, so neither can widen an entry to cover
# other files or lines. A substring under 3 characters is refused as too broad.
#
# Usage: bin/check-review-comments.sh [--tree <tree-ish>]
#        bin/check-review-comments.sh --self-test
#   --tree   check a commit or branch instead of the working tree, for example
#            --tree origin/main. The allowlist is read from the same tree.
#   --self-test   run the check against a planted comment in a temporary
#            repo, with allowlists that must fail and one that must pass.
#
# Dependencies: bash and git. Runs the same way locally and in CI.
set -euo pipefail

# No \b: BSD regex (macOS git grep -E) does not support it, so a pattern
# using it silently matches less on a laptop than on Linux CI.
# MARKERS names review history. A comment hit is a comment leader followed by
# a marker; a docstring has no leader, so its lines are matched on MARKERS alone.
MARKERS='(codex|lkirc|claude[0-9]|(claude|qwen|gemini)[-a-z0-9]*'"'"'s|round[- ]?[0-9]|[0-9](st|nd|rd|th) round|fix[- ]round|work[- ]order|gate finding|review finding|adversarial (gate|round)|PR ?#[0-9]+\))'
PATTERN='(#|//|--|\*).*'"$MARKERS"
ALLOW_FILE=.review-comment-allow
# A shorter substring matches too many lines to say what it allows.
MIN_SUBSTRING=3

tmp=""
trap '[ -z "$tmp" ] || rm -rf "$tmp"' EXIT
self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# blank <string>: true when the string is empty or only whitespace.
blank() { [ -z "${1//[[:space:]]/}" ]; }

# self_test: plant one review-history comment in a throwaway repo and run the
# check against allowlists that must fail or pass. A guard that cannot fail is
# worth nothing, so this proves the parser rejects entries that would
# otherwise allow every hit in a file.
self_test() {
  # A hook or wrapper may export these; they would point git at the caller.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
  local failed=0
  tmp=$(mktemp -d)
  git -C "$tmp" init -q
  mkdir "$tmp/src"
  printf 'x = 1  # fixed in round 2 by codex\n' > "$tmp/src/app.py"
  git -C "$tmp" add src/app.py

  # run_case <name> <want: pass|fail> <expected output regex> <allowlist>
  run_case() {
    local name=$1 want=$2 expect=$3 allow=$4 out rc=0
    printf '%s\n' "$allow" > "$tmp/$ALLOW_FILE"
    out=$(cd "$tmp" && bash "$self" 2>&1) || rc=$?
    if [ "$want" = pass ] && [ "$rc" -ne 0 ]; then
      echo "FAIL  $name: expected pass, got exit $rc: $out"; failed=$((failed + 1))
    elif [ "$want" = fail ] && [ "$rc" -ne 1 ]; then
      echo "FAIL  $name: expected exit 1, got exit $rc: $out"; failed=$((failed + 1))
    elif ! printf '%s\n' "$out" | grep -Eq "$expect"; then
      echo "FAIL  $name: output lacks /$expect/: $out"; failed=$((failed + 1))
    else
      echo "ok    $name"
    fi
  }

  local exact='src/app.py:round 2 by codex  # example reason'
  run_case "exact entry passes"        pass 'OK \(1 allowlisted\)' "$exact"
  run_case "empty substring"           fail 'malformed' 'src/app.py:  # because'
  run_case "whitespace substring"      fail 'malformed' 'src/app.py:   # because'
  run_case "empty reason"              fail 'malformed' 'src/app.py:round 2 by codex  # '
  run_case "whitespace reason"         fail 'malformed' 'src/app.py:round 2 by codex  #    '
  run_case "empty path"                fail 'malformed' ':round 2 by codex  # because'
  run_case "whitespace path"           fail 'malformed' ' :round 2 by codex  # because'
  run_case "one-character substring"   fail 'malformed' 'src/app.py:r  # because'
  run_case "glob substring *"          fail 'malformed' 'src/app.py:*  # because'
  run_case "glob substring r*d 2"      fail 'comment records review history' 'src/app.py:r*d 2  # because'
  run_case "glob substring [r]ound"    fail 'comment records review history' 'src/app.py:[r]ound 2  # because'
  run_case "glob substring round ?"    fail 'comment records review history' 'src/app.py:round ? by  # because'
  run_case "path *"                    fail 'comment records review history' '*:round 2 by codex  # because'
  run_case "path src/*"                fail 'comment records review history' 'src/*:round 2 by codex  # because'
  run_case "path prefix src/"          fail 'comment records review history' 'src/:round 2 by codex  # because'
  run_case "stale entry"               fail 'matches nothing' "$exact"$'\n''src/gone.py:round 2 by codex  # because'
  run_case "malformed line"            fail 'malformed' 'not an allowlist entry'
  run_case "missing reason separator"  fail 'malformed' 'src/app.py:round 2 by codex'


  # Docstring cases. Each plants one Python file and nothing else.
  git -C "$tmp" rm -q -f src/app.py
  # run_py <name> <want> <expect> <allowlist> <file body>
  run_py() {
    mkdir -p "$tmp/src"
    printf '%s' "$5" > "$tmp/src/doc.py"
    git -C "$tmp" add src/doc.py
    run_case "$1" "$2" "$3" "$4"
  }
  local multi=$'def f():\n    """Return one.\n\n    Added in fix round 3 so callers retry.\n    """\n    return 1\n'
  run_py "module docstring"        fail 'src/doc.py,line=1' '' $'"""Notes: codex round 7 required this."""\nx = 1\n'
  run_py "function docstring"      fail 'src/doc.py,line=2' '' $'def f():\n    """Return one; lkirc asked for this."""\n    return 1\n'
  run_py "class docstring"         fail 'src/doc.py,line=2' '' $'class C:\n    """Holds state, per the work order."""\n'
  run_py "continuation line"       fail 'src/doc.py,line=4' '' "$multi"
  run_py "allowlisted docstring"   pass 'OK \(1 allowlisted\)' 'src/doc.py:fix round 3 so callers retry  # example reason' "$multi"
  run_py "plain string literal"    pass 'OK \(0 allowlisted\)' '' $'msg = "codex round 7 failed"\nprint(msg)\n'
  run_py "unparsable python"       fail 'cannot parse' '' $'def (\n'

  if [ "$failed" -gt 0 ]; then
    echo "self-test: $failed case(s) failed." >&2
    return 1
  fi
  echo "self-test: OK."
}

tree=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tree) tree="${2:?--tree needs a value}"; shift 2 ;;
    --self-test) self_test; exit $? ;;
    -h|--help) awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

cd "$(git rev-parse --show-toplevel)"

# This script and its allowlist quote the markers by design.
exclude=(":(exclude)bin/check-review-comments.sh" ":(exclude)$ALLOW_FILE")

# Prints "<path>:<line>:<text>" for every line of every module, class and
# function docstring in the NUL-separated file list on stdin. It reads the
# source span of the docstring statement, so a marker on a continuation line
# gets its own line number. Exits 1 if a file does not parse: a file the check
# cannot read must not pass as clean.
PY_DOCSTRINGS=$(cat <<'PY'
import ast, subprocess, sys

if sys.version_info < (3, 8):
    sys.exit("python 3.8 or newer is needed to read docstring line ranges")
tree = sys.argv[1]
status = 0
for raw in sys.stdin.buffer.read().split(b"\0"):
    if not raw:
        continue
    path = raw.decode("utf-8", "surrogateescape")
    if tree and path.startswith(tree + ":"):
        path = path[len(tree) + 1:]
    if tree:
        data = subprocess.run(["git", "show", tree + ":" + path],
                              check=True, stdout=subprocess.PIPE).stdout
    else:
        with open(path, "rb") as fh:
            data = fh.read()
    try:
        module = ast.parse(data)
    except (SyntaxError, ValueError) as err:
        print("cannot parse " + path + ": " + str(err), file=sys.stderr)
        status = 1
        continue
    lines = data.decode("utf-8", "replace").replace("\r\n", "\n").split("\n")
    for node in ast.walk(module):
        if not isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef,
                                 ast.AsyncFunctionDef)) or not node.body:
            continue
        first = node.body[0]
        if (isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant)
                and isinstance(first.value.value, str)):
            for n in range(first.lineno, first.end_lineno + 1):
                print(path + ":" + str(n) + ":" + lines[n - 1])
sys.exit(status)
PY
)

# py_files: NUL-separated tracked *.py paths in scope, same excludes as above.
py_files() { git grep -lIz -e '' ${tree:+"$tree"} -- '*.py' "${exclude[@]}" || true; }

if [ -n "$tree" ]; then
  hits=$(git grep -nIiE "$PATTERN" "$tree" -- . "${exclude[@]}" | sed "s|^$tree:||" || true)
  allow=$(git show "$tree:$ALLOW_FILE" 2>/dev/null || true)
else
  hits=$(git grep -nIiE "$PATTERN" -- . "${exclude[@]}" || true)
  allow=$(cat "$ALLOW_FILE" 2>/dev/null || true)
fi

# Docstrings carry no comment leader, so scan them separately and merge.
if [ "$(py_files | tr -cd '\0' | wc -c)" -gt 0 ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "::error::python3 is required to check docstrings in tracked *.py files; install it" >&2
    exit 1
  fi
  doc_lines=$(py_files | python3 -c "$PY_DOCSTRINGS" "$tree") || {
    echo "::error::could not scan Python docstrings (see above); refusing to pass unchecked" >&2
    exit 1
  }
  doc_hits=$(printf '%s\n' "$doc_lines" | grep -iE "$MARKERS" || true)
  hits=$(printf '%s\n%s\n' "$hits" "$doc_hits" | awk 'NF && !seen[$0]++')
fi

# Parse the allowlist into parallel arrays (bash 3.2 has no associative ones).
# Every field must carry content: an empty substring would match every line
# of its file, and an empty path or reason leaves the entry unexplained.
allow_path=(); allow_text=(); allow_used=()
bad_entries=0
reject() {
  echo "::error file=$ALLOW_FILE::malformed entry ($1; want '<path>:<substring>  # <reason>'): $entry"
  bad_entries=$((bad_entries + 1))
}
while IFS= read -r entry; do
  case "$entry" in ''|'#'*) continue ;; esac
  body=${entry%%  # *}
  if [ "$body" = "$entry" ] || [ "${body#*:}" = "$body" ]; then
    reject "no path, substring or reason separator"
    continue
  fi
  e_path=${body%%:*}
  e_text=${body#*:}
  e_reason=${entry#*  # }
  if blank "$e_path"; then reject "empty path"; continue; fi
  if blank "$e_text"; then reject "empty substring"; continue; fi
  if blank "$e_reason"; then reject "empty reason"; continue; fi
  e_text_nospace=${e_text//[[:space:]]/}
  if [ "${#e_text_nospace}" -lt "$MIN_SUBSTRING" ]; then
    reject "substring shorter than $MIN_SUBSTRING characters"
    continue
  fi
  allow_path+=("$e_path")
  allow_text+=("$e_text")
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
    # Both comparisons are literal: the quotes stop glob matching, and the
    # path must equal the hit's path, not prefix it.
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
