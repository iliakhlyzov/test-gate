#!/bin/bash
# Table tests for lib/classify.sh. Run: tests/classify.test.sh
cd "$(dirname "$0")/.." || exit 1
. lib/classify.sh
# Built-in rules only: do not read the rules file of the person who runs the tests.
export TEST_GATE_RULES=/nonexistent

fail=0
check() { # expected kind, command
  local got
  got=$(tg_classify "$2"); got=${got%%	*}
  if [ "$got" = "$1" ]; then printf 'ok    %-6s %s\n' "$1" "$2"
  else printf 'FAIL  want %-6s got %-6s %s\n' "$1" "$got" "$2"; fail=1; fi
}

check heavy 'yarn test'
check heavy 'npm test'
check heavy 'npm t'
check heavy 'pnpm test'
check heavy 'npx jest'
check heavy 'node_modules/.bin/jest --ci'
check heavy 'FOO=1 yarn test'
check heavy 'cd app && yarn test'
check heavy 'yarn test 2>&1 | tail -50'
check heavy 'npm run test:e2e'
check heavy 'yarn playwright test'
check heavy 'npx playwright test tests/login.spec.ts'
check heavy 'yarn test:integration src/db.test.ts'
check heavy 'pnpm exec vitest run'
check heavy 'make test'
check heavy 'jest --watchAll=false'
check heavy 'tg-run -- yarn test && yarn test:e2e'
check light 'yarn test src/a.test.ts'
check light 'npx jest src/foo.spec.tsx'
check light 'pnpm vitest run src/a.test.ts'
check light 'npm run test:unit -- src/x.test.ts'
check light 'yarn jest src/a.test.ts -t "renders title"'
check watch 'yarn test --watch'
check watch 'npx jest --watchAll'
check gated 'tg-run -- yarn test'
check gated 'cd app && tg-run --light -- yarn test a.test.ts'
check heavy 'pnpm --filter web test'
check heavy 'pnpm -F web test'
check heavy 'yarn --cwd app test'
check heavy 'npm --prefix app test'
check heavy 'npm -w pkg test'
check heavy 'yarn workspace app test'
check heavy 'nx test app'
check heavy 'npx nx run app:test'
check heavy 'turbo run test'
check heavy 'yarn turbo test'
check heavy 'lerna run test'
check heavy 'make -j4 test'
check heavy 'make -C app test'
check heavy 'timeout 600 yarn test'
check heavy 'caffeinate -i yarn test'
check heavy 'if yarn test; then echo ok; fi'
check heavy 'for p in a b; do yarn test; done'
check heavy '{ yarn test; }'
check heavy '! yarn test'
check heavy 'bash -c "cd app && yarn test"'
check heavy "sh -c 'npx jest'"
check heavy 'node node_modules/.bin/jest'
check heavy 'node --test'
check heavy 'yarn test --config jest.config.js'
check heavy 'yarn test --setupFiles ./setup.ts'
check heavy 'yarn --cwd api test:it __tests__/db.test.ts'
check heavy 'yarn test:it'
check heavy 'npm run test-it -- src/a.test.ts'
check heavy 'yarn test:it:db src/a.test.ts'
check light 'yarn test:ci __tests__/split-it.test.ts'
check light 'yarn test:unit src/edit.test.ts'
check light 'yarn test src/integration-utils.test.ts'
check light 'yarn test \
  src/a.test.ts'
check watch 'yarn test:watch'
check watch 'tg-run -- yarn test:watch'
check watch 'tg-run -- yarn test --watch'
check misuse 'tg-run --light -- yarn test'
check gated 'tg-run -- bash -c "cd app && yarn test"'
check none "git commit -m \"\$(cat <<'MSG'
yarn test now passes
MSG
)\""
check none 'cat > ci.yml <<YML
run: npm test
YML'
check none 'npx playwright install chromium'
check none 'git commit -m "fix: yarn test was flaky"'
check none 'grep -r jest src'
check none 'cat jest.config.js'
check none 'yarn add -D jest'
check none 'npm install'
check none 'yarn lint'
check none 'yarn build'
check none 'ls -la'
check none 'echo done; ls'

# User rules file.
rules=$(mktemp)
trap 'rm -f "$rules"' EXIT
cat >"$rules" <<'RULES'
# my rules
light test:unit

heavy ^yarn verify
heavy (^| )lint:types
light test:ci .*/smoke/
nonsense line is ignored
RULES
export TEST_GATE_RULES=$rules
check light 'yarn test:unit'
check light 'cd api && yarn test:unit'
check heavy 'yarn verify'
check heavy 'yarn lint:types'
check light 'yarn test:ci src/smoke/'
check heavy 'yarn test:ci'
check watch 'yarn test:unit --watch'
check gated 'tg-run --light -- yarn test:unit'
check misuse 'tg-run --light -- yarn test'
check gated 'tg-run -- yarn verify'
check none 'git commit -m "yarn verify"'

check heavy 'CI=1 yarn verify'
check heavy 'time yarn  verify'
check heavy 'FOO="a b" timeout 60 yarn verify'
check light 'yarn exec test:unit'

# Windows line ends and no newline at the end of the file.
printf 'heavy ^yarn verify$\r\nlight ^jest$\r\nheavy ^yarn lint:all$' >"$rules"
check heavy 'yarn verify'
check light 'npx jest'
check heavy 'yarn lint:all'
out=$(bin/tg-classify "npx jest")
case "$out" in *"kind:  light"*"rule:  light ^jest\$"*) echo "ok    tg-classify shows a rule that decided an inner command" ;; *) echo "FAIL  tg-classify inner: $out"; fail=1 ;; esac
printf 'light .*\n' >"$rules"
out=$(bin/tg-classify "yarn watch:css")
case "$out" in *"kind:  light"*) echo "ok    light .* changes none to light" ;; *) echo "FAIL  light .*: $out"; fail=1 ;; esac
out=$(bin/tg-classify "yarn test --watch")
case "$out" in *"kind:  watch"*"rule:  built-in"*) echo "ok    rules never change watch" ;; *) echo "FAIL  watch with rule: $out"; fail=1 ;; esac
printf 'heavy ^yarn verify\n' >"$rules"

out=$(bin/tg-classify "yarn verify")
case "$out" in *"rule:  heavy ^yarn verify"*) echo "ok    tg-classify shows the user rule" ;; *) echo "FAIL  tg-classify: $out"; fail=1 ;; esac
out=$(bin/tg-classify "yarn test")
case "$out" in *"rule:  built-in"*"means: blocked unless"*) echo "ok    tg-classify shows built-in rule" ;; *) echo "FAIL  tg-classify: $out"; fail=1 ;; esac

exit $fail
