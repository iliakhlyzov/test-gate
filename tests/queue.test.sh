#!/bin/bash
# Integration tests for tg-run / tg-status / tg-claude-hook. Run: tests/queue.test.sh
cd "$(dirname "$0")/.." || exit 1
# The path has a space on purpose, like "~/Library/Application Support".
TMP_ROOT=$(mktemp -d)
TEST_GATE_HOME="$TMP_ROOT/App Support/test-gate"
export TEST_GATE_HOME
mkdir -p "$TEST_GATE_HOME"
# Built-in rules only: do not read the rules file of the person who runs the tests.
export TEST_GATE_RULES=/nonexistent
export TEST_GATE_MIN_DISK_GB=0 TEST_GATE_POLL=0.2 TEST_GATE_REPORT_EVERY=1
trap 'rm -rf "$TMP_ROOT"' EXIT
fail=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }

# 1. Three heavy runs in parallel never overlap with one slot.
log=$TEST_GATE_HOME/order.log
for i in 1 2 3; do
  bin/tg-run -- sh -c "echo start$i >>'$log'; sleep 1; echo end$i >>'$log'" 2>>"$TEST_GATE_HOME/err$i" &
  sleep 0.1
done
wait
seq=$(tr '\n' ' ' <"$log")
if [ "$seq" = "start1 end1 start2 end2 start3 end3 " ]; then ok "heavy runs are serialized in FIFO order"; else bad "order: $seq"; fi
grep -q 'QUEUED: position' "$TEST_GATE_HOME/err3" && ok "waiting run reports its queue position" || bad "no QUEUED message"

# 2. Two slots allow two at once.
: >"$log"
for i in 1 2; do TEST_GATE_SLOTS=2 bin/tg-run -- sh -c "echo start$i >>'$log'; sleep 1; echo end$i >>'$log'" 2>/dev/null & done
wait
case "$(head -n 2 "$log" | tr '\n' ' ')" in "start"?" start"?" ") ok "TEST_GATE_SLOTS=2 runs two at once" ;; *) bad "slots=2: $(tr '\n' ' ' <"$log")" ;; esac

# 3. Exit code is passed through.
bin/tg-run -- sh -c 'exit 7' 2>/dev/null
[ $? = 7 ] && ok "exit code passed through" || bad "exit code"

# 4. Leftover background processes are killed after the command ends.
bin/tg-run -- sh -c 'sleep 300 & echo $! > "$1"' sh "$TEST_GATE_HOME/bg.pid" 2>/dev/null
sleep 0.5
if kill -0 "$(cat "$TEST_GATE_HOME/bg.pid")" 2>/dev/null; then bad "leftover still alive"; kill "$(cat "$TEST_GATE_HOME/bg.pid")"; else ok "leftover processes cleaned up"; fi

# 5. Interrupting tg-run kills the command and frees the slot.
bin/tg-run -- sh -c 'sleep 300' 2>/dev/null &
runner=$!
sleep 0.5
[ -n "$(ls "$TEST_GATE_HOME/slots")" ] && ok "slot taken while running" || bad "slot not taken"
kill -TERM $runner; wait $runner 2>/dev/null
sleep 0.3
[ -z "$(ls "$TEST_GATE_HOME/slots")" ] && ok "slot freed after SIGTERM" || bad "slot still taken after SIGTERM"
pgrep -f '^sleep 300' >/dev/null && { bad "command survived SIGTERM"; pkill -f '^sleep 300'; } || ok "command killed on SIGTERM"

# 6. A slot held by a dead process is reclaimed.
printf 'pid=999999\nclass=heavy\nsince=0\ncwd=/\ncmd=ghost\n' >"$TEST_GATE_HOME/slots/1"
timeout 5 bin/tg-run -- true 2>/dev/null && ok "stale slot reclaimed" || bad "stale slot blocked the queue"

# 7. Max wait gives up with 75 and leaves the queue.
bin/tg-run -- sleep 3 2>/dev/null &
sleep 0.3
TEST_GATE_MAX_WAIT=1 bin/tg-run -- true 2>/dev/null
[ $? = 75 ] && ok "max wait exits 75" || bad "max wait"
[ -z "$(ls "$TEST_GATE_HOME/queue")" ] && ok "ticket removed after giving up" || bad "ticket left in queue"
bin/tg-status | grep -q 'running  (1 of 1' && ok "tg-status shows the running job" || bad "tg-status"
bin/tg-status --swiftbar | head -n 1 | grep -q '▶1' && ok "swiftbar title shows running job" || bad "swiftbar title"
wait

