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
# Comment syntaxes covered, by file extension. Nothing else is claimed.
#
#   per-line leaders  #  //  --  *   any tracked file in scope; a marker must
#                                    follow the leader on the same line
#   docstrings        *.py           module, class and function docstrings
#   /* ... */         *.ts *.tsx *.js *.jsx *.cjs *.mjs *.css *.scss *.tf
#                     *.tfvars (string-aware); *.html *.htm *.svg *.vue
#                     (not string-aware)
#   <!-- ... -->      *.html *.htm *.svg *.vue *.xml *.bpmn *.j2 *.jinja
#   {# ... #}         *.html *.htm *.j2 *.jinja *.jinja2
#   {{/* ... */}}     *.tpl *.tftpl *.yaml *.yml, also as {{- /* ... */ -}}
#
# A docstring or block comment has no leader on its interior lines, so every
# line from the opening delimiter to the closing one is matched on the
# markers alone and reported as <path>:<line>; the allowlist covers it the
# same way. These need python3 whenever a file with one of those extensions is
# tracked, and the check fails rather than skip them. Where a delimiter could
# sit inside a string, the scanners for JavaScript, TypeScript, CSS and
# Terraform skip strings; the others do not, so they can report a delimiter
# inside a string, never miss a comment.
#
# Out of scope: ordinary string literals (log and error text are data),
# Markdown, lockfiles and generated or minified files (see the excludes), and
# any syntax or extension not listed above.
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


  # Comment cases without a per-line leader. Each plants one file and nothing
  # else. The marker sits on an interior line, where no leader precedes it.
  git -C "$tmp" rm -q -f src/app.py
  # run_file <name> <want> <expect> <allowlist> <path> <file body>
  run_file() {
    git -C "$tmp" rm -q -r -f --ignore-unmatch -- . >/dev/null
    mkdir -p "$tmp/$(dirname "$5")"
    printf '%s' "$6" > "$tmp/$5"
    git -C "$tmp" add "$5"
    run_case "$1" "$2" "$3" "$4"
  }
  local multi=$'def f():\n    """Return one.\n\n    Added in fix round 3 so callers retry.\n    """\n    return 1\n'
  local inner=$'codex round 7 required this\n'
  run_file "py module docstring"   fail 'src/doc.py,line=1' '' src/doc.py $'"""Notes: codex round 7 required this."""\nx = 1\n'
  run_file "py function docstring" fail 'src/doc.py,line=2' '' src/doc.py $'def f():\n    """Return one; lkirc asked for this."""\n    return 1\n'
  run_file "py class docstring"    fail 'src/doc.py,line=2' '' src/doc.py $'class C:\n    """Holds state, per the work order."""\n'
  run_file "py continuation line"  fail 'src/doc.py,line=4' '' src/doc.py "$multi"
  run_file "py allowlisted docstring" pass 'OK \(1 allowlisted\)' 'src/doc.py:fix round 3 so callers retry  # example reason' src/doc.py "$multi"
  run_file "py plain string literal" pass 'OK \(0 allowlisted\)' '' src/doc.py $'msg = "codex round 7 failed"\nprint(msg)\n'
  run_file "py unparsable"         fail 'cannot parse' '' src/doc.py $'def (\n'
  run_file "ts /* */ interior"     fail 'src/a.ts,line=3' '' src/a.ts $'/*\n * Notes.\n'"$inner"$' */\nexport const x = 1;\n'
  run_file "tsx {/* */} interior"  fail 'src/a.tsx,line=3' '' src/a.tsx $'export const A = () => (\n  <div>{/*\n'"$inner"$'  */}</div>\n);\n'
  run_file "css /* */ interior"    fail 'src/a.css,line=2' '' src/a.css $'/*\n'"$inner"$'*/\n.a { color: red; }\n'
  run_file "html <!-- --> interior" fail 'page.html,line=2' '' page.html $'<!--\n'"$inner"$'-->\n<p>x</p>\n'
  run_file "html {# #} interior"   fail 'page.html,line=2' '' page.html $'{#\n'"$inner"$'#}\n<p>x</p>\n'
  run_file "j2 {# #} interior"     fail 'conf.j2,line=2' '' conf.j2 $'{#\n'"$inner"$'#}\nkey: value\n'
  run_file "svg <!-- --> interior" fail 'img.svg,line=2' '' img.svg $'<!--\n'"$inner"$'-->\n<svg></svg>\n'
  run_file "tpl {{/* */}} interior" fail 'charts/c/templates/_h.tpl,line=2' '' charts/c/templates/_h.tpl $'{{/*\n'"$inner"$'*/}}\n'
  run_file "yaml {{- /* */ -}} interior" fail 'charts/c/templates/cm.yaml,line=3' '' charts/c/templates/cm.yaml $'data:\n  {{- /*\n'"$inner"$'  */ -}}\n'
  run_file "ts allowlisted interior" pass 'OK \(1 allowlisted\)' 'src/a.ts:round 7 required this  # example reason' src/a.ts $'/*\n * Notes.\n'"$inner"$' */\nexport const x = 1;\n'
  run_file "ts delimiters in strings" pass 'OK \(0 allowlisted\)' '' src/a.ts $'const a = "/*";\nconst b = "codex round 7 failed";\nconst c = "*/";\n'
  run_file "html delimiter in string (over-reports)" fail 'page.html,line=2' '' page.html $'<p title="<!--">\n'"$inner"$'</p>\n'
  run_file "shell glob is not a comment" pass 'OK \(0 allowlisted\)' '' bin/x.sh $'ls /tmp/*\necho "codex round 7 failed"\n'

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

