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

## Node gate: works with any agent (prototype)

The Claude Code hook sees only Claude Code. The Node gate works for every
agent (Claude, Codex, Cursor...), your IDE and you, and changes nothing in
your repositories. Add this line to `~/.zshenv` and open a new terminal:

```bash
[ -f "$HOME/.test-gate/node/gate.js" ] && export NODE_OPTIONS="--require $HOME/.test-gate/node/gate.js ${NODE_OPTIONS:-}"
```

It keeps your other `NODE_OPTIONS`. It needs a home folder path without
spaces. The `[ -f ... ]` check matters: if
`NODE_OPTIONS` points to a file that does not exist, **every** `node`,
`npm` and `yarn` command fails. To remove the gate, delete this line.

Now every Node process loads `node/gate.js` first (it costs about 2 ms):

- not Jest, Vitest or Playwright: nothing happens;
- a run with explicit test files (`jest src/a.test.ts`): runs at once,
  without the queue. A script name or option with `it`, `e2e` or
  `integration` (like `test:it`) still uses the queue;
- `playwright test`, or a run without test files: the gate starts the same
  command again through `tg-run --` and waits in the queue.

To check that an agent gets it, ask it to run `echo $NODE_OPTIONS`.
To turn it off for one command: `TEST_GATE_NODE=off yarn test`.

The gate does nothing for watch mode (`--watch`, `vitest` in a terminal,
`--ui`) and when a debugger is attached (`--inspect`, VS Code).
If the waiting Node process is killed, its run leaves the queue, or stops
if it already runs.

Limits:

- If a script starts Docker first and Jest later
  (`docker compose up && jest`), Docker starts before the queue. Run such
  scripts with `tg-run -- yarn test:it`.
- Node's own test runner (`node --test`) is not gated.
- In a monorepo, `yarn workspaces foreach -p run test` puts each Jest in
  the queue on its own, so they run one by one.
- If something fails inside the gate, or `tg-run` is not found, the tests
  run as usual.

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
| `tg-classify "<cmd>"` | show how the hook sees a command, and which rule decided it |

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

When the hook is not sure, it treats the command as heavy.

### Your own rules

If the hook is wrong for your project, write your own rules in
`~/.config/test-gate/rules` (or in the file set by `TEST_GATE_RULES`).
One rule per line:

```
# heavy <regex>: always use the queue
# light <regex>: never use the queue
heavy ^yarn verify$
light ^yarn test:unit
```

- The regex is checked against one simple command (the part between `&&`,
  `;`, `|`). Before the check, env vars (`CI=1`), wrappers (`time`,
  `timeout 60`, `sudo`) and extra spaces are removed, and quoted text is
  replaced by `""`. So `CI=1 time yarn verify` is checked as `yarn verify`.
- Use `^` and `$`: `light test:unit` also matches `test:unit:all`.
- Your rules are checked first. The first rule that matches wins.
- Rules cannot allow watch mode or `tg-run --light` for a heavy run.
- Changes work at once, in all sessions.

Check how a command is seen:

```bash
tg-classify "yarn --cwd api test:it __tests__/db.test.ts"
```

```
kind:  heavy
part:  yarn --cwd api test:it __tests__/db.test.ts
rule:  built-in
means: blocked unless it runs as: tg-run -- <command>
```

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
tests/classify.test.sh && tests/queue.test.sh && tests/node.test.sh
```

See [CLAUDE.md](CLAUDE.md) for the rules (bash 3.2, BSD tools).
