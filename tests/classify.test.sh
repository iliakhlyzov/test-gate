#!/bin/bash
# Table tests for lib/classify.sh. Run: tests/classify.test.sh
cd "$(dirname "$0")/.." || exit 1
. lib/classify.sh

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

exit $fail
