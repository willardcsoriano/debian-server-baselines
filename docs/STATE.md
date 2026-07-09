# STATE.md

## Overview

Repo-scoped working notes that supplement [`CLAUDE.md`](CLAUDE.md). `CLAUDE.md` holds stable guidance (how the codebase works, editing rules); this file holds open follow-ups and conventions that aren't yet codified there. Move items into `CLAUDE.md` when they harden into stable rules; delete them when resolved. This is a **snapshot**, rewritten in place each session — history lives in git, not here.

## Table of Contents

- [Overview](#overview)
- [Next session pickup](#next-session-pickup)
  - [Live target: acme-prod](#live-target-acme-prod)
  - [Open decision: inline vs pre-commit hook for duplicated install blocks](#open-decision-inline-vs-pre-commit-hook-for-duplicated-install-blocks)
  - [Other open items](#other-open-items)
  - [Context worth preserving (don't re-derive next session)](#context-worth-preserving-dont-re-derive-next-session)
- [Open follow-ups](#open-follow-ups)

## Next session pickup

*Last updated: 2026-07-09.* Current `origin/main` tip: `997adfc` (fix(base): install aide-common so AIDE actually initializes, #4). Repo layout: `base-server.sh` (base, 20 sections) + `prod-server.sh` (2 sections: rootless Docker + Compose, Bitwarden Secrets Manager CLI) + `dev-server.sh` (8 sections) + `syslog-baseline.sh` (log receiver) + `wireguard-baseline.sh` (WireGuard peer). Docs live under `docs/`.

**Install model is public `curl | bash` again.** The repo went back to public at some point after the last STATE.md update — `README.md` now has an explicit per-script curl one-liner for all five scripts (added this session; previously only base and dev had one, the rest said "swap the filename"). The old "private repo, git-clone-only" note from a prior snapshot is stale and wrong — ignore it, and ignore any reference to the memory file it pointed at (`~/.claude/projects/-home-willard-repos-debian-baseline/memory/...` — that path is under the repo's *old* name; it was renamed to `debian-server-baselines` and current project memory lives under the matching `-home-willard-repos-debian-server-baselines` path).

One practical wrinkle with public curl: `raw.githubusercontent.com` rate-limits by source IP (429), which has hit the live target below twice — usually a shared-NAT/cloud-egress issue, not a repo problem. `git clone` (goes through `github.com`, a different bucket) is the reliable fallback; mentioned in README-adjacent troubleshooting but not written down anywhere in-repo yet.

### Live target: acme-prod

Real production VM this repo is actively hardening: `acme-prod` (203.0.113.10, SSH alias `acme-prod`, Hetzner/Singapore, sudo user `willard`). App is a marketing site + ERP — not latency-sensitive; users are in the Philippines. Treat script changes as production-affecting, not theoretical.

**Status:** `base-server.sh` run successfully multiple times — Lynis hardening index **83**, all 20 sections clean, AIDE genuinely initialized (was silently broken across the script's entire history until this session's fix — see below). **`prod-server.sh` has not been run on it yet — that's the next action.**

**Open question, needs a human check:** Lynis flagged `KRNL-5830` (reboot needed) after the `PKGS-7346` rc-state cleanup (added this session) purged an old kernel package. It's unconfirmed whether the VM was actually rebooted afterward before continuing. Check `uptime` on the box before assuming this is resolved — if not rebooted, do it before `prod-server.sh` (nothing is deployed to Docker yet, so it's still the cheapest possible time).

### Open decision: inline vs pre-commit hook for duplicated install blocks

Two blocks are now inlined and duplicated across `prod-server.sh` + `dev-server.sh`: the rootless Docker install (`prod-server.sh` 1/2, `dev-server.sh` 1/8) and, as of this session, the Bitwarden Secrets Manager CLI (`bws`) install (`prod-server.sh` 2/2, `dev-server.sh` 7/8). `DRIFTCHECK.md` §1 and §2 are the manual sync mechanism for each; `CLAUDE.md` editing guardrails require lockstep edits.

This session found a real crack in the manual-sync approach: `DRIFTCHECK.md`'s Docker drift-diff command (`sed -n '/^# DRIFT:/,/^pass /p'`) silently broke the moment `prod-server.sh` grew a second `# DRIFT:` block (for `bws`) — it re-triggered on every DRIFT/pass pair in the file instead of isolating just Docker's, producing a misleading false-positive diff. Fixed in `626032e` by anchoring on literal Docker-specific text, but it's exactly the class of drift a pre-commit hook would catch mechanically instead of relying on someone noticing mid-audit.

A `lib/docker-rootless.sh` was tried mid-refactor once, reverted before commit. The self-containment rule stands regardless of install model (public curl or private clone): each script must run individually without depending on siblings — that rules out `source ./lib/…`, not reproducibility via a hook.

The parked proposal that would give mechanical reproducibility without giving up the one-liner install:

- Wrap each duplicated block with explicit markers, e.g. `# >>> DOCKER-ROOTLESS-INSTALL >>>` / `# <<< DOCKER-ROOTLESS-INSTALL <<<`, and the equivalent for `bws`.
- Add `.githooks/pre-commit` that `sed`-extracts each block from both scripts and `diff`s them — fails the commit if they've drifted.
- Wire with `git config core.hooksPath .githooks` (one-time per checkout).
- Update `CLAUDE.md` editing guardrails: "if you change Docker or bws in one script, the pre-commit hook will refuse the commit unless the other matches."
- Update `DRIFTCHECK.md` §1/§2: replace the manual `diff` instructions with "the pre-commit hook handles this; an unexpected fire is the signal."

Same hook pattern already used in the `claude-config` repo (commit-msg + secrets pre-commit), so the shape is familiar. Tradeoff: hook is *local* enforcement only — fine for a personal-maintainer repo, weaker if outside contributors ever show up (then back it with CI).

**Decision pending, now with more evidence in favor of the hook** — the manual method has visibly broken once already. Lean in fresh and pick.

### Other open items

1. **Pre-existing broken link.** `DRIFTCHECK.md` § Overview references a `DRIFT.md` ("General drift methodology lives in `DRIFT.md`") that doesn't exist in the repo. Either create it, drop the reference, or repoint it.

2. **Stray branches, likely cleanup candidates.** `feat/dev-server-gemini-cli` (local + `origin`), `feat/antigravity-cli` (`origin`), and `feat/ufw-cidr-auditd-execve` (`origin`) all correspond to work already merged into `main` (PRs #2 and #3, plus an earlier pre-session branch) but weren't deleted after merge. Verify each is fully merged (`git branch --merged main`), then `git branch -d <name>` locally and `git push origin --delete <name>` remotely. Not urgent — just hygiene, and a destructive-ish action worth confirming before running.

3. **Possible future direction, not decided:** if container-specific security posture is ever wanted (auditing the Docker daemon/container config itself, not just the OS), Lynis isn't the right tool — it doesn't inspect running containers or images. Docker Bench for Security was floated as the fitting tool for that *if* it comes up, but explicitly **not** added to `prod-server.sh` this session (would just re-run the OS-level Lynis audit for near-zero new signal, violating the same extraction-threshold precedent as the deleted `remote-syslog.sh`). Only pursue if the user explicitly asks for container-level auditing specifically.

### Context worth preserving (don't re-derive next session)

- **Why role-oriented and not tool-oriented:** role scripts (`prod-server.sh`, `dev-server.sh`) were picked over factoring tools (`docker.sh`, `node.sh`, ...) because the user-side mental model is "what kind of server am I spinning up?", not "which tools do I want?". A maintainer's DRY win wasn't worth a user's clarity loss.
- **Why `remote-syslog.sh` was deleted** (vs left dormant): it functionally duplicated baseline section 20 with no growth path the section couldn't absorb — the extraction-threshold violation called out in `CLAUDE.md` ("an extracted file that mirrors the in-baseline section is churn, not signal"). The sender side stays in section 20 forever; the only file that earns its own slot is the receiver (`syslog-baseline.sh`), qualitatively different work. This same precedent is why Lynis was *not* added to `prod-server.sh` this session (see above).
- **Why rootless Docker is the deliberate default, not rootful:** `docker` group membership is root-equivalent (any member can bind-mount host `/` via the daemon socket, no exploit needed) — rootless closes that specific hole via user-namespace remapping, at the cost of userspace-networking overhead (`slirp4netns`). Considered and rejected switching the network backend to `pasta`: it's labeled *experimental* by RootlessKit itself (vs `slirp4netns`'s *recommended*), needs explicit config wiring (not auto-detected), and the target workload (marketing site + ERP, PH users, SG host) is nowhere near latency-sensitive enough for the throughput difference to matter. Not revisiting unless the workload profile changes.
- **Why `bws` was added to `prod-server.sh` this session:** a plaintext `.env` sitting next to a compose file is a full-secrets read behind one `cat` for anyone who compromises the account the app runs under (which, for rootless Docker, *is* the account the daemon itself runs as). `bws run --project-id <id> -- docker compose up -d` injects secrets as env vars into the child process only, never touching disk. Installed identically to `dev-server.sh`'s existing `bws` (same DRIFT-verified install logic, checksum-verified), duplicated per the Docker precedent above.
- **The AIDE bug (found + fixed this session, `997adfc`):** `base-server.sh` installed `aide` but never `aide-common` — the package that actually ships `/etc/aide/aide.conf` and the `aideinit` script. Both `aideinit` and the `aide --init` fallback failed silently (stderr suppressed), and the script printed `pass "AIDE database initialized"` **unconditionally**, regardless of whether a database was ever produced. Confirmed live on `acme-prod`: `/var/lib/aide/` didn't exist at all despite every prior run claiming success. Fix installs `aide-common` and makes the success message conditional on the database file actually existing, `warn`-ing otherwise. **Implication:** any server previously hardened with a pre-`997adfc` version of this script likely has the same silent gap — worth checking (`ls -la /var/lib/aide/`) on any other box this repo has touched.
- **Lynis score philosophy** (already in `docs/WALKTHROUGH.md`, worth restating so it isn't re-litigated): 70+ is decent, 80s is well-hardened, 90+ usually requires real usability tradeoffs (separate partitions, GRUB password, non-standard SSH port) that this repo deliberately declines — see the Deliberate Gaps table in `WALKTHROUGH.md`. The number is a proxy, not the goal. Lynis distinguishes **warnings** (score-relevant, need action) from **suggestions** (advisory, don't move the score) — always check `sudo grep '^warning' /var/log/lynis-report.dat` specifically, not the full suggestion dump, when deciding what's worth chasing.

## Open follow-ups

- **UMASK 027 ↔ Docker bind-mount interaction.** See [`docs/reports/docker-umask-bind-mount-interaction.md`](docs/reports/docker-umask-bind-mount-interaction.md). The "What `base-server` could add" section proposes either a preflight note for Docker users or a CLAUDE.md sidebar covering the umask × `USERGROUPS_ENAB` × container-UID collision. Not yet implemented.
