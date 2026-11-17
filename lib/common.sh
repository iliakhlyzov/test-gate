# shellcheck shell=bash
# Shared helpers for test-gate.
# Must stay compatible with macOS /bin/bash 3.2 and BSD userland:
# no associative arrays, no mapfile, no ${x,,}, no GNU-only flags.

TG_OS=$(uname -s)

if [ -n "${TEST_GATE_HOME:-}" ]; then
  TG_HOME=$TEST_GATE_HOME
elif [ "$TG_OS" = Darwin ]; then
  TG_HOME="$HOME/Library/Application Support/test-gate"
else
  TG_HOME="${XDG_STATE_HOME:-$HOME/.local/state}/test-gate"
fi
TG_LOGS="$TG_HOME/logs"
mkdir -p "$TG_HOME/queue" "$TG_HOME/slots" "$TG_HOME/light" "$TG_LOGS"

tg_now() { date +%s; }
tg_ts() { date '+%Y-%m-%dT%H:%M:%S'; }

tg_fmt_dur() {
  local s=${1:-0}
  if [ "$s" -ge 3600 ]; then printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
  elif [ "$s" -ge 60 ]; then printf '%dm%02ds' $((s / 60)) $((s % 60))
  else printf '%ds' "$s"; fi
}

tg_fmt_gb() { awk -v m="${1:-0}" 'BEGIN { printf "%.1f GB", m / 1024 }'; }

# ---------------------------------------------------------------- memory & disk

# macOS memory pressure: 1 = normal, 2 = warn, 4 = critical.
tg_pressure_level() {
  local v=""
  if [ -n "${TEST_GATE_FAKE_PRESSURE:-}" ]; then
    v=$TEST_GATE_FAKE_PRESSURE
  elif [ "$TG_OS" = Darwin ]; then
    v=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)
  elif [ -r /proc/pressure/memory ]; then
    # Linux approximation (development only).
    v=$(awk '/^some/ { split($2, a, "="); x = a[2] + 0; print (x >= 40) ? 4 : ((x >= 10) ? 2 : 1) }' /proc/pressure/memory)
  fi
  printf '%s\n' "${v:-1}"
}

tg_pressure_name() {
  case "$1" in 1) echo normal ;; 2) echo warn ;; 4) echo critical ;; *) echo "unknown($1)" ;; esac
}

tg_ram_mb() {
  if [ "$TG_OS" = Darwin ]; then
    sysctl -n hw.memsize 2>/dev/null | awk '{ printf "%d\n", $1 / 1048576 }'
  else
    awk '/^MemTotal/ { printf "%d\n", $2 / 1024 }' /proc/meminfo
  fi
}

# Share of memory the kernel considers available, in percent.
tg_mem_free_pct() {
  if [ "$TG_OS" = Darwin ]; then
    sysctl -n kern.memorystatus_level 2>/dev/null || echo 0
  else
    awk '/^MemTotal/ { t = $2 } /^MemAvailable/ { a = $2 } END { printf "%d\n", t ? a * 100 / t : 0 }' /proc/meminfo
  fi
}

tg_swap_used_mb() {
  if [ "$TG_OS" = Darwin ]; then
    # "total = 2048.00M  used = 1024.50M  free = 1023.50M  (encrypted)"
    sysctl -n vm.swapusage 2>/dev/null | awk '{
      for (i = 1; i <= NF; i++) if ($i == "used") {
        v = $(i + 2); u = substr(v, length(v)); n = v + 0
        if (u == "G") n *= 1024
        printf "%d\n", n; exit
      } }'
  else
    awk '/^SwapTotal/ { t = $2 } /^SwapFree/ { f = $2 } END { printf "%d\n", (t - f) / 1024 }' /proc/meminfo
  fi
}

