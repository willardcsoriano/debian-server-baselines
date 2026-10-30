# SSH banner-exchange timeout on `dev`: a Docker OOM cascade starving `sshd`

## Overview

For months, SSH to the `dev` Hetzner VM intermittently failed with `Connection timed out during banner exchange`, and the only recovery was a full VM reboot. Five rounds of fixes were tried first, all at the SSH application layer (`sshd_config` tuning, systemd socket activation, client `ControlMaster`, MTU/`IPQoS` settings, a mobile-hotspot network-path test) — all failed, because the real cause was never there. A plain `nc <ip> 22` test (TCP handshake completes, then nothing) finally reframed the problem as below the SSH layer entirely. On 2026-07-24, `hcloud server metrics` plus a `journalctl -b -1` read taken immediately after a hard reset found it: a Docker container health-check failure cascaded into the rootless `docker.service` getting OOM-killed and stuck in a crash-restart loop, pegging CPU at 600–800% and disk reads at ~1 GB/s for over an hour — starving `sshd` itself along with everything else on the VM. The same cascade recurred on 2026-07-28 with a different, fully-confirmed trigger: a Laravel container whose PHP-FPM worker had run unrecycled for ~53 hours. Both incidents share one root enabling condition — no memory ceiling anywhere on the VM — which is why the fixes below (swap, per-container limits, the crash-loop guard, and the agent-host hardening in [`agent-host.md`](../agent-host.md)) target that gap directly rather than the SSH layer the first five attempts chased.

## Table of Contents

