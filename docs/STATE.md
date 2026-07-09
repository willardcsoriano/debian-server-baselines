# STATE.md

## Overview

Repo-scoped working notes that supplement [`CLAUDE.md`](CLAUDE.md). `CLAUDE.md` holds stable guidance (how the codebase works, editing rules); this file holds open follow-ups and conventions that aren't yet codified there. Move items into `CLAUDE.md` when they harden into stable rules; delete them when resolved. This is a **snapshot**, rewritten in place each session — history lives in git, not here.

## Table of Contents

- [Overview](#overview)
- [Next session pickup](#next-session-pickup)
  - [Live target: acme-prod](#live-target-acme-prod)
  - [Repo housekeeping: an open PR that's now superseded](#repo-housekeeping-an-open-pr-thats-now-superseded)
  - [Open decision: inline vs pre-commit hook for duplicated install blocks](#open-decision-inline-vs-pre-commit-hook-for-duplicated-install-blocks)
  - [Other open items](#other-open-items)
  - [Context worth preserving (don't re-derive next session)](#context-worth-preserving-dont-re-derive-next-session)
- [Open follow-ups](#open-follow-ups)

## Next session pickup

*Last updated: 2026-07-09.* Current `origin/main` tip: `c8d8ffb` (docs(prod): note docker login persists a credential to disk, #5). Repo layout: `base.sh` (base, 20 sections) + `prod.sh` (2 sections: rootless Docker + Compose, Bitwarden Secrets Manager CLI) + `dev.sh` (8 sections) + `syslog.sh` (log receiver) + `wireguard.sh` (WireGuard peer). Docs live under `docs/`.

**Install model is public `curl | bash` again.** The repo went back to public at some point after an earlier STATE.md snapshot — `README.md` has an explicit per-script curl one-liner for all five scripts. If you see any note claiming "private repo, git-clone-only" elsewhere (including an orphaned memory file under the repo's *old* name, `-home-willard-repos-debian-baseline`), it's stale — ignore it. Current project memory lives under the matching `-home-willard-repos-debian-server-baselines` path.

One practical wrinkle: `raw.githubusercontent.com` rate-limits by source IP (429) — hit the live target below twice. Usually a shared-NAT/cloud-egress issue, not a repo problem. `git clone` (goes through `github.com`, a different bucket) is the reliable fallback.

### Live target: acme-prod

Real production VM this repo is actively hardening and deploying to: `acme-prod` (203.0.113.10, SSH alias `acme-prod`, Hetzner/Singapore, sudo user `willard`). App is a marketing site + ERP — not latency-sensitive; users are in the Philippines. Treat script changes as production-affecting, not theoretical.

**Status:**
- `base.sh`: run successfully multiple times — Lynis hardening index **83**, all 20 sections clean, AIDE genuinely initialized (was silently broken across the script's entire history until this session's fix — see below).
- `prod.sh`: **run successfully** — rootless Docker + Compose installed and daemon active, `bws` 2.1.0 installed. Note: RootlessKit picked `gvisor-tap-vsock` as the network driver, not `slirp4netns` as assumed earlier in this session's design discussion — harmless either way for this non-latency-sensitive workload, just correcting the record.
- **App deployment: not yet done, likely mid-flow.** The session ended partway through `docker login ghcr.io` — the user was at the username/password (PAT) prompt, discussing whether/how to avoid persisting the registry credential to disk, and it's unconfirmed whether login was completed or `docker compose up` ever ran. **Next action: check whether `docker login` succeeded and pick up the actual app deploy from there** — registry auth, then `bws run --project-id <id> -- docker compose up -d` (or plain `docker compose pull && up -d` if not wiring up `bws` secrets yet).

**Open question, needs a human check — still unresolved across two sessions now:** Lynis flagged `KRNL-5830` (reboot needed) after the `PKGS-7346` rc-state cleanup purged an old kernel package. Never confirmed whether the VM was actually rebooted. Check `uptime` before doing anything else on this box — if not rebooted, it's a judgment call now whether to reboot given Docker is live (rootless daemon has linger enabled, so it survives a reboot fine, but any containers you've since started would need to come back up).

### Repo housekeeping: an open PR that's now superseded

`docs/state-snapshot-refresh` (PR [#6](https://github.com/willardcsoriano/debian-server-baselines/pull/6)) carries an earlier version of *this same file* from a prior snapshot in this session — it's now stale relative to what's written here. Also discovered while shipping it: this repo doesn't have GitHub's "Allow auto-merge" setting enabled, so `gh pr merge --auto` errors instead of queuing (`/ship`'s default mode needs it; `now` mode doesn't). Recommend: close PR #6 without merging (its content is superseded), then ship this version fresh — or just merge #6 first and let this snapshot land as an immediate follow-up diff, either works. Worth deciding on the auto-merge repo setting once, too, so future `/ship` runs don't hit the same wall.

### Open decision: inline vs pre-commit hook for duplicated install blocks

Two blocks are now inlined and duplicated across `prod.sh` + `dev.sh`: the rootless Docker install (`prod.sh` 1/2, `dev.sh` 1/8) and, as of this session, the Bitwarden Secrets Manager CLI (`bws`) install (`prod.sh` 2/2, `dev.sh` 7/8). `DRIFTCHECK.md` §1 and §2 are the manual sync mechanism for each; `CLAUDE.md` editing guardrails require lockstep edits.

This session found a real crack in the manual-sync approach: `DRIFTCHECK.md`'s Docker drift-diff command (`sed -n '/^# DRIFT:/,/^pass /p'`) silently broke the moment `prod.sh` grew a second `# DRIFT:` block (for `bws`) — it re-triggered on every DRIFT/pass pair in the file instead of isolating just Docker's, producing a misleading false-positive diff. Fixed in `626032e` by anchoring on literal Docker-specific text, but it's exactly the class of drift a pre-commit hook would catch mechanically instead of relying on someone noticing mid-audit.

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

2. **Stray branches, likely cleanup candidates.** `feat/dev-server-gemini-cli` (local + `origin`), `feat/antigravity-cli` (`origin`), and `feat/ufw-cidr-auditd-execve` (`origin`) all correspond to work already merged into `main` (PRs #2 and #3, plus an earlier pre-session branch) but weren't deleted after merge. Verify each is fully merged (`git branch --merged main`), then `git branch -d <name>` locally and `git push origin --delete <name>` remotely. Not urgent — just hygiene.

3. **GitHub repo setting: enable "Allow auto-merge".** Settings → General → Pull Requests. Without it, `/ship`'s default (merge-when-green) mode errors on every PR in this repo; only `now` mode works, or manual merges. One-time fix.

4. **Possible future direction, not decided:** if container-specific security posture is ever wanted (auditing the Docker daemon/container config itself, not just the OS), Lynis isn't the right tool — it doesn't inspect running containers or images. Docker Bench for Security was floated as the fitting tool for that *if* it comes up, but explicitly **not** added to `prod.sh` (would just re-run the OS-level Lynis audit for near-zero new signal, violating the same extraction-threshold precedent as the deleted `remote-syslog.sh`). Only pursue if the user explicitly asks for container-level auditing specifically.

### Context worth preserving (don't re-derive next session)

- **Why role-oriented and not tool-oriented:** role scripts (`prod.sh`, `dev.sh`) were picked over factoring tools (`docker.sh`, `node.sh`, ...) because the user-side mental model is "what kind of server am I spinning up?", not "which tools do I want?". A maintainer's DRY win wasn't worth a user's clarity loss.
- **Why `remote-syslog.sh` was deleted** (vs left dormant): it functionally duplicated baseline section 20 with no growth path the section couldn't absorb — the extraction-threshold violation called out in `CLAUDE.md` ("an extracted file that mirrors the in-baseline section is churn, not signal"). The sender side stays in section 20 forever; the only file that earns its own slot is the receiver (`syslog.sh`), qualitatively different work. This same precedent is why Lynis was *not* added to `prod.sh`.
- **Why rootless Docker is the deliberate default, not rootful:** `docker` group membership is root-equivalent (any member can bind-mount host `/` via the daemon socket, no exploit needed) — rootless closes that specific hole via user-namespace remapping, at the cost of userspace-networking overhead. Considered and rejected switching the network backend to `pasta`: it's labeled *experimental* by RootlessKit itself, needs explicit config wiring, and the target workload (marketing site + ERP, PH users, SG host) is nowhere near latency-sensitive enough for a throughput difference to matter. (In practice, this Docker version defaulted to `gvisor-tap-vsock` anyway, without either of us configuring it — also fine, same reasoning applies.) Not revisiting unless the workload profile changes.
- **Why `bws` was added to `prod.sh`:** a plaintext `.env` sitting next to a compose file is a full-secrets read behind one `cat` for anyone who compromises the account the app runs under (which, for rootless Docker, *is* the account the daemon itself runs as). `bws run --project-id <id> -- docker compose up -d` injects secrets as env vars into the child process only, never touching disk. Installed identically to `dev.sh`'s existing `bws`, duplicated per the Docker precedent above.
- **`docker login` has the same at-rest-secret problem, now documented (`c8d8ffb`):** it persists the registry credential to `~/.docker/config.json` as base64 (not encrypted), indefinitely, by default. `prod.sh`'s summary and `README.md` now both note wrapping it with `bws` + `docker logout` for a leaner footprint — surfaced live while walking the user through their first real deploy.
- **The AIDE bug (found + fixed, `997adfc`):** `base.sh` installed `aide` but never `aide-common` — the package that actually ships `/etc/aide/aide.conf` and the `aideinit` script. Both `aideinit` and the `aide --init` fallback failed silently (stderr suppressed), and the script printed `pass "AIDE database initialized"` **unconditionally**, regardless of whether a database was ever produced. Confirmed live on `acme-prod`: `/var/lib/aide/` didn't exist at all despite every prior run claiming success. Fix installs `aide-common` and makes the success message conditional on the database file actually existing, `warn`-ing otherwise. **Implication:** any server previously hardened with a pre-`997adfc` version of this script likely has the same silent gap — worth checking (`ls -la /var/lib/aide/`) on any other box this repo has touched.
- **Lynis score philosophy** (already in `docs/WALKTHROUGH.md`, worth restating so it isn't re-litigated): 70+ is decent, 80s is well-hardened, 90+ usually requires real usability tradeoffs (separate partitions, GRUB password, non-standard SSH port) that this repo deliberately declines. The number is a proxy, not the goal. Lynis distinguishes **warnings** (score-relevant, need action) from **suggestions** (advisory, don't move the score) — always check `sudo grep '^warning' /var/log/lynis-report.dat` specifically, not the full suggestion dump, when deciding what's worth chasing.

## Open follow-ups

- **UMASK 027 ↔ Docker bind-mount interaction.** See [`docs/reports/docker-umask-bind-mount-interaction.md`](docs/reports/docker-umask-bind-mount-interaction.md). The "What `base.sh` could add" section proposes either a preflight note for Docker users or a CLAUDE.md sidebar covering the umask × `USERGROUPS_ENAB` × container-UID collision. Not yet implemented.