tg_compressed_mb() {
  if [ "$TG_OS" = Darwin ]; then
    vm_stat 2>/dev/null | awk '
      /page size of/ { ps = $8 }
      /Pages occupied by compressor/ { c = $5; sub(/\./, "", c) }
      END { printf "%d\n", c * ps / 1048576 }'
  else
    echo 0
  fi
}

# Free space on the volume that holds swap files (macOS) or on /.
tg_disk_free_gb() {
  local p=/
  [ -d /System/Volumes/VM ] && p=/System/Volumes/VM
  df -Pk "$p" 2>/dev/null | awk 'NR == 2 { printf "%d\n", $4 / 1048576 }'
}

# Prints a reason why a run must not start now, or nothing if it may start.
# $1 = highest acceptable pressure level (1, 2 or 4).
tg_block_reason() {
  local p d min=${TEST_GATE_MIN_DISK_GB:-15}
  p=$(tg_pressure_level)
  if [ "$p" -gt "$1" ]; then
    echo "memory pressure is $(tg_pressure_name "$p")"
    return
  fi
  d=$(tg_disk_free_gb)
  # Unknown free space (df failed) never blocks.
  if [ -n "$d" ] && [ "$d" -lt "$min" ]; then
    echo "only ${d} GB free on the swap disk (need ${min} GB, TEST_GATE_MIN_DISK_GB)"
  fi
}

# ------------------------------------------------------------------- processes

# node_n,node_mb,browser_n,browser_mb,vm_mb,top1,top1_mb,top2,top2_mb,top3,top3_mb
# RSS-based; "top" groups processes by name.
tg_proc_categories() {
  ps -axo rss=,comm= 2>/dev/null | awk '
    function clean(s) { gsub(/[,;"]/, "_", s); return s }
    {
      rss = $1; $1 = ""; name = substr($0, 2); sub(/.*\//, "", name)
      mb = rss / 1024; l = tolower(name)
      if (l ~ /^node[0-9.]*$/) { nn++; nm += mb }
      else if (l ~ /chrom|headless_shell|chrome for testing|firefox|webkit|playwright/) { bn++; bm += mb }
      if (l ~ /virtualization|qemu|vpnkit|docker|orbstack|limactl|colima|podman|krunkit/) vm += mb
      agg[name] += mb
    }
    END {
      for (k in agg) {
        v = agg[k]
        if (v > t1v) { t3 = t2; t3v = t2v; t2 = t1; t2v = t1v; t1 = k; t1v = v }
        else if (v > t2v) { t3 = t2; t3v = t2v; t2 = k; t2v = v }
        else if (v > t3v) { t3 = k; t3v = v }
      }
      printf "%d,%d,%d,%d,%d,%s,%d,%s,%d,%s,%d\n", nn, nm, bn, bm, vm,
        clean(t1), t1v, clean(t2), t2v, clean(t3), t3v
    }'
}

# jest_runs,playwright_runs (main processes only, workers excluded)
tg_runner_counts() {
  ps -axo command= 2>/dev/null | awk '
    /awk|grep|processChild|jest-worker|run-driver|tg-log/ { next }
    /(^|[\/ ])jest(\.js)?( |$)|jest-cli\/bin/ { j++ }
    /playwright(\.js)? test( |$)|playwright\/cli\.js test/ { p++ }
    END { printf "%d,%d\n", j, p }'
}

tg_count_files() { find "$1" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' '; }

tg_group_alive() { kill -0 -- "-$1" 2>/dev/null; }

tg_group_count() {
  ps -axo pgid= 2>/dev/null | awk -v g="$1" '$1 == g { n++ } END { print n + 0 }'
}

# TERM the whole process group, then KILL whatever is left after ~5s.
tg_kill_group() {
  local g=$1 i=0
  [ -n "$g" ] || return 0
  tg_group_alive "$g" || return 0
  kill -TERM -- "-$g" 2>/dev/null
  while tg_group_alive "$g" && [ $i -lt 20 ]; do sleep 0.25; i=$((i + 1)); done
  tg_group_alive "$g" && kill -KILL -- "-$g" 2>/dev/null
  return 0
}

# Prints NODE_OPTIONS without "--require .../test-gate/node/gate.js".
tg_strip_gate() {
  local out="" w skip=0
  set -f
  # shellcheck disable=SC2086
  for w in $1; do
    if [ $skip = 1 ]; then
      skip=0
      case "$w" in *test-gate*/node/gate.js) continue ;; *) out="$out --require $w"; continue ;; esac
    fi
    case "$w" in
      --require | -r) skip=1 ;;
      --require=*test-gate*/node/gate.js | -r=*test-gate*/node/gate.js) ;;
      *) out="$out $w" ;;
    esac
  done
  set +f
  printf '%s\n' "${out# }"
}

