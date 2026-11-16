# shellcheck shell=bash
# Classifies a shell command line by how heavy it is for the machine.
#
#   tg_classify "<command line>"  ->  prints "<kind>\t<segment>"
#
# kind (most severe wins across `;`, `&&`, `||`, `|` segments):
#   watch  - a test runner in watch mode (never finishes)
#   heavy  - full test suite, e2e/Playwright, integration tests
#   light  - test runner pointed at explicit test files (unit tests only)
#   gated  - already wrapped in tg-run
#   none   - nothing test-related
#
# Heuristics only. Tunable with:
#   TEST_GATE_HEAVY_SCRIPTS  regex for package.json script names that run tests
#   TEST_GATE_ALWAYS_HEAVY   regex: if a segment matches, never treat it as light

TG_RUNNERS='^(jest|vitest|mocha|ava|playwright|cypress)$'
TG_HEAVY_SCRIPTS_DEFAULT='^(test|tests|e2e|integration|ci|(test|e2e|integration)[:-].*)$'
TG_ALWAYS_HEAVY_DEFAULT='e2e|integration|playwright|cypress|testcontainers'
TG_MAKE_TARGETS='^(test|tests|e2e|check|integration|ci)$'

tg_kind_rank() {
  case "$1" in watch) echo 4 ;; heavy) echo 3 ;; light) echo 2 ;; gated) echo 1 ;; *) echo 0 ;; esac
}

# Classify a single simple command (no separators).
tg_classify_segment() {
  local seg=$1 w1 name="" make_target="" a has_file=0 watch=0 sub
  local heavy_scripts=${TEST_GATE_HEAVY_SCRIPTS:-$TG_HEAVY_SCRIPTS_DEFAULT}
  local always_heavy=${TEST_GATE_ALWAYS_HEAVY:-$TG_ALWAYS_HEAVY_DEFAULT}

  set -f
  # shellcheck disable=SC2086
  set -- $seg
  set +f

  # Skip env assignments and transparent prefixes.
  while [ $# -gt 0 ]; do
    case "$1" in
      env | time | command | exec | nohup) shift ;;
      nice) shift; [ "${1:-}" = -n ] && shift 2 ;;
      [A-Za-z_]*=*) shift ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || { echo none; return; }

  w1=${1##*/}
  shift
  case "$w1" in
    tg-run) echo gated; return ;;
    npx | bunx)
      while [ $# -gt 0 ]; do case "$1" in -*) shift ;; *) break ;; esac; done
      name=${1:-}; name=${name##*/}; [ $# -gt 0 ] && shift
      ;;
    yarn | npm | pnpm | bun)
      while [ $# -gt 0 ]; do case "$1" in -*) shift ;; *) break ;; esac; done
      sub=${1:-}; [ $# -gt 0 ] && shift
      case "$sub" in
        run | run-script)
          while [ $# -gt 0 ]; do case "$1" in -*) shift ;; *) break ;; esac; done
          name=${1:-}; [ $# -gt 0 ] && shift ;;
        exec | x | dlx)
          name=${1:-}; name=${name##*/}; [ $# -gt 0 ] && shift ;;
        t) name="test" ;;
        *)
          # npm only runs custom scripts via "npm run"; "npm test" is the exception.
          if [ "$w1" = npm ] && [ "$sub" != test ]; then name=""; else name=$sub; fi ;;
      esac
      ;;
    make) make_target=${1:-} ;;
    *) name=$w1 ;;
  esac

  # Runner-specific subcommands that are not test runs.
  case "$name" in
    playwright) [ "${1:-}" = test ] || { echo none; return; } ;;
    cypress) [ "${1:-}" = run ] || { echo none; return; } ;;
  esac

  if [ -n "$make_target" ]; then
    if [[ "$make_target" =~ $TG_MAKE_TARGETS ]]; then echo heavy; else echo none; fi
    return
  fi
  [ -n "$name" ] || { echo none; return; }
  if ! [[ "$name" =~ $TG_RUNNERS ]] && ! [[ "$name" =~ $heavy_scripts ]]; then
    echo none; return
  fi

  for a in "$@"; do
    case "$a" in
      --watch | --watchAll | --watch=true | --watchAll=true) watch=1 ;;
      -*) ;;
      *.test.* | *.spec.* | *.ts | *.tsx | *.js | *.jsx | *.mjs | *.cjs | *.mts | *.cts) has_file=1 ;;
    esac
  done
  # vitest without "run" watches when attached to a terminal; agents usually are not.
  if [ $watch = 1 ]; then echo watch; return; fi
  if [[ "$name $seg" =~ $always_heavy ]]; then echo heavy; return; fi
  if [ $has_file = 1 ]; then echo light; else echo heavy; fi
}

tg_classify() {
  local cmd=$1 seg kind best=none best_seg="" segs
  # Drop quoted strings (commit messages, grep patterns) and fd redirections,
  # then split into simple commands.
  segs=$(printf '%s\n' "$cmd" | awk '{
    gsub(/"[^"]*"/, "\"\""); gsub(/\047[^\047]*\047/, "\047\047")
    gsub(/[0-9]*>&[0-9-]+/, " ")
    gsub(/&&|\|\||[;|&()`]/, "\n")
    print }')
  while IFS= read -r seg; do
    seg=$(printf '%s' "$seg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -n "$seg" ] || continue
    kind=$(tg_classify_segment "$seg")
    if [ "$(tg_kind_rank "$kind")" -gt "$(tg_kind_rank "$best")" ]; then
      best=$kind; best_seg=$seg
    fi
  done <<EOF
$segs
EOF
  printf '%s\t%s\n' "$best" "$best_seg"
}