# 8. Critical pressure blocks even a free slot; light runs wait too.
TEST_GATE_FAKE_PRESSURE=4 TEST_GATE_MAX_WAIT=1 bin/tg-run -- true 2>"$TEST_GATE_HOME/p.err"
[ $? = 75 ] && grep -q 'memory pressure is critical' "$TEST_GATE_HOME/p.err" && ok "critical pressure blocks heavy runs" || bad "pressure gate"
TEST_GATE_FAKE_PRESSURE=4 TEST_GATE_MAX_WAIT=1 bin/tg-run --light -- true 2>/dev/null
[ $? = 75 ] && ok "critical pressure blocks light runs" || bad "light pressure gate"
TEST_GATE_FAKE_PRESSURE=2 bin/tg-run --light -- true 2>/dev/null && ok "warn pressure lets light runs through" || bad "light at warn"

# 9. Hook decisions.
hook() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)" | bin/tg-claude-hook 2>"$TEST_GATE_HOME/hook.err"; }
hook 'cd app && yarn test'; [ $? = 2 ] && grep -q 'cd app && .*tg-run -- yarn test' "$TEST_GATE_HOME/hook.err" && ok "hook blocks heavy and suggests rewrite" || bad "hook heavy"
hook 'tg-run -- yarn test'; [ $? = 0 ] && ok "hook allows gated" || bad "hook gated"
hook 'yarn test src/a.test.ts'; [ $? = 0 ] && ok "hook allows light" || bad "hook light"
TEST_GATE_FAKE_PRESSURE=4 hook 'yarn test src/a.test.ts'; [ $? = 2 ] && grep -q 'tg-run --light -- yarn test' "$TEST_GATE_HOME/hook.err" && ok "hook blocks light at critical" || bad "hook light critical"
hook 'yarn test --watch'; [ $? = 2 ] && ok "hook blocks watch" || bad "hook watch"
hook 'ls'; [ $? = 0 ] && ok "hook ignores unrelated" || bad "hook ls"
TEST_GATE_HOOK=off hook 'yarn test'; [ $? = 0 ] && ok "TEST_GATE_HOOK=off disables" || bad "hook off"

# 9b. kill -9 on tg-run: the next run cleans up the orphaned command first.
bin/tg-run -- sh -c 'sleep 301' 2>/dev/null &
runner=$!
sleep 0.5
kill -KILL $runner; wait $runner 2>/dev/null
pgrep -f '^sleep 301' >/dev/null && ok "orphan alive right after kill -9 (expected)" || bad "orphan setup"
timeout 10 bin/tg-run -- true 2>/dev/null && ok "next run starts after kill -9" || bad "queue stuck after kill -9"
pgrep -f '^sleep 301' >/dev/null && { bad "orphaned command not cleaned up"; pkill -f '^sleep 301'; } || ok "orphaned command killed before next run"

# 9c. Slot owned by a live process with a different start time (reused pid) is stale.
printf 'pid=%s\npstart=Mon Jan  1 00:00:00 2001\nclass=heavy\nsince=0\ncwd=/\ncmd=old\n' $$ >"$TEST_GATE_HOME/slots/1"
timeout 5 bin/tg-run -- true 2>/dev/null && ok "reused pid does not hold the slot" || bad "reused pid blocks the queue"

# 9d. Run timeout and stdin.
TEST_GATE_MAX_RUN=1 bin/tg-run -- sleep 30 2>"$TEST_GATE_HOME/t.err"
grep -q TIMEOUT "$TEST_GATE_HOME/t.err" && ok "TEST_GATE_MAX_RUN stops long runs" || bad "max run"
echo hello | timeout 5 bin/tg-run -- sh -c 'read x; echo "got:$x"' 2>/dev/null | grep -q '^got:$' && ok "command gets empty stdin" || bad "stdin"
TEST_GATE_HOOK=on hook 'tg-run --light -- yarn test'; [ $? = 2 ] && ok "hook blocks --light misuse" || bad "hook misuse"

# 10. Logger snapshot, mark, summary, measure.
bin/tg-log mark "test freeze" >/dev/null && ok "tg-log mark" || bad "mark"
TEST_GATE_LOG_INTERVAL=1 timeout 2.5 bin/tg-log run; ls "$TEST_GATE_HOME"/logs/samples-*.csv >/dev/null 2>&1 && ok "tg-log run writes samples" || bad "samples"
bin/tg-log summary | grep -q 'samples: ' && ok "tg-log summary" || bad "summary"
bin/tg-measure sh -c 'sleep 2 & sleep 1.5' 2>"$TEST_GATE_HOME/m.err"
grep -q 'peak memory' "$TEST_GATE_HOME/m.err" && ok "tg-measure reports peak" || bad "measure"
grep -q 'LEFTOVERS' "$TEST_GATE_HOME/m.err" && ok "tg-measure detects leftovers" || bad "measure leftovers"

exit $fail
