# shellcheck shell=bash
# Decides how heavy a shell command is for the machine.
#
#   tg_classify "<command line>"  ->  prints "<kind><TAB><part of the command>"
#
# kind (the most serious one wins when the command has several parts):
#   watch   - a test runner in watch mode (it never ends)
#   misuse  - `tg-run --light` used for a heavy run
#   heavy   - full test suite, e2e/Playwright, integration tests
#   light   - a test runner with explicit test files (*.test.*, *.spec.*)
#   gated   - already wrapped in tg-run
#   none    - nothing about tests
#
# This is a heuristic. Extend it with (regex, added to the defaults):
#   TEST_GATE_HEAVY_SCRIPTS_EXTRA   more package.json script names that run tests, e.g. '^build$'
#   TEST_GATE_ALWAYS_HEAVY_EXTRA    more words that make a run heavy even with test files

TG_RUNNERS='^(jest|vitest|mocha|ava|playwright|cypress)$'
TG_HEAVY_SCRIPTS='^(test|tests|e2e|integration|ci|(test|e2e|integration)[:-].*)$'
TG_ALWAYS_HEAVY='e2e|integration|playwright|cypress|testcontainers'
TG_WATCH_SCRIPTS='(^|[:-])watch($|[:-])'
TG_MAKE_TARGETS='^(test|tests|e2e|check|integration|ci)$'

tg_kind_rank() {
  case "$1" in watch) echo 5 ;; misuse) echo 4 ;; heavy) echo 3 ;; light) echo 2 ;; gated) echo 1 ;; *) echo 0 ;; esac
}

