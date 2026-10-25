#!/usr/bin/env bash
# check-review-comments.sh — fail when a comment records review history.
#
# A comment should say why the code is the way it is. Which review, round,
# reviewer, agent or work order prompted a change belongs in the PR and the
# issue, not in the file: it goes stale, means nothing to a new reader, and
# hides the actual reason. See dmfdeploy/dmfdeploy#768.
#
# The check runs one case-insensitive extended regex over every tracked code,
# configuration and test file: a comment leader (#, //, --, *, {#) followed later on the same line by
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
#                     *.tfvars (skips strings, see below); *.html *.htm *.svg
#                     *.vue (skips nothing)
#   <!-- ... -->      *.html *.htm *.svg *.vue *.xml *.bpmn *.j2 *.jinja
#   {# ... #}         *.html *.htm *.j2 *.jinja *.jinja2
#   {{/* ... */}}     *.tpl *.tftpl *.yaml *.yml, also as {{- /* ... */ -}}
#
# A docstring or block comment has no leader on its interior lines, so every
# line from the opening delimiter to the closing one is matched on the
# markers alone and reported as <path>:<line>; the allowlist covers it the
# same way. These need python3 whenever a file with one of those extensions is
# tracked, and the check fails rather than skip them.
#
# The scanner for JavaScript, TypeScript, CSS, SCSS and Terraform skips the
# places where "/*" is text, not a comment: strings, line comments, template
# text (`...` in JavaScript, "..." and <<EOF heredocs in Terraform) and regex
# literals. A substitution inside a template or string (${...}, #{...} in
# SCSS, %{...} in Terraform) is code and can hold a comment, so it is scanned
# as code, nested to any depth.
#
# Whether a "/" starts a regex and a "<" starts JSX depends on the token
# before it, so the scanner sometimes guesses. Where the token cannot decide
# (after ")", "}", "of", "yield" or "await", a "<" in .js, .cjs and .mjs, or
# a <T>( or <T extends in .tsx), it follows both readings and reports a
# comment either one finds. Elsewhere it takes one reading, and a wrong
# guess must not cost a comment:
#   - JSX is read to its grammar, and a closing tag must name the element it
#     closes. A guessed JSX reading that breaks the grammar, or is still open
#     at the end of the file, goes back to the "<" and rescans it as an
#     operator.
#   - A "/*" inside JSX text or a JSX attribute string is reported, not
#     skipped, so a guess that closes by accident hides nothing it covered.
#   - A regex is read only if it closes on its line. One that would hide a
#     "/*" is checked against the division reading too.
#   - A '...' or "..." string still open at the end of its line means the
#     scanner lost track, so it rescans that line from the quote as code.
#   - In SCSS, a // comment never hides a "/*", because // is not a comment
#     inside url(...) or a custom property value.
#   - When the last reading breaks the syntax, more than 64 are live, or the
#     scan passes 4 steps per character of the file, the rest of the file
#     from the earliest point still in doubt skips nothing. The step budget
#     bounds the retries, so a file costs linear time; real code uses under
#     half a step per character.
# The other scanners skip nothing. So a delimiter inside a string, template
# or JSX text can be reported, but a comment in valid code is not missed.
# The residual risk is a wrong guess the rules above do not catch: one that
# closes cleanly and leaves the scanner out of step, so a later comment is
# read from the wrong context. Syntax the scanner does not model is outside
# that promise.
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
work=""
trap '[ -z "$tmp" ] || rm -rf "$tmp"; [ -z "$work" ] || rm -rf "$work"' EXIT
self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# blank <string>: true when the string is empty or only whitespace.
blank() { [ -z "${1//[[:space:]]/}" ]; }

