# test-gate

A queue for heavy test runs on a Mac, for the case when several AI agents
(Claude Code, Codex) run tests at the same time.

**The problem:** two or three agents start `yarn test`, Playwright and
integration tests with containers at the same time. The Mac runs out of
memory, macOS shows the "Force Quit Applications" window, and everything
becomes slow.

**What test-gate does:**

- `tg-run` puts heavy test runs in one queue for the whole machine (all
  repositories and worktrees). By default only one heavy run works at a time.
  A waiting run prints `QUEUED: position 2 of 3`.
- It does not start a heavy run when memory pressure is critical or when
  there is too little free disk space for swap.
- When a run ends, it stops the processes that the run left behind (jest
  workers, browsers).
- A Claude Code hook stops agents from running heavy tests outside the queue
  and tells them the right command.
- `tg-log` and `tg-measure` help you find out what really uses the memory.
- `tg-status` and a menu bar plugin show what is running and what is waiting.

No dependencies: it uses only what macOS already has. `jq` is useful for the
hook and the installer. macOS 15 and newer already have it. On older macOS,
install it (`brew install jq`) or add the hook to the settings by hand.

> **Status: experiment.** The scripts are tested on Linux. They have not run
> on macOS yet. If something fails, please open an issue with the output.

## Install

```bash
git clone https://github.com/iliakhlyzov/test-gate ~/.test-gate
```

```bash
~/.test-gate/install.sh --claude-hook
```

This links the commands into `~/.local/bin` and adds the hook to
`~/.claude/settings.json` (the old version is saved as `settings.json.bak`).
If `~/.local/bin` is not in your `PATH`, the installer shows the line to add
to `~/.zshrc`. To remove everything: `install.sh --uninstall`.

Then give your agents the instructions from [docs/agents.md](docs/agents.md):
add them to `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`.

A real example of this work, with numbers: [docs/example.md](docs/example.md).

## The experiment (3–5 days)

Goal: zero "Force Quit Applications" windows, and a clear answer to the
question "what uses the memory?".

**1. Start the logger.** It saves the state of the machine every 15 seconds.

```bash
tg-log start
```

When the Mac becomes slow or the window appears, mark the moment:

```bash
tg-log mark "force quit window"
```

**2. Measure one run of each kind** while the Mac is quiet:

```bash
tg-measure yarn test
```

```bash
tg-measure yarn playwright test
```

It shows the peak memory of the run and all its child processes, swap, the
memory of VMs (Docker), and processes that are still alive after the run.
If one run alone uses more than half of the RAM, a queue is not enough:
limit the workers first (see the next step).

**3. Limit the tests.** In the project config:

```js
// jest.config.js
module.exports = { maxWorkers: 2, workerIdleMemoryLimit: '1GB' }
```

```js
// playwright.config.ts
export default defineConfig({ workers: 2 })
```

For Docker Desktop, set a memory limit (Settings → Resources), for example
4–6 GB. Or use OrbStack: it gives memory back when it does not need it.
Do not turn off Ryuk in testcontainers: it removes containers after failed runs.

**4. Read the results:**

```bash
tg-log summary
```

It shows peak swap and memory, the lowest free disk space, moments with high
memory pressure and the top processes at that time, your marks, and how long
runs waited in the queue.

## Commands

| Command | What it does |
|---|---|
| `tg-run -- <cmd>` | heavy run through the queue |
| `tg-run --light -- <cmd>` | no queue; waits only when memory pressure is critical |
| `tg-status` | what is running and what is waiting |
| `tg-log start` / `stop` / `status` | background logger |
| `tg-log mark [note]` | mark the moment when the Mac froze |
| `tg-log summary [days]` | results from the logs |
| `tg-measure <cmd>` | measure one run |

Data is in `~/Library/Application Support/test-gate/`, logs are in `logs/`
inside it.

## What is "heavy" (the hook)

- **Heavy, only through the queue:** `yarn test`, `npm test`, `npx jest`,
  `vitest run`, `playwright test`, scripts `test:*`, `e2e*`, `integration*`,
  `make test`, `nx test`, `turbo run test`. Package manager options like
  `pnpm --filter web test` or `yarn --cwd app test`, and wrappers like
  `timeout`, `caffeinate` and `bash -c "..."` are understood too.
- **Light, no queue:** a run with explicit test files, like
  `yarn test src/a.test.ts`. A run is still heavy if the script name or the
  options say e2e, integration, playwright or `it` (like `test:it`).
- **Blocked:** watch mode (`--watch`, `--watchAll`, scripts like `test:watch`),
  and `tg-run --light` for a heavy run.

When the hook is not sure, it treats the command as heavy. You can add your
own rules (regex, added to the defaults):

- `TEST_GATE_HEAVY_SCRIPTS_EXTRA`: more script names that run tests, for
  example `'^build$'`.
- `TEST_GATE_ALWAYS_HEAVY_EXTRA`: more words that make a run heavy even with
  test files.

To turn the hook off for a while: `TEST_GATE_HOOK=off`.

## tg-run settings

| Variable | Default | Meaning |
|---|---|---|
| `TEST_GATE_SLOTS` | 1 | how many heavy runs can work at the same time |
| `TEST_GATE_MAX_PRESSURE` | 2 | start only when pressure is at most: 1 normal, 2 warn, 4 critical |
| `TEST_GATE_MIN_DISK_GB` | 15 | minimum free disk space for swap |
| `TEST_GATE_MAX_WAIT` | 0 | stop waiting after N seconds (exit code 75); 0 = wait forever |
| `TEST_GATE_MAX_RUN` | 7200 | stop a run after N seconds; 0 = never |
| `TEST_GATE_KILL_LEFTOVERS` | 1 | stop processes that the run left behind |

The command gets no input: its stdin is `/dev/null`.

## Menu bar

Install [SwiftBar](https://github.com/swiftbar/SwiftBar) and link the plugin
into the SwiftBar plugin folder:

```bash
ln -s ~/.test-gate/swiftbar/test-gate.5s.sh "<SwiftBar plugin folder>/"
```

The icon is 🟢/🟡/🔴 for memory pressure. `▶1 ⏳2` means one run is working
and two are waiting. The menu lists the runs, with a Stop button for each.

## Limits

- The hook sees only Claude Code commands. Codex and commands you type
  yourself can skip the queue. For them there are only the agent instructions.
- The hook reads the command text. A custom script that runs tests inside
  will not be noticed.
- The Claude Code Bash tool stops a command after **2 minutes** by default
  (10 minutes at most). A run that waits longer in the queue is stopped and
  its place in the queue is lost. So agents should start `tg-run` in the
  background (`run_in_background: true`).
- If a run starts something in its own process group (for example a
  Playwright `webServer`, or Docker containers), test-gate cannot stop it.
- Memory is measured as RSS, so the numbers are approximate. VM memory
  (Docker) is not included in the memory of a run.
- The logger does not start again after a reboot. Run `tg-log start` again.

## Development

```bash
tests/classify.test.sh && tests/queue.test.sh
```

See [CLAUDE.md](CLAUDE.md) for the rules (bash 3.2, BSD tools).
