#!/bin/bash
# Tests for node/gate.js with fake jest/playwright packages. Run: tests/node.test.sh
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
command -v node >/dev/null || { echo "skip: node not found"; exit 0; }

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
# Paths with a space on purpose, like "~/Library/Application Support".
export TEST_GATE_HOME="$TMP_ROOT/App Support/test-gate"
P="$TMP_ROOT/my project"
mkdir -p "$TEST_GATE_HOME" "$P/node_modules/jest/bin" "$P/node_modules/@playwright/test" "$P/node_modules/vitest" "$P/node_modules/.bin"
export TEST_GATE_RULES=/nonexistent TEST_GATE_MIN_DISK_GB=0 TEST_GATE_POLL=0.2
unset TEST_GATE_INSIDE TEST_GATE_NODE npm_lifecycle_event

fake='const fs = require("fs");
const log = process.env.FAKE_LOG;
if (log) fs.appendFileSync(log, "start\n");
console.log("ran inside=" + (process.env.TEST_GATE_INSIDE || "no") + " args=" + process.argv.slice(2).join(" ") + " nodeopts=" + (process.env.NODE_OPTIONS || ""));
setTimeout(() => { if (log) fs.appendFileSync(log, "end\n"); process.exit(Number(process.env.FAKE_EXIT || 0)); }, Number(process.env.FAKE_MS || 100));'
printf '%s\n' "$fake" >"$P/node_modules/jest/bin/jest.js"
printf '%s\n' "$fake" >"$P/node_modules/@playwright/test/cli.js"
printf '%s\n' "$fake" | sed 's/require("fs")/(await import("fs")).default/' >"$P/node_modules/vitest/vitest.mjs"
ln -s ../jest/bin/jest.js "$P/node_modules/.bin/jest"
ln -s ../vitest/vitest.mjs "$P/node_modules/.bin/vitest"
ln -s ../@playwright/test/cli.js "$P/node_modules/.bin/playwright"
echo 'console.log("other ran")' >"$P/other.js"
export NODE_OPTIONS="--require $ROOT/node/gate.js"
cd "$P" || exit 1

fail=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }
queued() { grep -q '\[test-gate\] RUNNING' "$TMP_ROOT/err"; }
run() { "$@" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; }

run node node_modules/.bin/jest
queued && grep -q 'inside=1' "$TMP_ROOT/out" && ok "full jest run goes through tg-run" || bad "full jest: $(cat "$TMP_ROOT/err" "$TMP_ROOT/out")"

run node node_modules/.bin/jest src/a.test.ts
! queued && grep -q 'inside=no' "$TMP_ROOT/out" && ok "jest with a test file runs without the queue" || bad "light jest"

npm_lifecycle_event=test:it run node node_modules/.bin/jest src/a.test.ts
queued && ok "test:it script with a file still uses the queue" || bad "test:it light"

run node node_modules/.bin/jest --testPathPattern=e2e src/a.test.ts
queued && ok "e2e in options makes it heavy" || bad "e2e option"

FAKE_EXIT=3 run node node_modules/.bin/jest
[ $? = 3 ] && ok "exit code passed through" || bad "exit code"

run node other.js
! queued && grep -q 'other ran' "$TMP_ROOT/out" && ok "other node programs are not touched" || bad "other.js"

run node node_modules/.bin/playwright test tests/a.spec.ts
queued && ok "playwright test always uses the queue" || bad "playwright test"

run node node_modules/.bin/playwright install
! queued && ok "playwright install is not queued" || bad "playwright install"

run node node_modules/.bin/jest -w 2
queued && ok "jest -w 2 (maxWorkers) still uses the queue" || bad "jest -w 2"

run node node_modules/.bin/vitest run -w
! queued && ok "vitest -w (watch) is not queued" || bad "vitest -w"

run node node_modules/.bin/jest --watch
! queued && ok "watch mode is not queued" || bad "watch"

TEST_GATE_NODE=off run node node_modules/.bin/jest
! queued && ok "TEST_GATE_NODE=off turns the gate off" || bad "off"

TEST_GATE_TG_RUN=/nonexistent run node node_modules/.bin/jest
! queued && grep -q 'ran inside=no' "$TMP_ROOT/out" && ok "without tg-run the tests run as usual" || bad "no tg-run"

timeout 20 "$ROOT/bin/tg-run" -- node node_modules/.bin/jest >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
[ "$(grep -c '\[test-gate\] RUNNING' "$TMP_ROOT/err")" = 1 ] && ok "tg-run -- jest is queued once (no deadlock)" || bad "double queue: $(cat "$TMP_ROOT/err")"

grep -q 'nodeopts=.*gate.js' "$TMP_ROOT/out" && bad "gate.js is still in NODE_OPTIONS inside tg-run" || ok "tg-run removes the gate from NODE_OPTIONS"

run node node_modules/.bin/vitest run
queued && ok "vitest run uses the queue" || bad "vitest run: $(cat "$TMP_ROOT/err")"
run node node_modules/.bin/vitest run src/a.test.ts
! queued && ok "vitest run with a file is light" || bad "vitest light"
run node node_modules/.bin/vitest watch
! queued && ok "vitest watch is not queued" || bad "vitest watch"

run node --inspect=127.0.0.1:0 node_modules/.bin/jest
! queued && grep -q 'inside=no' "$TMP_ROOT/out" && ok "a run with a debugger is not queued" || bad "inspect"

# The Node process that waits is killed with its pid only (not the group).
FAKE_MS=30000 node node_modules/.bin/jest >/dev/null 2>&1 &
outer=$!
sleep 1.5
kill -TERM $outer; wait $outer 2>/dev/null
sleep 4
pgrep -f "my project/node_modules/.bin/jest" >/dev/null && { bad "test run kept running after its Node parent was killed"; pkill -f "my project/node_modules/.bin/jest"; } || ok "killing the waiting Node process stops the run"
[ -z "$(ls "$TEST_GATE_HOME/slots")" ] && ok "slot freed after the Node parent was killed" || bad "slot still taken"

# Killed while it waits in the queue: it leaves the queue and never runs.
log2="$TMP_ROOT/late.log"
FAKE_MS=2500 node node_modules/.bin/jest >/dev/null 2>&1 &
holder=$!
sleep 0.5
FAKE_LOG=$log2 node node_modules/.bin/jest >/dev/null 2>&1 &
waiter=$!
sleep 1
kill -TERM $waiter; wait $waiter 2>/dev/null
wait $holder
sleep 3
[ ! -s "$log2" ] && ok "a killed waiting run does not start later" || bad "killed waiting run started later"
[ -z "$(ls "$TEST_GATE_HOME/queue")" ] && ok "queue is empty after the waiting run was killed" || bad "ticket left in queue"

log="$TMP_ROOT/order.log"
for _ in 1 2 3; do FAKE_LOG=$log FAKE_MS=700 node node_modules/.bin/jest >/dev/null 2>&1 & sleep 0.1; done
wait
[ "$(tr '\n' ' ' <"$log")" = "start end start end start end " ] && ok "parallel full runs wait for each other" || bad "order: $(tr '\n' ' ' <"$log")"

exit $fail
