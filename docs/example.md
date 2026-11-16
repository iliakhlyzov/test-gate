# Example: why does my Mac freeze?

This is a real case from the first days of test-gate. Names of projects and
services are removed. The numbers are real.

## The situation

- MacBook with **18 GB RAM**.
- Several Claude Code sessions and Codex work at the same time. They often
  run tests: Jest, Playwright, integration tests with Docker.
- The project runs in Docker. There are **two copies** of the backend stack
  (one to work with, one for tests) and **two copies** of the web client.
- Problem: when tests run, the Mac becomes very slow, and macOS shows the
  "Force Quit Applications" window.

The first idea was: "the tests use too much memory, so they need a queue".
The data showed a different story.

## Step 1. Look at the state of the machine

`tg-status --swiftbar` (the menu bar plugin; SwiftBar parameters removed),
with no tests running:

```
🟡
---
Memory: warn · available 37%
Swap 26.9 GB · compressed 6.6 GB · disk 11 GB free
---
Nothing running
```

**26.9 GB of swap with no tests running.** That is more than all the RAM.
Free disk space was also low (11 GB), and swap files live on the same disk.

## Step 2. Measure one test run

```
$ tg-measure yarn test
──────── test-gate measure ────────
command          yarn test
duration         5m11s (exit 0)
peak memory      3.7 GB in 4 processes  (RSS of the process tree)
Mac RAM          18.0 GB
worst pressure   warn
swap used        28.6 GB before, 33.6 GB peak
lowest free disk 111 GB
VMs (Docker...)  0.8 GB peak, not included above
───────────────────────────────────
```

- One run needs about **3.7 GB**, about 20% of the RAM. That is fine.
- But swap grew by 5 GB during the run: the Mac had no free memory before
  the tests started.
- `tg-measure` counts RSS, so it sees only a small part of the Docker VM
  memory (0.8 GB here, 8.1 GB in `top` below).
- The run takes 5 minutes. Claude Code stops a foreground Bash command after
  2 minutes, so agents must start `tg-run` in the background.

## Step 3. Find who holds the memory

`ps` (RSS) showed nothing big: every process was under 0.5 GB. RSS does not
count memory that is compressed or in swap. `top` counts it:

```
$ top -l 1 -o mem -n 15 -stats mem,command
MEM   COMMAND
8136M com.apple.Virtua      <- Docker virtual machine
7470M com.docker.backe      <- Docker Desktop service
3610M node                  <- web client dev server
2870M CursorUIViewServ
2060M com.apple.Virtua      <- another virtual machine
1980M WindowServer
1774M node                  <- second web client
...
```

```
$ uptime
14:55  up 68 days,  6:05, 6 users, load averages: 10.80 12.92 13.99
```

- **Docker held about 15.6 GB**: 8.1 GB for the VM and 7.5 GB for
  `com.docker.backend`. The second number is not normal. It looks like a
  memory leak after 68 days without a reboot.
- So the tests were not the cause. They were the last drop.

**Lesson:** to find who uses memory on macOS, use `top` (or Activity
Monitor), not `ps`.

## Step 4. Reboot and limit Docker

- Docker Desktop → Settings → Resources → Memory: 6 GB.
- Reboot the Mac.

After the reboot: swap 0, the Docker VM about 1.8 GB.

## Step 5. Measure the setup step by step

```
tg-log start
tg-log mark "after reboot"
# start the main Docker stack
tg-log mark "docker: main stack"
# start the web client
tg-log mark "client 1"
# run tests through the queue
tg-run -- yarn test
tg-log summary
```

Result (short):

```
RAM: 18.0 GB
pressure: normal 6, warn 20, critical 0 samples
peak swap used: 5885 MB
peak node processes total: 4984 MB
peak browsers total: 6215 MB, peak VM (Docker etc.): 1673 MB
marked events:
  after reboot        (pressure 1, swap 0 MB,   top: Google Chrome Helper 5338 MB)
  docker: main stack  (pressure 2, swap 257 MB, top: Google Chrome Helper 3292 MB)
  client 1            (pressure 2, swap 745 MB, top: Google Chrome Helper 3982 MB)
gated runs: 3, avg wait 288s, max wait 864s, avg duration 222s
```

| Step | Pressure | Swap | Main user of memory |
|---|---|---|---|
| After reboot | normal | 0 | Chrome 5.3 GB |
| + main Docker stack | warn | 0.3 GB | Chrome 3.3 GB, webpack 1.4 GB |
| + client 1 | warn | 0.7 GB | Chrome 4 GB |
| + test run | warn | 4–5.9 GB | node 3–3.9 GB, Chrome 2.8 GB |

- **Chrome is the biggest constant user: 3–6 GB.**
- Even half of the setup (one stack, one client) plus one test run does not
  fit into 18 GB without swap.
- The queue works: 3 runs, they waited up to 14 minutes for each other
  instead of running at the same time.

## Memory budget for 18 GB

| Part | GB |
|---|---|
| macOS (wired memory, WindowServer, Spotlight) | ~4 |
| Chrome | 5–6 |
| Slack, Telegram, Claude, Codex, terminal | 2–3 |
| Docker, main stack | ~2 |
| Web client (webpack + node) | 2–3 |
| One test run | ~3.5 |
| **Total** | **~18–22** |

The second Docker stack and the second client add 4–6 GB more. "Two of
everything + agents + tests" needs about 28–32 GB.

## What helps, from cheap to expensive

1. Turn on Chrome Memory Saver and close heavy tabs (Chrome menu Window →
   Task Manager). Can give back 2–4 GB.
2. Limit Docker Desktop memory and restart Docker (or the Mac) from time to
   time. Or try OrbStack, which frees memory when it does not need it.
3. Run one web client. Start the second one only when you need it.
4. Start the test stack only for the time of the tests (one at a time,
   thanks to the queue).
5. Use `tg-run` for heavy tests, so agents do not run them at the same time.
6. If nothing can be removed: move the test stack and test runs to another
   machine or CI, or use a Mac with 32 GB or more.