# Prints "<path>:<line>:<text>" for every line of every comment that has no
# per-line leader: Python docstrings, and block comments in the syntaxes named
# in the header. A comment's lines run from its opening delimiter to its
# closing one, so a marker on an interior line gets its own line number.
# Exits 1 if a Python file does not parse: a file the check cannot read must
# not pass as clean.
#
# String literals are skipped only where that is cheap: the C-style scanner
# (TypeScript, JavaScript, CSS, Terraform) steps over '...', "..." and `...`.
# The delimiter scanners for HTML, Jinja and Go templates do not know about
# strings, so a delimiter inside a string there opens a comment. That fails
# closed: it can only report more, never less. An unterminated block runs to
# the end of the file for the same reason.
PY_SCAN=$(cat <<'PY'
import ast, re, subprocess, sys

if sys.version_info < (3, 8):
    sys.exit("python 3.8 or newer is needed to read comment line ranges")

C = (re.compile(r"/\*"), "*/")
HTML = (re.compile(r"<!--"), "-->")
JINJA = (re.compile(r"\{#"), "#}")
GOT = (re.compile(r"\{\{-?\s*/\*"), "*/")
# Extensions whose block comments need string-aware scanning, with the line
# comment leaders that can hide a "/*" from the scanner.
CSCAN = {"ts": ("//",), "tsx": ("//",), "js": ("//",), "jsx": ("//",),
         "cjs": ("//",), "mjs": ("//",), "css": (), "scss": ("//",),
         "tf": ("#", "//"), "tfvars": ("#", "//")}
DELIM = {"html": [HTML, JINJA, C], "htm": [HTML, JINJA, C],
         "svg": [HTML, C], "vue": [HTML, C], "xml": [HTML], "bpmn": [HTML],
         "j2": [JINJA, HTML], "jinja": [JINJA, HTML], "jinja2": [JINJA, HTML],
         "tpl": [GOT], "tftpl": [GOT], "yaml": [GOT], "yml": [GOT]}


def c_spans(text, leaders):
    spans, i, n, line = [], 0, len(text), 1
    while i < n:
        ch = text[i]
        if ch == "\n":
            line += 1
            i += 1
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            end = n if j < 0 else j + 2
            first = line
            line += text.count("\n", i, end)
            spans.append((first, line))
            i = end
        elif any(text.startswith(m, i) for m in leaders):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif ch in "'\"`":
            i += 1
            while i < n and text[i] != ch:
                if text[i] == "\n":
                    if ch != "`":
                        break
                    line += 1
                elif text[i] == "\\" and i + 1 < n:
                    if text[i + 1] == "\n":
                        line += 1
                    i += 1
                i += 1
            if i < n and text[i] == ch:
                i += 1
        else:
            i += 1
    return spans


def delim_spans(text, syntaxes):
    spans, pos = [], 0
    while True:
        found = [(m.start(), m.end(), close)
                 for opener, close in syntaxes
                 for m in [opener.search(text, pos)] if m]
        if not found:
            return spans
        start, after, close = min(found, key=lambda f: f[0])
        j = text.find(close, after)
        end = len(text) if j < 0 else j + len(close)
        spans.append((text.count("\n", 0, start) + 1,
                      text.count("\n", 0, end) + 1))
        pos = end


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
    text = data.decode("utf-8", "replace").replace("\r\n", "\n")
    lines = text.split("\n")
    ext = path.rsplit(".", 1)[-1].lower() if "." in path.rsplit("/", 1)[-1] else ""
    spans = []
    if ext == "py":
        try:
            module = ast.parse(data)
        except (SyntaxError, ValueError) as err:
            print("cannot parse " + path + ": " + str(err), file=sys.stderr)
            status = 1
            continue
        for node in ast.walk(module):
            if not isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef,
                                     ast.AsyncFunctionDef)) or not node.body:
                continue
            first = node.body[0]
            if (isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant)
                    and isinstance(first.value.value, str)):
                spans.append((first.lineno, first.end_lineno))
    elif ext in CSCAN:
        spans = c_spans(text, CSCAN[ext])
    elif ext in DELIM:
        spans = delim_spans(text, DELIM[ext])
    for first, last in spans:
        for n in range(first, min(last, len(lines)) + 1):
            print(path + ":" + str(n) + ":" + lines[n - 1])