# Classify one simple command (no ; && || | in it).
tg_classify_segment() {
  local seg=$1 w1 name="" sub a has_file=0 watch=0 light_flag=0 inner rest=""
  local heavy_scripts=$TG_HEAVY_SCRIPTS always_heavy=$TG_ALWAYS_HEAVY
  [ -n "${TEST_GATE_HEAVY_SCRIPTS_EXTRA:-}" ] && heavy_scripts="$heavy_scripts|$TEST_GATE_HEAVY_SCRIPTS_EXTRA"
  [ -n "${TEST_GATE_ALWAYS_HEAVY_EXTRA:-}" ] && always_heavy="$always_heavy|$TEST_GATE_ALWAYS_HEAVY_EXTRA"

  set -f
  # shellcheck disable=SC2086
  set -- $seg
  set +f

  # Skip env assignments, shell keywords and wrapper commands.
  while [ $# -gt 0 ]; do
    case "$1" in
      env | time | command | exec | nohup | if | then | else | elif | do | while | until | '{' | '!') shift ;;
      nice) shift; [ "${1:-}" = -n ] && shift 2 ;;
      timeout | gtimeout)
        shift
        while [ $# -gt 0 ]; do case "$1" in -s | -k) shift 2 ;; -*) shift ;; *) break ;; esac; done
        [ $# -gt 0 ] && shift ;; # the duration
      caffeinate | sudo)
        shift
        while [ $# -gt 0 ]; do case "$1" in -u | -g | -w | -t) shift 2 ;; -*) shift ;; *) break ;; esac; done ;;
      [A-Za-z_]*=*) shift ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || { echo none; return; }

  w1=${1##*/}
  shift
  case "$w1" in
    tg-run)
      while [ $# -gt 0 ]; do
        case "$1" in --light) light_flag=1; shift ;; --heavy) shift ;; --) shift; break ;; *) break ;; esac
      done
      inner=$(tg_classify_segment "$*")
      if [ "$inner" = watch ]; then echo watch
      elif [ $light_flag = 1 ] && [ "$inner" = heavy ]; then echo misuse
      else echo gated; fi
      return ;;
    npx | bunx)
      while [ $# -gt 0 ]; do case "$1" in -p | --package) shift 2 ;; -*) shift ;; *) break ;; esac; done
      tg_classify_segment "$*"; return ;;
    node)
      for a in "$@"; do [ "$a" = --test ] && { echo heavy; return; }; done
      while [ $# -gt 0 ]; do case "$1" in -*) shift ;; *) break ;; esac; done
      [ $# -gt 0 ] || { echo none; return; }
      a=${1##*/}; a=${a%.js}
      if [[ "$a" =~ $TG_RUNNERS ]]; then shift; tg_classify_segment "$a $*"; else echo none; fi
      return ;;
    yarn | npm | pnpm | bun)
      while [ $# -gt 0 ]; do
        case "$1" in
          --filter | -F | --cwd | --prefix | -w | --workspace | -C | --dir) shift 2 ;;
          -*) shift ;;
          *) break ;;
        esac
      done
      sub=${1:-}
      [ $# -gt 0 ] && shift
      if [ "$sub" = workspace ]; then # yarn workspace <name> <script>
        [ $# -gt 0 ] && shift
        sub=${1:-}; [ $# -gt 0 ] && shift
      fi
      case "$sub" in
        run | run-script)
          while [ $# -gt 0 ]; do case "$1" in -*) shift ;; *) break ;; esac; done
          name=${1:-}; [ $# -gt 0 ] && shift ;;
        exec | x | dlx)
          tg_classify_segment "$*"; return ;;
        nx | turbo | lerna)
          tg_classify_segment "$sub $*"; return ;;
        t) name="test" ;;
        *)
          # npm runs custom scripts only with "npm run"; "npm test" is the exception.
          if [ "$w1" = npm ] && [ "$sub" != test ]; then name=""; else name=$sub; fi ;;
      esac
      ;;
    nx | turbo | lerna)
      [ "${1:-}" = run ] || [ "${1:-}" = run-many ] && shift
      while [ $# -gt 0 ]; do case "$1" in -*) shift ;; *) break ;; esac; done
      name=${1:-}; name=${name##*:} # nx run app:test -> test
      [ $# -gt 0 ] && shift ;;
    make | gmake)
      while [ $# -gt 0 ]; do
        case "$1" in -C | -f | --directory | --file) shift 2 ;; -* | *=*) shift ;; *) break ;; esac
      done
      if [[ "${1:-}" =~ $TG_MAKE_TARGETS ]]; then echo heavy; else echo none; fi
      return ;;
    *) name=$w1 ;;
  esac

  # Runner subcommands that do not run tests.
  case "$name" in
    playwright) [ "${1:-}" = test ] || { echo none; return; } ;;
    cypress) [ "${1:-}" = run ] || { echo none; return; } ;;
  esac

  [ -n "$name" ] || { echo none; return; }
  if [[ "$name" =~ $TG_WATCH_SCRIPTS ]] && [[ "$name" =~ test|jest|vitest|spec ]]; then
    echo watch; return
  fi
  if ! [[ "$name" =~ $TG_RUNNERS ]] && ! [[ "$name" =~ $heavy_scripts ]]; then
    echo none; return
  fi

  for a in "$@"; do
    case "$a" in
      --watch | --watchAll | --watch=true | --watchAll=true) watch=1 ;;
      -*) rest="$rest $a" ;;
      *.test.* | *.spec.* | *__tests__/*) has_file=1 ;;
      *) rest="$rest $a" ;;
    esac
  done
  if [ $watch = 1 ]; then echo watch; return; fi
  # Words like e2e/integration count in the script name and in options, not in file names.
  if [[ "$name $rest" =~ $always_heavy ]]; then echo heavy; return; fi
  if [ $has_file = 1 ]; then echo light; else echo heavy; fi
}

# Turns a full command line into simple commands, one per line:
# joins "\" line breaks, drops heredoc bodies, adds the scripts of
# `bash -c '...'` as extra lines, removes quoted text and fd redirections,
# and splits on ; && || | & ( ) and backticks.
tg_split_command() {
  printf '%s\n' "$1" | awk '
    function simple(x) {
      gsub(/"[^"]*"/, "\"\"", x); gsub(/\047[^\047]*\047/, "\047\047", x)
      gsub(/[0-9]*>&[0-9-]+/, " ", x)
      gsub(/&&|\|\||[;|&()`{}]/, "\n", x)
      return x
    }
    {
      line = $0
      if (hd != "") { t = line; gsub(/^[ \t]+|[ \t]+$/, "", t); if (t == hd) hd = ""; next }
      if (cont != "") { line = cont " " line; cont = "" }
      if (line ~ /\\$/) { cont = substr(line, 1, length(line) - 1); next }
      if (match(line, /<<-?[ ]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) {
        hd = substr(line, RSTART, RLENGTH); gsub(/^<<-?[ ]*|["\047]/, "", hd)
        line = substr(line, 1, RSTART - 1) " " substr(line, RSTART + RLENGTH)
      }
      out = simple(line)
      r = line
      while (match(r, /(bash|sh|zsh)[ ]+-[a-z]*c[ ]+("[^"]*"|\047[^\047]*\047)/)) {
        before = substr(r, 1, RSTART - 1); m = substr(r, RSTART, RLENGTH)
        r = substr(r, RSTART + RLENGTH)
        if (before ~ /tg-run/) continue # tg-run -- bash -c "..." is already gated
        sub(/^[a-z]+[ ]+-[a-z]*c[ ]+/, "", m)
        out = out "\n" simple(substr(m, 2, length(m) - 2))
      }
      print out
    }
    END { if (cont != "") print simple(cont) }'
}

tg_classify() {
  local seg kind best=none best_seg=""
  while IFS= read -r seg; do
    seg=$(printf '%s' "$seg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -n "$seg" ] || continue
    kind=$(tg_classify_segment "$seg")
    if [ "$(tg_kind_rank "$kind")" -gt "$(tg_kind_rank "$best")" ]; then
      best=$kind
      best_seg=$seg
    fi
  done <<EOF
$(tg_split_command "$1")
EOF
  printf '%s\t%s\n' "$best" "$best_seg"
}