# gh_data / gh_prop: escape untrusted text (paths, line content, allowlist
# entries) for a GitHub workflow command. A path or line may hold a newline,
# a carriage return, a comma or "::", and unescaped they would end the
# annotation early or start a new command.
gh_data() {
  local s=$1
  s=${s//'%'/%25}; s=${s//$'\r'/%0D}; s=${s//$'\n'/%0A}
  printf '%s' "$s"
}
gh_prop() {
  local s
  s=$(gh_data "$1")
  s=${s//:/%3A}; s=${s//,/%2C}
  printf '%s' "$s"
}

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
  run_file "ts comment in a template substitution" fail 'src/a.ts,line=3' '' src/a.ts $'const s = `a ${ /*\n * Notes.\n'"$inner"$' */ x } b`;\n'
  run_file "tsx comment in a template substitution" fail 'src/a.tsx,line=3' '' src/a.tsx $'const s = `a ${ /*\n * Notes.\n'"$inner"$' */ x } b`;\n'
  run_file "ts template text with /* and no marker" pass 'OK \(0 allowlisted\)' '' src/a.ts $'const s = `glob: src/*.ts`;\nconst t = 1;\n'
  run_file "ts template text with /* then a marker" pass 'OK \(0 allowlisted\)' '' src/a.ts $'const s = `glob: src/*.ts`;\nconst t = "codex round 7 failed";\n'
  # Text that cannot hold a comment must not hide a real opener after it,
  # and must not open one itself. Bodies are valid code unless marked; in a
  # fail case the marker sits on the line after the opener, with no leader.
  local tail=$'\n'"$inner"$'*/\n'
  run_file "ts // in template text" fail 'src/a.ts,line=2' '' src/a.ts $'const t = `//`; /*'"$tail"
  run_file "ts quote in template text" fail 'src/a.ts,line=2' '' src/a.ts $'const t = `it\'s`; /*'"$tail"
  run_file "ts escaped backtick in template text" fail 'src/a.ts,line=2' '' src/a.ts $'const t = `a \\` // b`; /*'"$tail"
  run_file "ts multi-line template keeps line numbers" fail 'src/a.ts,line=3' '' src/a.ts $'const t = `one\ntwo //`; /*'"$tail"
  run_file "ts nested template in a substitution" fail 'src/a.ts,line=2' '' src/a.ts $'const t = `a ${ `b // ${ c }` } //`; /*'"$tail"
  run_file "ts object braces in a substitution" fail 'src/a.ts,line=2' '' src/a.ts $'const t = `${ {a: 1} /*'"$tail"$'.a }`;\n'
  run_file "ts quote in a regex" fail 'src/a.ts,line=2' '' src/a.ts $'const r = /\'/; /*'"$tail"
  run_file "ts escaped slash in a regex" fail 'src/a.ts,line=2' '' src/a.ts $'const r = /a\\//; /*'"$tail"
  run_file "ts quotes in a regex class" fail 'src/a.ts,line=2' '' src/a.ts $'const r = /["\']/g; /*'"$tail"
  run_file "ts slash in a regex class" fail 'src/a.ts,line=2' '' src/a.ts $'const r = /[/]\'/; /*\''"$tail"
  # Not valid code: the line shows what happens once the scanner loses track.
  run_file "unclosed string does not hide a /*" fail 'src/a.ts,line=2' '' src/a.ts $'const a = \'oops; /*'"$tail"
  run_file "ts regex after ) pairs a quote" fail 'src/a.ts,line=2' '' src/a.ts $'if (ok) /"/.test(s); /* "'"$tail"
  run_file "ts division after ) is not a regex" fail 'src/a.ts,line=2' '' src/a.ts $'const h = (w) / 2; /*'"$tail"
  run_file "ts regex after return" fail 'src/a.ts,line=3' '' src/a.ts $'function f(s) {\n  return /\'/.test(s); /*'"$tail"$'}\n'
  run_file "tsx // in JSX text" fail 'src/a.tsx,line=2' '' src/a.tsx $'const a = <a>http://x {/*'"$tail"$'}</a>;\n'
  run_file "tsx quotes in JSX text" fail 'src/a.tsx,line=2' '' src/a.tsx $'const a = <p>It\'s {/* Bob\'s'"$tail"$'}</p>;\n'
  run_file "jsx JSX text after return" fail 'src/a.jsx,line=3' '' src/a.jsx $'function A() {\n  return <a title="x">http://x {/*'"$tail"$'}</a>;\n}\n'
  run_file "tsx /* in JSX text (over-reports)" fail 'src/a.tsx,line=2' '' src/a.tsx $'const a = <p>/* not a comment</p>;\nconst b = "codex round 7 failed";\nconst c = "*/";\n'
  run_file "js /* in JSX text (over-reports)" fail 'src/a.js,line=2' '' src/a.js $'const a = <p>/* not a comment</p>;\nconst b = "codex round 7 failed";\nconst c = "*/";\n'
  run_file "tsx generic arrow is not JSX" fail 'src/a.tsx,line=2' '' src/a.tsx $'const f = <T,>(x: T) => x; /*'"$tail"
  run_file "tsx generic function type is not JSX" fail 'src/a.tsx,line=2' '' src/a.tsx $'type F = <T>(x: T) => T; /*'"$tail"
  run_file "tsx const generic arrow is not JSX" pass 'OK \(0 allowlisted\)' '' src/a.tsx $'const f = <const T,>(x: T) => "/*";\nconst b = "codex round 7 failed";\nconst c = "*/";\n'
  # Not valid code: a tag that cannot close leaves no reading.
  run_file "tsx last reading lost does not end the scan" fail 'src/a.tsx,line=3' '' src/a.tsx $'const a = <b c;\n/*'"$tail"
  run_file "ts regex after yield" fail 'src/a.ts,line=3' '' src/a.ts $'function* g() {\n  yield /\'/; /* \''"$tail"$'}\n'
  run_file "js // in JSX text" fail 'src/a.js,line=2' '' src/a.js $'const a = <a>http://x {/*'"$tail"$'}</a>;\n'
  run_file "ts division after ) keeps strings opaque" pass 'OK \(0 allowlisted\)' '' src/a.ts $'const h = (w) / 2; const a = "/*";\nconst b = "codex round 7 failed";\nconst c = "*/";\n'
  # A guess that turns out wrong must not lose a comment.
  run_file "jsx Flow generic is not JSX" fail 'src/a.jsx,line=3' '' src/a.jsx $'const f = <T: string>(x: T): T => x;\n/*\n codex round 7\n*/\n'
  run_file "jsx Flow generic, then JSX" fail 'src/a.jsx,line=3' '' src/a.jsx $'const f = <T: string>(x: T): T => x;\n/*'"$tail"$'const e = <p>hi</p>;\n'
  # Not valid code: the guessed element closes by accident on the last line,
  # so no reading fails and nothing is retried.
  run_file "jsx guessed JSX that closes by accident" fail 'src/a.jsx,line=3' '' src/a.jsx $'const f = <T>x;\n/*'"$tail"$'const s = "</T>";\n'
  run_file "tsx guessed JSX that closes by accident" fail 'src/a.tsx,line=3' '' src/a.tsx $'const f = <T>x;\n/*'"$tail"$'const s = "</T>";\n'
  local strs=$'const a = "/*";\nconst b = "codex round 7 failed";\nconst c = "*/";\n'
  run_file "jsx Flow generic is rescanned as code" pass 'OK \(0 allowlisted\)' '' src/a.jsx $'const f = <T: string>(x: T): T => x;\n'"$strs"
  # Not valid code: a closing tag for another element ends the guess, so the
  # scan goes back to the "<" instead of reading on out of step.
  run_file "jsx closing tag must match" pass 'OK \(0 allowlisted\)' '' src/a.jsx $'const f = <T>x;\nconst s = `</p>\n`;\n'"$strs"
  # Not valid code: the guessed element never closes, so the scan goes back
  # to the "<" at the end of the file.
  run_file "jsx guess still open at the end of the file" pass 'OK \(0 allowlisted\)' '' src/a.jsx $'const f = <T>{ "/*" };\nconst b = "codex round 7 failed";\nconst c = "*/";\n'
  # Not valid code: the guess closes by accident inside a template, so the
  # scanner reads on out of step and ends the file inside a template.
  run_file "jsx guess that closes inside a template" fail 'src/a.jsx,line=4' '' src/a.jsx $'const f = <T>x;\nconst s = `</T>\n`; /*'"$tail"
  run_file "js regex guess that runs to the end of the line" fail 'src/a.js,line=3' '' src/a.js $'const h = (w) / \'it\\\'s\';\n/*'"$tail"
  run_file "js number before a slash" fail 'src/a.js,line=2' '' src/a.js $'const a = 1./2; /*'"$tail"
  # Not valid code: every line opens a guessed element that never closes, so
  # each guess runs far before it fails. The scan must still finish and
  # report the comment at the end.
  local many
  many=$(awk 'BEGIN { for (i = 0; i < 3000; i++) print "const a = <T>x;" }')
  run_file "jsx 3000 failing guesses stay within the step budget" fail 'src/a.jsx,line=3002' '' src/a.jsx "$many"$'\n/*'"$tail"
  run_file "ts reserved word as a property" fail 'src/a.ts,line=2' '' src/a.ts $'const h = o.return / 2; /*'"$tail"
  run_file "tf comment in a string substitution" fail 'main.tf,line=2' '' main.tf $'x = "${ /*'"$tail"$'1 }"\n'
  run_file "tfvars comment in a string substitution" fail 'env.tfvars,line=2' '' env.tfvars $'x = "${ /*'"$tail"$'1 }"\n'
  run_file "tf quote in a comment in a substitution" fail 'main.tf,line=2' '' main.tf $'x = "${ 1 /* "'"$tail"$'}"\n'
  run_file "tf // in heredoc text" fail 'main.tf,line=3' '' main.tf $'x = <<EOF\nsee // ${ /*'"$tail"$'1 }\nEOF\n'
  run_file "tf heredoc text with /* and no marker" pass 'OK \(0 allowlisted\)' '' main.tf $'x = <<-EOF\n  src/*.tf\n  EOF\ny = "codex round 7 failed"\n'
  run_file "scss // in an unquoted url" fail 'src/a.scss,line=2' '' src/a.scss $'.a { background: url(http://x/a.png); /*'"$tail"$'}\n'
  run_file "scss // in a custom property" fail 'src/a.scss,line=2' '' src/a.scss $'.a { --u: http://x; /*'"$tail"$'}\n'
  run_file "ts allowlisted interior" pass 'OK \(1 allowlisted\)' 'src/a.ts:round 7 required this  # example reason' src/a.ts $'/*\n * Notes.\n'"$inner"$' */\nexport const x = 1;\n'
  run_file "ts delimiters in strings" pass 'OK \(0 allowlisted\)' '' src/a.ts $'const a = "/*";\nconst b = "codex round 7 failed";\nconst c = "*/";\n'
  run_file "html delimiter in string (over-reports)" fail 'page.html,line=2' '' page.html $'<p title="<!--">\n'"$inner"$'</p>\n'
  run_file "shell glob is not a comment" pass 'OK \(0 allowlisted\)' '' bin/x.sh $'ls /tmp/*\necho "codex round 7 failed"\n'

  # Paths that hold the delimiters the old colon-joined records split on.
  # run_pair <name> <want> <expect> <allowlist> <path1> <body1> <path2> <body2>
  run_pair() {
    git -C "$tmp" rm -q -r -f --ignore-unmatch -- . >/dev/null
    mkdir -p "$tmp/$(dirname "$5")" "$tmp/$(dirname "$7")"
    printf '%s' "$6" > "$tmp/$5"
    printf '%s' "$8" > "$tmp/$7"
    git -C "$tmp" add -- "$5" "$7"
    run_case "$1" "$2" "$3" "$4"
  }
  local hit=$'x = 1  # fixed in round 2 by codex\n'
  local entry='src/app.py:round 2 by codex  # example reason'
  run_pair "path 'allowed:x' cannot borrow the entry" fail 'file=src/app.py%3Ax,line=1' "$entry" src/app.py "$hit" 'src/app.py:x' "$hit"
  run_pair "docstring path 'allowed:x' cannot borrow the entry" fail 'file=src/doc.py%3Ax.py,line=1' 'src/doc.py:round 2 by codex  # example reason' src/doc.py $'"""A note: round 2 by codex."""\n' 'src/doc.py:x.py' $'"""A note: round 2 by codex."""\n'
  run_pair "block-comment path 'allowed:x' cannot borrow the entry" fail 'file=src/a.css%3Ax.css,line=2' 'src/a.css:round 7 required this  # example reason' src/a.css $'/*\ncodex round 7 required this\n*/\n' 'src/a.css:x.css' $'/*\ncodex round 7 required this\n*/\n'
  run_file "path with a space"     fail 'file=src/a b.py,line=1' '' 'src/a b.py' "$hit"
  run_file "allowlisted path with a space" pass 'OK \(1 allowlisted\)' 'src/a b.py:round 2 by codex  # example reason' 'src/a b.py' "$hit"
  run_file "path with a tab"       fail $'file=src/a\tb.py,line=1' '' $'src/a\tb.py' "$hit"
  run_file "path with a newline"   fail 'file=src/a%0Ab.py,line=1' '' $'src/a\nb.py' "$hit"
  run_file "docstring in path with a space" fail 'file=src/d e.py,line=1' '' 'src/d e.py' $'"""Round 2 by codex."""\n'

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

# Prints "<path> NUL <line> NUL <text> NL" for every line of every comment that has no
# per-line leader: Python docstrings, and block comments in the syntaxes named
# in the header, that matches the markers. A comment's lines run from its
# opening delimiter to its closing one, so a marker on an interior line gets
# its own line number. NUL separates the fields because git permits ":", tabs
# and newlines in a path.
# Exits 1 if a Python file does not parse: a file the check cannot read must
# not pass as clean.
#
# The C-style scanner (TypeScript, JavaScript, CSS, SCSS, Terraform) skips
# only text that cannot hold code: strings, template text, regex literals,
# JSX text and line comments, but never a ${...} substitution, which is code.
# Where it cannot tell which reading is right, it follows all of them or
# goes back when a guess fails, and where it loses track it reports rather
# than skips; the header lists how.
# The delimiter scanners for HTML, Jinja and Go templates do not know about
# strings, so a delimiter inside a string there opens a comment. Both fail
# closed: they can only report more, never less. An unterminated block runs
# to the end of the file for the same reason.
# read, not $(cat <<...): bash 3.2 matches quotes inside a heredoc that sits
# in a command substitution, and the Python holds unpaired ones.
IFS= read -r -d '' PY_SCAN <<'PY' || true
import ast, bisect, heapq, re, subprocess, sys

if sys.version_info < (3, 8):
    sys.exit("python 3.8 or newer is needed to read comment line ranges")

C = (re.compile(r"/\*"), "*/")
HTML = (re.compile(r"<!--"), "-->")
JINJA = (re.compile(r"\{#"), "#}")
GOT = (re.compile(r"\{\{-?\s*/\*"), "*/")
# Languages whose block comments need a context-aware scanner. "leaders" are
# the line comment leaders; "quotes" maps each string quote to the openers of
# a substitution inside it, and "escapes" are the spellings of a literal
# opener. "template", "regex" and "jsx" turn on JavaScript template literals,
# regex literals and JSX. "heredoc" turns on Terraform <<EOF strings.
# "open_line" stops a line comment from hiding a "/*": in SCSS, // is not a
# comment inside url(...) or a custom property value, and the scanner does
# not model either.
JS = {"leaders": ("//",), "quotes": {"'": (), '"': ()},
      "template": True, "regex": True}
# "jsx": "sure" where an operand position can only start JSX with "<",
# "maybe" where Flow generics look the same.
JSX = dict(JS, jsx="maybe")
TSX = dict(JS, jsx="sure")
CSS = {"leaders": (), "quotes": {"'": (), '"': ()}}
SCSS = {"leaders": ("//",), "quotes": {"'": ("#{",), '"': ("#{",)},
        "open_line": True}
HCL = {"leaders": ("#", "//"), "quotes": {'"': ("${", "%{")},
       "escapes": ("$${", "%%{"), "heredoc": True}
# .ts cannot hold JSX; .js, .cjs and .mjs often do.
CSCAN = {"ts": JS, "tsx": TSX, "js": JSX, "jsx": TSX, "cjs": JSX, "mjs": JSX,
         "css": CSS, "scss": SCSS, "tf": HCL, "tfvars": HCL}
DELIM = {"html": [HTML, JINJA, C], "htm": [HTML, JINJA, C],
         "svg": [HTML, C], "vue": [HTML, C], "xml": [HTML], "bpmn": [HTML],
         "j2": [JINJA, HTML], "jinja": [JINJA, HTML], "jinja2": [JINJA, HTML],
         "tpl": [GOT], "tftpl": [GOT], "yaml": [GOT], "yml": [GOT]}

# Words after which an operand follows, so a "/" starts a regex and a "<"
# starts JSX. A reserved word is a property name after ".", and the
# contextual ones can also name a variable, so after those the scanner
# follows both readings.
RESERVED = frozenset("return typeof instanceof in new delete void throw "
                     "case do else".split())
CONTEXTUAL = frozenset("of yield await".split())
# A number keeps its ".", so the "/" in 1./2 is division.
WORD = re.compile(r"\d[\w$.]*|[\w$#]+")
SPACE = re.compile(r"\s+")
FLAGS = re.compile(r"[\w$]*")
JSX_START = re.compile(r"[\s\w$>]")
# In .tsx, <T,> and <T = U> can only open type parameters, while <T>(...)
# and <T extends U> can open type parameters or JSX.
TYPE_PARAMS = re.compile(r"\s*(?:const\s+)?[\w$]+\s*[,=]")
TYPE_OR_JSX = re.compile(r"\s*(?:const\s+)?[\w$]+\s*(?:extends\b|>\s*\()")
HEREDOC = re.compile(r"<<-?([A-Za-z_][\w-]*)[ \t]*\n")
TEMPLATE_STOP = re.compile(r"[\\`$]")
JSX_TEXT_STOP = re.compile(r"[{</]")
# A JSX tag name (div, a-b, svg:path, Foo.Bar) and an attribute name.
JSX_NAME = re.compile(r"(?:[^\W\d]|\$)[\w$-]*(?::(?:[^\W\d]|\$)[\w$-]*)?"
                      r"(?:\.(?:[^\W\d]|\$)[\w$-]*)*")
JSX_ATTR = re.compile(r"(?:[^\W\d]|\$)[\w$-]*(?::(?:[^\W\d]|\$)[\w$-]*)?\s*(=)?")
# More live readings than this, or more steps than STEP_BUDGET per
# character, and the scanner stops guessing. A reading whose context stack
# or JSX element nesting grows deeper than MAX_DEPTH ends as if it broke the
# syntax.
MAX_READINGS = 64
STEP_BUDGET = 4
MAX_DEPTH = 200


def c_spans(text, lang):
    """Return (first, last) line pairs of the block comments in text.

    A reading is the scanner's position plus a context stack: code (with its
    brace depth), string, template text, heredoc or JSX. Where the token
    before a "/" or "<" cannot tell an operator from a regex or JSX start,
    both readings go forward and a comment either one finds is kept. A
    reading that breaks the syntax (a regex or JSX tag that cannot close)
    stops; readings that reach the same state merge. Where only a JSX
    reading was taken, its failure resumes the operator reading it skipped.
    """
    n = len(text)
    starts = [0] + [m.end() for m in re.finditer("\n", text)]
    spans = set()
    leaders = lang["leaders"]
    quotes = lang["quotes"]
    escapes = lang.get("escapes", ())
    string_stop = {q: re.compile("[\\\\\n" + re.escape(q + "".join(
        o[0] for o in opens + escapes)) + "]") for q, opens in quotes.items()}

    def line_of(pos):
        return bisect.bisect_right(starts, pos)

    ends = {}

    def block(i):
        if i not in ends:
            j = text.find("*/", i + 2)
            ends[i] = n if j < 0 else j + 2
            spans.add((line_of(i), line_of(max(ends[i] - 1, i))))
        return ends[i]

    # A guess is a JSX reading taken without following the operator reading
    # too. alts[g] is that other reading; it is resumed if guess g fails.
    alts, used = [], set()

    def regex_end(i):
        # A regex literal cannot hold a raw newline; None means i does not
        # start one.
        j, in_class = i + 1, False
        while j < n:
            c = text[j]
            if c == "\n":
                return None
            if c == "\\":
                if j + 1 < n and text[j + 1] == "\n":
                    return None
                j += 2
                continue
            if in_class:
                in_class = c != "]"
            elif c == "[":
                in_class = True
            elif c == "/":
                return FLAGS.match(text, j + 1).end()
            j += 1
        return None

    def code(i, stack, prev):
        # prev classes the token before i: "R" means an operand may follow
        # (so "/" starts a regex), "D" means an operator must, "B" either.
        ch, top = text[i], stack[-1]
        if ch.isspace():
            return [(SPACE.match(text, i).end(), stack, prev)]
        if text.startswith("/*", i):
            return [(block(i), stack, prev)]
        for m in leaders:
            if text.startswith(m, i):
                j = text.find("\n", i)
                j = n if j < 0 else j
                if lang.get("open_line"):
                    k = text.find("/*", i + len(m), j)
                    j = j if k < 0 else k
                return [(j, stack, prev)]
        if ch in quotes:
            return [(i + 1, stack + (("s", ch, i),), prev)]
        if ch == "`" and lang.get("template"):
            return [(i + 1, stack + (("t",),), prev)]
        if ch == "<" and lang.get("heredoc"):
            m = HEREDOC.match(text, i)
            if m:
                return [(m.end(), stack + (("h", m.group(1)),), prev)]
        if ch == "{":
            return [(i + 1, stack[:-1] + (("c", top[1] + 1),), "R")]
        if ch == "}":
            if top[1] > 0:
                return [(i + 1, stack[:-1] + (("c", top[1] - 1),), "B")]
            # Closes a substitution or JSX expression; at the top level it
            # is unbalanced and ignored.
            return [(i + 1, stack[:-1] if len(stack) > 1 else stack, "B")]
        m = WORD.match(text, i)
        if m:
            w = m.group()
            if w in RESERVED:
                j = i - 1
                while j >= 0 and text[j].isspace():
                    j -= 1
                after_dot = j >= 0 and text[j] == "."
                return [(m.end(), stack, "D" if after_dot else "R")]
            return [(m.end(), stack, "B" if w in CONTEXTUAL else "D")]
        if lang.get("regex") and ch == "/":
            out = []
            guess = False
            if prev in "RB":
                end = regex_end(i)
                if end is not None:
                    out.append((end, stack, "D"))
                    # A regex that would hide a "/*" is checked against the
                    # division reading too, in case the token before was
                    # misread.
                    guess = text.find("/*", i, end + 1) >= 0
            if prev in "DB" or not out or guess:
                out.append((i + 1, stack, "R"))
            return out
        if (ch == "<" and lang.get("jsx") and prev in "RB"
                and JSX_START.match(text, i + 1)):
            op = (i + 1, stack, "R")
            if (lang["jsx"] == "sure" and prev == "R"
                    and not TYPE_OR_JSX.match(text, i + 1)):
                if TYPE_PARAMS.match(text, i + 1):
                    return [op]
                alts.append(op)
                return [(i + 1, stack + (("jo", (), "n", "", len(alts) - 1),), prev)]
            return [(i + 1, stack + (("jo", (), "n", "", -1),), prev), op]
        if ch == ")" or text.startswith(("++", "--"), i):
            return [(i + (1 if ch == ")" else 2), stack, "B")]
        if ch == "]":
            return [(i + 1, stack, "D")]
        if ch == "!" and not text.startswith("!=", i):
            # Logical not, or the TypeScript non-null assertion x!.
            return [(i + 1, stack, "B")]
        return [(i + 1, stack, "R")]

    def string(i, stack, prev):
        _, q, start = stack[-1]
        ch = text[i]
        if ch == "\\":
            return [(i + 2, stack, prev)]
        if ch == q:
            return [(i + 1, stack[:-1], "D")]
        if ch == "\n":
            # Valid code cannot leave a string open at a raw newline, so the
            # scanner has lost track. Rescan from after the quote as code, so
            # the misread string cannot hide a "/*" on this line.
            return [(start + 1, stack[:-1], "B")]
        for e in escapes:
            if text.startswith(e, i):
                return [(i + len(e), stack, prev)]
        for o in quotes[q]:
            if text.startswith(o, i):
                return [(i + len(o), stack + (("c", 0),), "R")]
        m = string_stop[q].search(text, i + 1)
        return [(m.start() if m else n, stack, prev)]

    def template(i, stack, prev):
        ch = text[i]
        if ch == "\\":
            return [(i + 2, stack, prev)]
        if ch == "`":
            return [(i + 1, stack[:-1], "D")]
        if text.startswith("${", i):
            return [(i + 2, stack + (("c", 0),), "R")]
        m = TEMPLATE_STOP.search(text, i + 1)
        return [(m.start() if m else n, stack, prev)]

    def heredoc(i, stack, prev):
        ident = stack[-1][1]
        if i == 0 or text[i - 1] == "\n":
            m = re.compile(r"[ \t]*" + re.escape(ident) + r"[ \t]*(?=\n|$)").match(text, i)
            if m:
                return [(m.end(), stack[:-1], "D")]
        for e in escapes:
            if text.startswith(e, i):
                return [(i + len(e), stack, prev)]
        if text.startswith(("${", "%{"), i):
            return [(i + 2, stack + (("c", 0),), "R")]
        return [(i + 1, stack, prev)]

    def jsx(i, stack, prev):
        # Frames: ("jx", names, guess) for element children, ("jo", names,
        # phase, name, guess) for an opening tag and ("jc", names, phase,
        # guess) for a closing one. names lists the open elements, innermost
        # last; a closing tag must name the innermost one. Any text that
        # breaks the JSX grammar ends the reading.
        top, rest, ch = stack[-1], stack[:-1], text[i]
        kind, names, guess = top[0], top[1], top[-1]
        if len(names) > MAX_DEPTH:
            return []
        if kind == "jx":
            if ch == "{":
                return [(i + 1, stack + (("c", 0),), "R")]
            if text.startswith("</", i):
                return [(i + 2, rest + (("jc", names, "n", guess),), prev)]
            if ch == "<":
                return [(i + 1, rest + (("jo", names, "n", "", guess),), prev)]
            if text.startswith("/*", i):
                # Literal text in real JSX, but the JSX reading may be a
                # wrong guess, so it is reported and never skipped.
                block(i)
            m = JSX_TEXT_STOP.search(text, i + 1)
            return [(m.start() if m else n, stack, prev)]
        if ch.isspace():
            return [(SPACE.match(text, i).end(), stack, prev)]
        if text.startswith("/*", i):
            return [(block(i), stack, prev)]
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            k = text.find("/*", i + 2, j)
            return [(j if k < 0 else k, stack, prev)]

        def close(at):
            if len(names) == 1:
                return [(at, rest, "D")]
            return [(at, rest + (("jx", names[:-1], guess),), prev)]

        if kind == "jc":
            if top[2] == "n":
                m = JSX_NAME.match(text, i)
                if m and names and m.group() == names[-1]:
                    return [(m.end(), rest + (("jc", names, "e", guess),), prev)]
                if ch == ">" and names and names[-1] == "":
                    return close(i + 1)
            elif ch == ">":
                return close(i + 1)
            return []
        phase, name = top[2], top[3]
        if phase == "n":
            if ch == ">":
                return [(i + 1, rest + (("jx", names + ("",), guess),), prev)]
            m = JSX_NAME.match(text, i)
            if m:
                return [(m.end(), rest + (("jo", names, "a", m.group(), guess),), prev)]
            return []
        attrs = rest + (("jo", names, "a", name, guess),)
        if phase == "v":
            if ch in "\"'":
                j = text.find(ch, i + 1)
                if j < 0:
                    return []
                k = text.find("/*", i + 1, j)
                while k >= 0:
                    # Reported for the same reason as in JSX text.
                    block(k)
                    k = text.find("/*", k + 2, j)
                return [(j + 1, attrs, prev)]
            if ch == "{":
                return [(i + 1, attrs + (("c", 0),), "R")]
            return []
        if ch == "{":
            return [(i + 1, stack + (("c", 0),), "R")]
        if ch == ">":
            return [(i + 1, rest + (("jx", names + (name,), guess),), prev)]
        if text.startswith("/>", i):
            if not names:
                return [(i + 2, rest, "D")]
            return [(i + 2, rest + (("jx", names, guess),), prev)]
        m = JSX_ATTR.match(text, i)
        if m:
            if m.group(1):
                return [(m.end(), rest + (("jo", names, "v", name, guess),), prev)]
            return [(m.end(), stack, prev)]
        return []

    steps = {"c": code, "s": string, "t": template, "h": heredoc,
             "jo": jsx, "jc": jsx, "jx": jsx}
    start = (0, (("c", 0),))
    live, heap = {start: "R"}, [start]

    def add(pos, stack, prev):
        key = (pos, stack)
        if key in live:
            if live[key] != prev:
                live[key] = "B"
        else:
            live[key] = prev
            heapq.heappush(heap, key)

    def skip_nothing(i):
        while True:
            i = text.find("/*", i)
            if i < 0:
                return
            i = block(i)

    def retry(stack):
        # A reading inside guess g failed, so resume the reading g skipped.
        for frame in stack:
            if frame[0] in ("jo", "jc", "jx") and frame[-1] >= 0:
                if frame[-1] not in used:
                    used.add(frame[-1])
                    add(*alts[frame[-1]])

    # A reading in step with valid code ends the file in code with every
    # brace closed. If none does, or the scanner gives up, the rest of the
    # file skips nothing from the earliest point that could be wrong: where a
    # reading broke the syntax, or a guess whose other reading never ran,
    # since a guess can close by accident and leave the scanner out of step.
    budget = STEP_BUDGET * n + 4096
    clean, gave_up, doubt = False, False, [n]
    while heap and not gave_up:
        if len(heap) > MAX_READINGS:
            gave_up = True
            break
        pos, stack = heapq.heappop(heap)
        prev = live.pop((pos, stack))
        while True:
            if pos >= n:
                if stack == (("c", 0),):
                    clean = True
                else:
                    retry(stack)
                break
            budget -= 1
            if budget < 0:
                gave_up = True
                doubt.append(pos)
                break
            nxt = []
            if len(stack) <= MAX_DEPTH:
                nxt = steps[stack[-1][0]](pos, stack, prev)
            if not nxt:
                retry(stack)
                doubt.append(pos)
                break
            if len(nxt) == 1 and not heap:
                pos, stack, prev = nxt[0]
                continue
            for item in nxt:
                add(*item)
            break
    if gave_up or not clean:
        doubt += [k[0] for k in heap]
        doubt += [alts[g][0] for g in range(len(alts)) if g not in used]
        skip_nothing(min(doubt))
    return sorted(spans)


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
markers = re.compile(sys.argv[2], re.I)
out = sys.stdout.buffer
emitted = set()
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
            if (path, n) in emitted or not markers.search(lines[n - 1]):
                continue
            emitted.add((path, n))
            # path NUL line NUL text NL: the same record shape as git grep -z.
            out.write(path.encode("utf-8", "surrogateescape") + b"\0"
                      + str(n).encode() + b"\0"
                      + lines[n - 1].encode("utf-8", "replace") + b"\n")
sys.exit(status)
PY

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
  git rev-parse --verify --quiet "$tree^{tree}" >/dev/null || {
    echo "::error::--tree: not a commit or tree: $(gh_data "$tree")" >&2
    exit 2
  }
  allow=$(git show "$tree:$ALLOW_FILE" 2>/dev/null || true)
else
  allow=$(cat "$ALLOW_FILE" 2>/dev/null || true)
fi

# Hits are NUL-delimited records, "path NUL line NUL text NL", never a
# colon-joined string: git permits ":" in a path, so splitting on ":" would
# let a file named "<allowed path>:x" borrow the allowed path's entry.
work=$(mktemp -d)
rc=0
git grep -z -nIiE "$PATTERN" ${tree:+"$tree"} -- . "${exclude[@]}" > "$work/grep" || rc=$?
if [ "$rc" -gt 1 ]; then
  echo "::error::git grep failed (exit $rc); refusing to pass unchecked" >&2
  exit 1
fi

# Docstrings and block-comment bodies carry no comment leader, so scan them
# separately into the same record shape.
: > "$work/scan"
scan_files > "$work/files"
if [ -s "$work/files" ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "::error::python3 is required to check docstrings and block comments; install it" >&2
    exit 1
  fi
  python3 -c "$PY_SCAN" "$tree" "$MARKERS" < "$work/files" > "$work/scan" || {
    echo "::error::could not scan docstrings and block comments (see above); refusing to pass unchecked" >&2
    exit 1
  }
fi

# Parse the allowlist into parallel arrays (bash 3.2 has no associative ones).
# Every field must carry content: an empty substring would match every line
# of its file, and an empty path or reason leaves the entry unexplained.
allow_path=(); allow_text=(); allow_used=()
bad_entries=0
reject() {
  echo "::error file=$ALLOW_FILE::malformed entry ($1; want '<path>:<substring>  # <reason>'): $(gh_data "$entry")"
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
seen_path=(); seen_line=()
# check_stream <file> <strip-tree>: judge each record against the allowlist.
# Both the path and the line are compared whole, and the substring is matched
# literally: the quotes stop glob matching, and a path must equal the entry's
# path, not prefix it or share a leading part with it. An allowlist entry
# splits on its first ":", so an entry's path never holds one, and a hit in a
# path that does is never allowed.
check_stream() {
  local rpath rline rtext i dup allowed
  while IFS= read -r -d '' rpath && IFS= read -r -d '' rline && IFS= read -r rtext; do
    if [ "$2" = strip ] && [ -n "$tree" ] && [ "${rpath#"$tree":}" != "$rpath" ]; then
      rpath=${rpath#"$tree":}
    fi
    dup=0
    for ((i = 0; i < ${#seen_path[@]}; i++)); do
      if [ "${seen_path[$i]}" = "$rpath" ] && [ "${seen_line[$i]}" = "$rline" ]; then dup=1; break; fi
    done
    [ "$dup" -eq 0 ] || continue
    seen_path+=("$rpath"); seen_line+=("$rline")
    allowed=0
    for ((i = 0; i < ${#allow_path[@]}; i++)); do
      if [ "${allow_path[$i]}" = "$rpath" ] && [[ "$rtext" == *"${allow_text[$i]}"* ]]; then
        allowed=1; allow_used[i]=1
      fi
    done
    if [ "$allowed" -eq 0 ]; then
      echo "::error file=$(gh_prop "$rpath"),line=$rline::comment records review history; keep the reason, drop the provenance: $(gh_data "$rtext")"
      failures=$((failures + 1))
    fi
  done < "$1"
}
check_stream "$work/grep" strip
check_stream "$work/scan" keep

stale=0
for ((i = 0; i < ${#allow_path[@]}; i++)); do
  if [ "${allow_used[$i]}" -eq 0 ]; then
    echo "::error file=$ALLOW_FILE::entry matches nothing, remove it: $(gh_data "${allow_path[$i]}:${allow_text[$i]}")"
    stale=$((stale + 1))
  fi
done

total=$((failures + stale + bad_entries))
if [ "$total" -gt 0 ]; then
  echo "review-comment check: $failures unallowed hit(s), $stale stale and $bad_entries malformed allowlist entr(ies)." >&2
  exit 1
fi
echo "review-comment check: OK (${#allow_path[@]} allowlisted)."
