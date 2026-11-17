// test-gate for Node: puts heavy Jest, Vitest and Playwright runs into the
// tg-run queue, whoever starts them (any agent, an IDE or you).
//
// Load it in every Node process, for example in ~/.zshenv:
//   export NODE_OPTIONS="--require $HOME/.test-gate/node/gate.js"
//
// What it does in each Node process:
//   - not a test runner (a server, a linter, a jest worker): returns at once;
//   - a light run (explicit test files, unit tests only): returns, no queue;
//   - a heavy run: starts the same command again through `tg-run --`,
//     waits for it, and exits with its exit code.
//
// Settings:
//   TEST_GATE_NODE=off   turn the gate off
//   TEST_GATE_INSIDE=1   set by tg-run for its command, so it is not queued twice
//   TEST_GATE_PARENT     set by this file for tg-run: if this process is killed,
//                        tg-run leaves the queue or stops the run
//
// If anything goes wrong (no tg-run, an error here), the test runs as usual.
'use strict';

(function gate() {
  try {
    const env = process.env;
    if (env.TEST_GATE_INSIDE === '1' || env.TEST_GATE_NODE === 'off') return;
    if (!require('worker_threads').isMainThread) return;
    // A debugger is attached to this process; a second process would break it.
    if (process.execArgv.some((a) => /^--inspect/.test(a)) || env.VSCODE_INSPECTOR_OPTIONS) return;

    const fs = require('fs');
    const path = require('path');

    const main = process.argv[1];
    if (!main) return;
    let real;
    try {
      real = fs.realpathSync(main).split(path.sep).join('/');
    } catch (e) {
      return;
    }

    let runner = '';
    if (/\/jest(-cli)?\/bin\/jest(\.js)?$/.test(real)) runner = 'jest';
    else if (/\/vitest\/vitest\.mjs$/.test(real)) runner = 'vitest';
    else if (/\/(@playwright\/test|playwright(-core)?)\/cli\.js$/.test(real)) runner = 'playwright';
    if (!runner) return;

    const args = process.argv.slice(2);

    // Commands that do not run tests, or never end.
    if (runner === 'playwright' && args[0] !== 'test') return;
    const passFlags = ['--version', '-v', '--help', '-h', '--listTests', '--showConfig', '--clearCache',
      '--watch', '--watchAll', '--watch=true', '--watchAll=true', '--ui'];
    if (args.some((a) => passFlags.indexOf(a) !== -1)) return;
    // -w is watch in vitest, but --maxWorkers in jest.
    if (runner === 'vitest' && args.indexOf('-w') !== -1) return;
    // Plain `vitest` in a terminal is watch mode.
    if (runner === 'vitest' && (args[0] === 'watch' || args[0] === 'dev' ||
      (args[0] !== 'run' && args.indexOf('--run') === -1 && process.stdin.isTTY && !env.CI))) return;

    // Light run: explicit test files, and nothing says e2e or integration.
    // npm_lifecycle_event is the package.json script name (test:it, test:e2e...).
    // Same words as TG_ALWAYS_HEAVY in lib/classify.sh.
    const heavyWords = /e2e|integration|playwright|cypress|testcontainers|(^|[:\-\/=])it([:\-\/=]|$)/;
    const script = env.npm_lifecycle_event || '';
    const files = args.filter((a) => a[0] !== '-' && /\.(test|spec)\.|__tests__\//.test(a));
    const options = args.filter((a) => a[0] === '-');
    const isLight = runner !== 'playwright' &&
      files.length > 0 &&
      !heavyWords.test(script) &&
      !options.some((a) => heavyWords.test(a));
    if (isLight) return;

    const tgRun = env.TEST_GATE_TG_RUN || path.join(__dirname, '..', 'bin', 'tg-run');
    try {
      fs.accessSync(tgRun, fs.constants.X_OK);
    } catch (e) {
      return;
    }

    // TEST_GATE_PARENT: tg-run stops waiting or running if this process is killed.
    const childEnv = Object.assign({}, env, { TEST_GATE_INSIDE: '1', TEST_GATE_PARENT: String(process.pid) });
    const result = require('child_process').spawnSync(
      tgRun,
      ['--', process.execPath].concat(process.execArgv, process.argv.slice(1)),
      { stdio: 'inherit', env: childEnv }
    );
    if (result.error) return; // could not start tg-run: run as usual
    process.exit(result.status === null ? 1 : result.status);
  } catch (e) {
    // Never break a test run because of the gate.
  }
})();