- [Overview](#overview)
- [The rule that would have saved five rounds of guessing](#the-rule-that-would-have-saved-five-rounds-of-guessing)
- [Five failed attempts, all at the wrong layer](#five-failed-attempts-all-at-the-wrong-layer)
- [What actually reframed the problem](#what-actually-reframed-the-problem)
- [Root cause: two occurrences, one systemic gap](#root-cause-two-occurrences-one-systemic-gap)
  - [2026-07-24 — the first diagnosed occurrence](#2026-07-24--the-first-diagnosed-occurrence)
  - [2026-07-28 — same cascade, a fully-confirmed trigger](#2026-07-28--same-cascade-a-fully-confirmed-trigger)
  - [Why "just reboot" always "fixed" it](#why-just-reboot-always-fixed-it)
- [Corrective actions](#corrective-actions)
- [Recovery runbook](#recovery-runbook)
- [Later incidents on this VM (chronological index)](#later-incidents-on-this-vm-chronological-index)
- [Open questions](#open-questions)
- [References](#references)

## The rule that would have saved five rounds of guessing

**Before assuming an SSH problem on this box, check `docker.service` and `journalctl -b -1` first** — and if the crashed boot's `tail -300` doesn't show a clear trigger, grep the full boot, not just the tail. Every occurrence before 2026-07-24 was destroyed by an immediate reboot before anyone looked at the system in its broken state; once a `journalctl -b -1` read immediately after recovery became standard practice, the real cause turned up in minutes both times this cascade has actually been diagnosed.

## Five failed attempts, all at the wrong layer

Each of the following looked plausible at the time and is recorded so it isn't retried after the next drop:

1. **VS Code multiplexing storms** — raised `MaxStartups`, disabled `TCPKeepAlive`, raised `LoginGraceTime` in `sshd_config`. Failed — still timed out on the next drop.
2. **Systemd socket-activation deadlock** — disabled `ssh.socket`, ran `ssh.service` as a persistent daemon instead. Failed identically.
3. **Client-side `ControlMaster` corruption** — removed multiplexing entirely from `~/.ssh/config`. Failed; `ssh -v` showed TCP completing cleanly, then hanging on the server's banner — proof the hang was server-side, not a client control-socket artifact.
4. **Client proxy / MTU blackholing** — deleted a systemd SSH proxy config, added `IPQoS 0x00` to the client config. Failed. (This step also shipped a real regression: `0x00` is invalid `IPQoS` syntax, and OpenSSH refused to start *at all* for any host on this client until it was fixed to the valid decimal form `IPQoS 0` — a self-inflicted bug layered on top of the real issue, caught late because the verification step (`nc`, not `ssh -v`) couldn't have detected an SSH-config parse error.)
5. **Switch client network entirely** — retried from a mobile hotspot, a completely different public IP and path. Failed identically, which ruled out CGNAT/IP-roaming and any IP-specific ban as the cause.

## What actually reframed the problem

After attempt 4, two plain `nc` tests settled where the failure actually was:

```
nc -zv -w 3 <dev-ip> 22   →  succeeds, TCP handshake completes
nc <dev-ip> 22            →  hangs indefinitely, zero bytes returned
```

Because `nc` is a completely different client than OpenSSH or VS Code's SSH implementation and fails identically, every client-side and SSH-application-layer theory was ruled out. The TCP handshake is handled entirely by the kernel, independent of whether `sshd` is alive; the banner is only sent once `sshd` calls `accept()` on the queued connection. "Port open, handshake completes, then infinite silence" means either `sshd` itself is wedged/unable to fork, or something below it — resource exhaustion, not an edge firewall, confirmed by the identical hotspot-retry result — is starving every process on the box, not just `sshd`.

## Root cause: two occurrences, one systemic gap

| Field | Value |
|---|---|
| Affected system | `dev` (Hetzner Cloud VM, Debian 13, rootless Docker) |
| Symptom | `Connection timed out during banner exchange` on every client (OpenSSH, VS Code Remote-SSH, plain `nc`) |
| Occurrences | 7 total: 5 prior and undiagnosed, 2 diagnosed (2026-07-24, 2026-07-28) |
| Detection | Manual — no automated alerting existed at the time |
| Proximate cause (both times) | `sshd` completed the TCP handshake (kernel-level) but was never scheduled to send its banner (userspace-level), because CPU/disk I/O were pegged by a Docker OOM/crash-restart cascade |

### 2026-07-24 — the first diagnosed occurrence

Two Postgres containers' health checks (`pg_isready`) began timing out at `05:56:24 UTC`, got stuck in a bad teardown state (`containerd`/`runc` errors: *"unable to destroy container: container still running"*), and by `06:04:04` the rootless `docker.service` itself was OOM-killed — already its 4th restart. Each restart re-attempted the same failing cleanup, pegging CPU at 600–800% and disk reads at ~1.0–1.3 GB/s continuously for over an hour, with network traffic flat throughout (ruling out an external cause). The VM was unreachable even to `qemu-guest-agent`; a soft ACPI reboot had no effect, and only a hard power-cycle (`hcloud server reset`) recovered it, in ~20 seconds.

**Five whys:** SSH timed out because `sshd` wasn't scheduled → because CPU/disk were pegged → because `docker.service` was crash-looping → because each restart hit containers already stuck in a bad teardown state from an earlier OOM kill → because the OOM killer fired in the first place. That last link is the one inference in the chain, not a proven fact: the leading theory is that roughly 10–15 concurrent SSH-backed connections (4 VS Code Remote-SSH windows, each running its own independent `vscode-server` + extension-host tree) added memory demand on top of the running containers, on a VM with **zero swap** at the time. Plausible and consistent with everything else observed, but no per-process memory snapshot from that exact second was ever captured, so it can't be proven after the fact.

**Fixed same day:** 4GB swap added and persisted (`vm.swappiness=10`); 24 months-old dead containers pruned; an unrelated client-side `IPQoS 0x00` syntax bug fixed; the Makefile below built so the next occurrence gets an evidence-preserving response instead of an immediate reboot.

### 2026-07-28 — same cascade, a fully-confirmed trigger

Four days later, the identical symptom returned. This time every link in the chain was confirmed directly, no inference required. `make check` (read-only) showed the same signature: CPU at 690–720%, disk reads at 1.0–1.3 GB/s, network flat. `journalctl -b -1`, grepped in full rather than just the last 300 lines (the postmortem's default tail didn't reach far enough back), found:

```
11:33:36  docker-0ae9c5fbb44c...scope: process killed by the OOM killer   (wfmctrading-app-1)
11:40:06  docker.service: killed by the OOM killer
11:40:07  docker.service: Failed with result 'exit-code'; app.slice also hit by OOM killer
11:40:09  docker.service: Scheduled restart job, restart counter is at 1
```

`wfmctrading-app-1`'s own PHP-FPM error log showed a worker process alive for **~53 hours** with no recycling (`pm.max_requests` unset in the stock `php:8.4-fpm` image), accumulating memory from Laravel/Filament's per-request static caches until the OOM killer took it, then escalated to `docker.service` itself ~6.5 minutes later. Unlike July 24, `docker.service` restarted cleanly on the first attempt — no repeating crash-loop at the unit level — but the VM stayed fully unreachable for a further ~20 minutes regardless, for reasons never fully confirmed (no journal data survives from inside that window).

**Fixed same day:** `mem_limit` added to all three `wfmctrading` compose services (`app: 2g`, `nginx: 256m`, `postgres: 1g`), validated against live Docker Compose documentation to confirm it's enforced outside Swarm mode, applied directly on the VM. **Recommended, not applied:** `pm.max_requests` (300–500) on the same pool — `mem_limit` bounds the blast radius, `pm.max_requests` addresses why the worker grew unbounded in the first place; this was later handed to the `wfmctrading` repo directly (`docs/learnings/03-php-fpm-worker-lifetime-and-memory-limits.md` there).

### Why "just reboot" always "fixed" it

A full reboot resets PIDs, clears memory pressure, and flushes connection tracking — regardless of which theory was actually correct. That ambiguity is exactly why every SSH-layer fix "looked like" it worked right before a reboot happened anyway: nothing was ever isolated against a live failure. One secondary troubleshooting source got specific mechanisms wrong along the way worth flagging so they aren't mistaken for confirmed causes later — "systemd socket activation deadlocks under connection churn" (attempt 2's theory) was never a documented failure mode, and "`IPQoS` prevents MTU blackholing" (attempt 4's theory) is technically incorrect; `IPQoS` only sets DSCP marking bits and has no relationship to packet size or fragmentation.

## Corrective actions

| Action | Status |
|---|---|
| 4GB swap, `vm.swappiness=10` | Done 2026-07-24. **Confirmed insufficient alone** by the 2026-07-28 recurrence — a genuine OOM under real memory pressure, not the restart-loop mechanism swap was meant to cushion |
| Prune months-old dead containers | Done 2026-07-24 |
| `docker.service` `StartLimitBurst=3` within 5 min (stops a crash-restart loop from forming at all) | Done 2026-07-29 — `~/.config/systemd/user/docker.service.d/override.conf`. This alone would likely have kept SSH alive during both prior incidents |
| Host-level memory ceiling for everything under the login session (`vscode-server` runs natively, outside any container's `mem_limit`) | Done 2026-07-29 — `/etc/systemd/system/user-1000.slice.d/override.conf`, `MemoryMax=14G`/`MemoryHigh=13G` |
| Per-container `mem_limit` on `wfmctrading` | Done 2026-07-28 |
| Per-container `mem_limit` on every other stack on this VM (`turtley`, `bodego`, `erpnext-scaffold`, `odoo-scaffold`) | **Still open.** Any of them could reproduce the same failure — any recurrence should start with `docker ps -a` to see which container got OOM-killed, not assume it's one of the two already fixed |
| `pm.max_requests` on `wfmctrading`'s php-fpm pool | Recommended, tracked in the `wfmctrading` repo, not here |
| Health-check timeout/retry tuning + backoff-aware restart policy on Postgres containers (replace bare `unless-stopped`) | Still open — directly addresses the mechanism that turned the July 24 blip into a crash-restart loop |
| `netdata` email alerting on memory pressure | Deferred by choice — needs `sudo` plus the operator's own SMTP credentials; command block preserved in this repo's `scripts/dev.sh` adjacent tooling for whenever it's picked up |
| `vscode-server` orphan reaping (a related but separate failure mode — reconnect storms exhausting memory, not Docker) | Done — see [`agent-host.md`](../agent-host.md) §e |
| Long-running agent-host hardening (swap headroom, OOM victim priority, session snapshot/restore, transcript retention) | Done — see [`agent-host.md`](../agent-host.md), `scripts/dev.sh` §9/9 |

## Recovery runbook

The repo root `Makefile` automates the escalation ladder used both times this cascade was actually diagnosed:

```bash
make check            # read-only: pull CPU/disk/network metrics via hcloud, no VM access needed
make recover          # the one command to run when it happens again — password-reset → soft reboot → hard reset, whichever is enough
make postmortem       # capture uptime/free/docker state/journalctl from the VM right now
make verify-hardening # confirm the mitigations above are actually live on dev, not just documented
```

`check`/`recover`/`postmortem` need no VM access until the final escalation step (`hcloud server reset`, a hard power-cycle) — in both diagnosed incidents, disk **write** I/O stayed at baseline throughout (only reads spiked, from the crash-restart cascade re-reading container/image layers), so a hard reset carried no observed data-loss risk to the VM itself. The standing, not-yet-realized risk is the two always-on Postgres containers (`bodego-postgres`, `turtley-db-1`) on this same VM: a hard power-cycle is not a clean shutdown, and an unlucky-timed reset mid-write is the actual worst-case exposure here (relying on WAL crash-recovery + ext4 journaling) — not VM destruction, but potential database corruption. This persists until `mem_limit` covers every stack on the box, not just `wfmctrading`.

**Before any reset, rule out the client's network.** Twice a carrier or company network filtered port 22 to this VM, which looks exactly like a wedged `sshd`. The check takes seconds: if `ping dev` is clean and a TCP probe to another port answers at once (`nc -vz -w 5 dev 443` comes back "refused" immediately) while `ssh dev` hangs, the VM is up and the path is filtering SSH. Switch networks instead of resetting. `make recover` does not run this check itself yet.

**Getting a console login.** `PermitRootLogin no` (set by `base.sh`) only applies to SSH, so root can still log in at the provider console:

1. `make password-reset` sets and prints a new root password (`hcloud server reset-password`). The agent's auto-mode classifier blocks this target, so run it yourself.
2. Open the server's **Console** in the Hetzner Cloud web UI. The `wss://` URL from `hcloud server request-console` is a VNC WebSocket for a VNC client and does not open in a browser tab.
3. Log in as `root` with that password. To fix the admin account: `getent group sudo` shows who has sudo, then `passwd <user>`.

The web console's keyboard mangles `|`, so type pipe-free commands there, one step at a time.

The moment SSH comes back, capture the previous boot's logs before they rotate out — `journalctl --list-boots`, then `journalctl -b -1 --no-pager`, grepped in full if the tail doesn't show a clear trigger (the July 28 postmortem's default `tail -300` didn't reach back far enough).

## Later incidents on this VM (chronological index)

The cascade above explains two of the roughly dozen "`dev` acting up" incidents since. Most of the others turned out to be a different, unrelated failure mode — `vscode-server` reconnect-storm pileups, not Docker/OOM — covered in [`agent-host.md`](../agent-host.md) §e, or network-path problems that only looked like a `dev`-side failure:

- **2026-07-29** — first confirmed `vscode-server` reconnect-storm pileup (not this cascade): a mid-outage VS Code client auto-update orphaned six server trees over ~24h.
- **2026-08-03, 2026-08-17** — the pileup recurred twice more, both times because the age-based reaper built after 07-29 had silently never actually been deployed to the VM.
- **2026-08-05** — a different shape: the VM was fully healthy, but a 2-day-old agent host wedged on new connections while still serving an open one.
- **2026-08-12 (×2), 2026-08-24, 2026-09-04** — not `dev`-side at all: a company network and, separately, mobile carriers were selectively filtering or degrading port 22 to this VM's IP specifically. One of these was misread as a pileup and escalated to an unnecessary hard reset before a side-by-side port test showed the VM was healthy throughout.
- **2026-08-21** — a wifi-switch-triggered pileup reached crisis level (load average ~95, swap 100% full) in under an hour, inside the 24h reaper's detection window entirely — closed by adding a second, faster, connection-aware reaper.
- **2026-09-25, 2026-09-29** — further orphan pileups and a hotspot-filtering recurrence.
- **2026-10-03 through 2026-10-24** — a run of client-side and protocol-budget issues (a stale VS Code SSH cache, a missing client sleep hook, `ConnectTimeout` budgets too short for lossy/slow mobile links) — none of them this VM's cascade, all client-side or protocol-timing fixes.

## Open questions

- What specifically triggered the 2026-07-24 memory pressure at `05:56:24 UTC` — still unconfirmed; the "too many concurrent Remote-SSH windows" theory is the best fit but unprovable after the fact.
- What kept the VM pegged and unreachable for ~20 minutes on 2026-07-28 after `docker.service` itself had already restarted cleanly — still unconfirmed.
- Whether the 5 earlier, undiagnosed occurrences (before 2026-07-24) share this same root cause or had a different one that was never identified — only the two most recent prior boots' journals were ever checked; earlier ones have long since rotated out.

## References

- `scripts/dev.sh` §9/9 and [`agent-host.md`](../agent-host.md) — the long-running agent-host hardening this cascade's follow-up work feeds into.
- Root `Makefile` — `make recover` / `check` / `postmortem` / `verify-hardening`, the automated version of the runbook above.
- `wfmctrading` repo, `docs/learnings/03-php-fpm-worker-lifetime-and-memory-limits.md` — the `pm.max_requests` follow-up for the 2026-07-28 trigger, tracked in that repo since it's a project-specific Dockerfile change, not VM baseline config.