# --------------------------------------------------------------- queue state

# Each queue ticket / slot / light registration is a small key=value file.
tg_field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1; }

# Start time of a process; together with the pid it identifies the process
# even after the pid is reused.
tg_pstart() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' '; }

# $1 pid, $2 start time recorded earlier (optional)
tg_alive() {
  [ -n "$1" ] && kill -0 "$1" 2>/dev/null || return 1
  [ -z "${2:-}" ] || [ "$(tg_pstart "$1")" = "$2" ]
}

# mkdir-based mutex. The owner's pid is stored inside; an abandoned mutex is
# broken only when its owner is dead, by renaming it (only one breaker wins).
TG_MUTEX_HELD=0
tg_mutex_lock() {
  local i=0 owner
  [ -w "$TG_HOME" ] || { echo "test-gate: $TG_HOME is not writable" >&2; exit 70; }
  while ! mkdir "$TG_HOME/mutex" 2>/dev/null; do
    i=$((i + 1))
    if [ $((i % 20)) = 0 ]; then
      owner=$(cat "$TG_HOME/mutex/pid" 2>/dev/null)
      # No pid after ~10s means the owner died between mkdir and writing it.
      if { [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; } || { [ -z "$owner" ] && [ $i -ge 100 ]; }; then
        mv "$TG_HOME/mutex" "$TG_HOME/mutex.dead.$$" 2>/dev/null && rm -rf "$TG_HOME/mutex.dead.$$"
        i=0
      fi
    fi
    sleep 0.1
  done
  echo $$ >"$TG_HOME/mutex/pid"
  TG_MUTEX_HELD=1
}
tg_mutex_unlock() {
  if [ "$TG_MUTEX_HELD" = 1 ] && [ "$(cat "$TG_HOME/mutex/pid" 2>/dev/null)" = $$ ]; then
    rm -rf "$TG_HOME/mutex"
  fi
  TG_MUTEX_HELD=0
}

# Drop entries whose owner is gone (crashed agent, closed session, kill -9).
# If the owner died but its command's process group still runs, kill the
# group first: otherwise the next heavy run would start on top of it.
tg_cleanup_stale() {
  local d f p g
  for d in queue slots light; do
    for f in "$TG_HOME/$d"/*; do
      [ -f "$f" ] || continue
      p=$(tg_field "$f" pid)
      [ -n "$p" ] || continue # being written right now
      tg_alive "$p" "$(tg_field "$f" pstart)" && continue
      g=$(tg_field "$f" pgid)
      [ -n "$g" ] && tg_kill_group "$g"
      rm -f "$f"
    done
  done
}

# "<cmd> (pid 123, 4m12s, ~/proj)"
tg_describe() {
  local f=$1 since cwd
  since=$(tg_field "$f" since)
  cwd=$(tg_field "$f" cwd)
  case "$cwd" in "$HOME"*) cwd="~${cwd#"$HOME"}" ;; esac
  printf '%s (pid %s, %s, %s)' "$(tg_field "$f" cmd)" "$(tg_field "$f" pid)" \
    "$(tg_fmt_dur $(($(tg_now) - ${since:-0})))" "$cwd"
}
