# test-gate: notes for working on this repo

- Target is macOS. Scripts run under `/bin/bash` 3.2 with BSD tools: no
  associative arrays, `mapfile`, `${x,,}`, `wait -n`, GNU-only flags of
  `sed`/`date`/`stat`/`ps`. `awk` must work with BSD awk (test with `mawk`).
- No runtime dependencies beyond what macOS ships. `jq` is optional.
- Linux fallbacks in `lib/common.sh` exist only so the tests run in CI or in
  a Linux container.
- Agent-facing messages (tg-run, the hook, docs/agents.md) are in English;
  README is in Russian.
- Run `tests/classify.test.sh` and `tests/queue.test.sh` after changes, and
  `shellcheck -x -S warning bin/* lib/*.sh install.sh swiftbar/*.sh tests/*.sh`.
