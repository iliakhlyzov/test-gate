# Instructions for agents

Paste the block below into the instructions your agents read:

- Claude Code: `~/.claude/CLAUDE.md` (all projects) or the project's `CLAUDE.md`
- Codex: `~/.codex/AGENTS.md` (all projects) or the project's `AGENTS.md`

Codex is not covered by the Claude Code hook, so for Codex these
instructions are the only guard.

---

```markdown
## Heavy commands on this machine (test-gate)

Several agents share this Mac. Heavy test runs go through a machine-wide queue
so that together they do not exhaust memory.

- Run full test suites, Playwright/e2e tests and integration tests (anything
  that starts containers) only through `tg-run -- <command>`, for example
  `tg-run -- yarn test` or `cd app && tg-run -- yarn test:e2e`.
  For compound commands: `tg-run -- bash -c 'cd app && yarn test'`.
- Running specific unit test files is fine without the queue:
  `yarn test src/foo.test.ts`.
- Start tg-run in the background when your tool allows it (Claude Code:
  `run_in_background: true`); waiting in the queue can take minutes.
- `QUEUED` or `WAITING` in the output is expected: another agent is testing
  or memory is low. Wait for the command to finish. Do not:
  - change, split or shrink the command to get around the queue;
  - start the test runner another way (npx, node_modules/.bin, bash -c, make);
  - kill other agents' processes;
  - conclude that the tests hang.
- If tg-run exits with code 75 it gave up waiting and the tests did NOT run.
  Say so to the user; do not run the tests without tg-run.
- Never start test runners in watch mode (`--watch`, `--watchAll`, plain
  `vitest` in a terminal).
- Stop dev servers and containers you started once you no longer need them.
- `tg-status` shows what is running and waiting.
```
