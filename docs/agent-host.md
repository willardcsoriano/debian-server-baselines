# Long-Running Agent Host

## Overview

A dev server that keeps many AI agent sessions (Claude Code, Antigravity) alive in tmux for weeks needs five things a normal dev box doesn't: enough swap for idle sessions to page out into, an OOM policy that sacrifices the reconnectable VS Code server before an irreplaceable agent, a way to bring every session back after a reboot, transcript retention longer than the longest idle stretch, and a way to clear the `vscode-server` trees a bad reconnect leaves behind before they pile up and exhaust that same memory. `dev.sh` section 9/9 installs all five, and none of them changes the Hetzner bill. Docker is upgraded only on purpose, through `docker-upgrade.sh`; a `dev.sh` re-run never moves the engine. This page explains each piece, why it's built that way, how to operate it day to day and after a reboot, and when to buy more RAM instead. It was written after a 2026-10-12 review of a cx43 (16 GB) host running ten agent sessions.

## Table of Contents

- [Overview](#overview)
- [The problem this solves](#the-problem-this-solves)
- [What `dev.sh` section 9/9 installs](#what-devsh-section-99-installs)
  - [a. Swap](#a-swap)
  - [b. OOM priority](#b-oom-priority)
  - [c. Session snapshot and restore](#c-session-snapshot-and-restore)
  - [d. Transcript retention](#d-transcript-retention)
  - [e. VS Code server reaper](#e-vs-code-server-reaper)
- [Docker upgrades](#docker-upgrades)
- [When to buy more RAM](#when-to-buy-more-ram)
- [Logs and failure reports](#logs-and-failure-reports)
- [Verification](#verification)

## The problem this solves

Measured on the reference host (cx43, 8 vCPU / 16 GB RAM / 160 GB disk, 4 GB swap):

- 10 tmux sessions (9 `claude`, 1 `agy`) held ~6.9 GB RSS and 2.2 GB swap. Each Claude session costs ~0.5–1 GB including its MCP server children.
- Only one session was attached; the rest had been idle for 5–29 days. The kernel had paged them out: swap was 86% full while 47% of RAM was available, memory PSI was 0, and swap-in/out was zero. **That's healthy.** The problem was headroom: ~540 MB of swap left.
- Every process had `oom_score_adj = 0`. Each Claude session scored ~680 and vscode-server ~667, so under memory exhaustion the kernel would kill an agent first.
- A reboot (including `make recover` / hard reset) would kill all ten sessions. Most were started with `claude -r`, so neither the command line nor any open file said which conversation each one held.
- Claude Code deletes transcripts older than `cleanupPeriodDays` (default 30). One idle session's transcript was 28 days old, two days from deletion. Once a transcript is gone, that conversation can't be resumed.
- A reconnect storm — a wifi switch, a client auto-update mid-session, a lossy mobile link — can leave behind `vscode-server` session trees with no client that will ever ask them to shut down. On a reference incident (2026-08-21), a single wifi switch orphaned three windows' worth of extension-host + language-server trees inside about an hour, driving swap to 100% full and load average to ~95 before anyone noticed.

## What `dev.sh` section 9/9 installs

| Piece | Where | Runs as | Tunable |
|---|---|---|---|
| Extra swap file | `/swapfile.agents` + `/etc/fstab` | — | `SWAP_TARGET_GB` (default 16) |
| OOM priority | `/usr/local/sbin/agent-oom-priority`, `agent-oom-priority.{service,timer}` (every 1 min) | root | edit `AGENT_ADJ` / `EDITOR_ADJ` in the script |
| Session snapshot/restore | `~/.local/bin/agent-sessions`, `~/.config/systemd/user/agent-sessions-snapshot.{service,timer}` (every 5 min), a `hint` line in `~/.bashrc` | user | — |
| Transcript retention | `/etc/claude-code/managed-settings.d/50-agent-host-retention.json` | — | `CLAUDE_RETENTION_DAYS` (default 90) |
| VS Code server reaper | `/usr/local/bin/reap-vscode-{orphans,server}.sh`, `vscode-server-reap{,-orphans}.{service,timer}` | user | edit `MAX_AGE_HOURS` in `reap-vscode-server.sh` |

Every piece is idempotent, and re-running `dev.sh` refreshes the installed files to the repo's version:

```bash
bash scripts/dev.sh
SWAP_TARGET_GB=24 CLAUDE_RETENTION_DAYS=120 bash scripts/dev.sh   # override defaults
```

### a. Swap

`dev.sh` tops total swap up to `SWAP_TARGET_GB` by adding `/swapfile.agents` for the shortfall. It doesn't resize the existing swap file, because resizing needs `swapoff`, which forces every paged-out idle session back into RAM at once. It refuses to act on filesystems other than ext4/xfs, or with less than the shortfall plus 20 GB free.

On Hetzner, swap is a file on the server's local disk; there's no separate swap product and nothing extra to pay. A Hetzner Volume would cost extra and is network storage, which is slower for swap.

### b. OOM priority

`agent-oom-priority` sets `oom_score_adj` to **−500** on every tmux server and everything under it (agents, their MCP servers, pane shells), and to **+500** on every `~/.vscode-server` process tree. Children inherit the value at fork, so new panes start protected; the 1-minute timer covers processes that predate it. Dry run: `sudo agent-oom-priority -n`.

Design choices:

- **−500, not −1000.** A genuinely runaway agent must stay killable.
- **A timer, not a one-shot.** Lowering a score needs root, and sessions started before the first run must be covered.
- **No systemd-oomd.** It kills whole cgroups, so one decision could take out several agents.
- **Only agents inside tmux are protected.** An agent started directly in a VS Code terminal is part of the vscode-server tree and gets +500. Run agents in tmux.

### c. Session snapshot and restore

Every 5 minutes, `agent-sessions snapshot` writes `~/.local/state/agent-sessions/manifest.json`, with one entry per tmux session:

- **Claude sessions:** the conversation ID and working directory, read from Claude Code's per-process file `~/.claude/sessions/<pid>.json`. That file records `sessionId`, `cwd` and the tmux pane.
- **Any other session:** the running command and the directory.

Sessions that disappear **during the current boot** were closed on purpose and are dropped. Sessions last seen in an **earlier boot** are kept until you restore or forget them.

After a reboot, an interactive login prints `agent-sessions: N session(s) from before the last reboot are not running`. Then:

```bash
agent-sessions list          # what's recorded, live vs MISSING
agent-sessions restore -n    # dry run
agent-sessions restore       # recreate each tmux session; type `claude --resume <id>` into it
agent-sessions forget NAME   # drop an entry you don't want back
```

`restore` creates each tmux session in its recorded directory and types the resume command into the pane's shell. That means `.bashrc` and `PATH` apply as usual, and quitting Claude leaves a shell behind. Non-Claude sessions (e.g. `agy`) get a shell in the right directory plus a reminder to start the tool yourself.

**Duplicate conversations.** If two tmux sessions hold the same conversation ID, `restore` resumes only the first and warns about the rest. Two live processes appending to one transcript can corrupt it. This happened on the reference host (`cli` and `netsuite` both on one conversation); `cli` was closed.

**Drift risk.** `~/.claude/sessions/<pid>.json` is an internal Claude Code file, not a documented interface; it was verified against 2.1.296. If its shape changes, Claude panes are recorded without a conversation ID, and `restore` opens a shell and says so instead of guessing. `agent-sessions list` showing `claude` entries with an empty conversation column is the signal to re-check it.

### d. Transcript retention

Claude Code's retention sweep runs after a session starts and deletes transcripts older than `cleanupPeriodDays` without any message. An idle session whose transcript ages out keeps running, but it can't be resumed after a reboot.

`dev.sh` raises the floor to 90 days with a managed-settings drop-in. The drop-in leaves `~/.claude/settings.json` alone, which matters because that file is often a symlink into a personal config repo. Managed values outrank user settings. See [managed settings](https://code.claude.com/docs/en/managed-settings) and [`cleanupPeriodDays`](https://code.claude.com/docs/en/settings-reference#cleanupperioddays).

**Privacy.** Transcripts contain everything an agent read, including records pulled from client systems (Salesforce, NetSuite and similar), which may include personal data. Longer retention widens that exposure, so GDPR storage-limitation and client contract terms can apply. Mitigations, in order:

1. Keep retention no longer than your longest real idle stretch.
2. Restrict SSH access to this host to your own keys (`base.sh` does this).
3. When a client engagement ends, delete that project's transcripts under `~/.claude/projects/<project>/`.
4. Consider an encrypted volume for `~/.claude` on hosts handling regulated data. The stock Debian image on Hetzner has no disk encryption.

### e. VS Code server reaper

`vscode-server` runs natively as this host's login user, entirely outside Docker — none of the per-container `mem_limit` work in [the SSH banner-timeout cascade report](reports/dev-vm-ssh-banner-timeout-cascade.md) protects against a `vscode-server` pile-up OOMing the host the same way an unbounded container used to. Two reapers run side by side, covering different accumulation speeds rather than one replacing the other:

- **`reap-vscode-server.sh`** — age-based, every 6 hours. Kills any `vscode-server` session process (matched by its real binary path — `agent host`, `command-shell`, `code-server`, `server-main.js`, `bootstrap-fork`) older than `MAX_AGE_HOURS` (default 24), then sweeps leftover stale sockets under `/tmp/user/$UID`. Deliberately not connection-aware: accurately detecting "orphaned vs. currently connected" needs checking for a live peer on each session's control socket, which is fiddly to get right and risks the one failure mode that actually matters — killing a session someone is using. A flat age ceiling can't make that mistake; worst case it forces one reconnect.
- **`reap-vscode-orphans.sh`** — structurally-safe, every 2 minutes. A reconnect storm can orphan a tree in minutes, well inside the 6-hour reaper's window: a single wifi switch has driven swap to 100% full and load average to ~95 in under an hour (see the problem statement above). This reaper only kills a `vscode-server` tree whose top-level launcher (the `agent host`/`command-shell` process sshd spawns directly per connection) has `PPID=1` — unambiguous evidence its parent SSH session has already died and the kernel has reparented it, never true for a tree still attached to a live session. No age heuristic, no liveness guess.

Both install as root-owned systemd system units that run as the login user, same pattern as the OOM-priority piece above. Re-running `dev.sh` refreshes both scripts to the repo's version.

## Docker upgrades

`dev.sh` and `prod.sh` install Docker with `apt-get install --no-upgrade`. A re-run installs what's missing but never upgrades the engine under running containers. Before this change, a re-run would silently have moved Docker 29.6.2 → 29.9.0 and containerd 2.2 → 2.4.

Upgrade on purpose with `scripts/docker-upgrade.sh`:

```bash
bash scripts/docker-upgrade.sh --check   # what would change; no sudo, nothing modified
bash scripts/docker-upgrade.sh           # upgrade (short outage: all containers restart)
```

It works through these steps in order:

1. Record the package versions and the set of running containers under `~/.local/state/docker-upgrade/<timestamp>/`.
2. Upgrade only the Docker packages.
3. Restart the rootless daemon so the new engine is actually running.
4. Start any container that was running before and didn't come back.
5. Verify. If the daemon or any container fails, print the exact `apt-get install --allow-downgrades <pkg>=<old-version> …` rollback command.

**Restart policies.** Containers with `restart: no` don't come back after a daemon restart or a reboot. `docker-upgrade.sh` restarts them for you, but a reboot won't. On the reference host, 4 of 5 running containers (`wfmctrading-*`, an ad-hoc `debian:bookworm-slim`) had no policy. Add `restart: unless-stopped` to each long-lived service in its compose file. That's a per-project decision, so it lives in each project repo, not here.

## When to buy more RAM

Upgrading from cx43 (16 GB, €18.49/mo) to cx53 (32 GB, €34.99/mo) is warranted by **memory pressure, not session count**. Idle sessions live in swap and cost disk, not RAM. The signal is `check-dev` (dotfiles) or `/proc/pressure/memory` showing `some avg60` ≥ 5% repeatedly during normal work, or available RAM under 15% with swap full. Before upgrading, re-check `hcloud server-type describe cx53` for availability in the server's location. The snapshot-migration runbook is in [HETZNER-CLOUD.md](HETZNER-CLOUD.md).

## Logs and failure reports

Every run of `dev.sh` and `docker-upgrade.sh` is logged in full, and each ends with a single greppable `RESULT:` line.

| Script | Log |
|---|---|
| `dev.sh` | `~/.local/state/debian-server-baselines/dev-<timestamp>-<pid>.log` |
| `docker-upgrade.sh` | `~/.local/state/docker-upgrade/<timestamp>-<pid>/run.log`, next to the recorded package versions and running containers |

- **On success:** `RESULT: OK (…, N warning(s))`, preceded by the list of warnings, each tagged with its section.
- **On failure:** the failing section, line, command and exit code, then `RESULT: FAILED in section '…'`. If `docker-upgrade.sh` had already upgraded packages before failing, it also prints the exact rollback command.
- **sudo:** both scripts ask for your password once, at the start, and keep the credential alive for the whole run, so a long step never stalls at a hidden prompt. The password is read from the terminal and never reaches the log.
- **Permissions:** logs are mode 600 in a mode 700 directory.
- **Terminal required:** the scripts need a real terminal for that prompt. Run them from your own terminal (`ssh -t host 'bash dev.sh'`), not from a tool that has no terminal; there they stop at preflight with `sudo authentication failed` and change nothing.

Quick check after a run:

```bash
grep -h '^RESULT' ~/.local/state/debian-server-baselines/dev-*.log | tail -1
```

## Verification

```bash
swapon --show                                         # /swapfile + /swapfile.agents
systemctl list-timers agent-oom-priority.timer        # next run within a minute
for p in $(pgrep -x claude); do cat /proc/$p/oom_score_adj; done   # -500 each
pgrep -f .vscode-server | head -3 | xargs -I{} cat /proc/{}/oom_score_adj   # 500
systemctl --user list-timers agent-sessions-snapshot.timer
agent-sessions list                                   # every agent session, state=live
cat /etc/claude-code/managed-settings.d/50-agent-host-retention.json
systemctl is-enabled vscode-server-reap.timer vscode-server-reap-orphans.timer
systemctl list-timers vscode-server-reap.timer vscode-server-reap-orphans.timer   # next run within 6h / 2min
```

AIDE will report the new files under `/usr/local/sbin`, `/etc/systemd/system` and `/etc/claude-code` on its next check. That's expected; re-baseline it after reviewing.