sys.exit(status)
PY
)

# scan_files: NUL-separated tracked paths in scope whose extension has a
# comment syntax beyond per-line leaders. Same excludes as above.
scan_files() {
  git grep -lIz -e '' ${tree:+"$tree"} -- \
    '*.py' '*.ts' '*.tsx' '*.js' '*.jsx' '*.cjs' '*.mjs' '*.css' '*.scss' \
    '*.tf' '*.tfvars' '*.html' '*.htm' '*.svg' '*.vue' '*.xml' '*.bpmn' \
    '*.j2' '*.jinja' '*.jinja2' '*.tpl' '*.tftpl' '*.yaml' '*.yml' \
    "${exclude[@]}" || true
}

if [ -n "$tree" ]; then
  hits=$(git grep -nIiE "$PATTERN" "$tree" -- . "${exclude[@]}" | sed "s|^$tree:||" || true)
  allow=$(git show "$tree:$ALLOW_FILE" 2>/dev/null || true)
else
  hits=$(git grep -nIiE "$PATTERN" -- . "${exclude[@]}" || true)
  allow=$(cat "$ALLOW_FILE" 2>/dev/null || true)
fi

# Docstrings and block-comment bodies carry no comment leader, so scan them
# separately and merge.
if [ "$(scan_files | tr -cd '\0' | wc -c)" -gt 0 ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "::error::python3 is required to check docstrings and block comments; install it" >&2
    exit 1
  fi
  scan_lines=$(scan_files | python3 -c "$PY_SCAN" "$tree") || {
    echo "::error::could not scan docstrings and block comments (see above); refusing to pass unchecked" >&2
    exit 1
  }
  scan_hits=$(printf '%s\n' "$scan_lines" | grep -iE "$MARKERS" || true)
  hits=$(printf '%s\n%s\n' "$hits" "$scan_hits" | awk 'NF && !seen[$0]++')
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
