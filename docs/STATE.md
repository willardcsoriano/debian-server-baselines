# STATE.md

## Overview

Repo-scoped working notes that supplement [`CLAUDE.md`](CLAUDE.md). `CLAUDE.md` holds stable guidance (how the codebase works, editing rules); this file holds open follow-ups and conventions that aren't yet codified there. Move items into `CLAUDE.md` when they harden into stable rules; delete them when resolved.

## Table of Contents

- [Overview](#overview)
- [Next session pickup](#next-session-pickup)
  - [Open decision: inline vs pre-commit hook for the Docker block](#open-decision-inline-vs-pre-commit-hook-for-the-docker-block)
  - [Other open items](#other-open-items)
  - [Context worth preserving (don't re-derive next session)](#context-worth-preserving-dont-re-derive-next-session)
- [Open follow-ups](#open-follow-ups)

## Next session pickup

This block exists so a future session can resume cold. Current `origin/main` tip: `e735af9` (docs(readme): move quick reference to a table above overview). Repo layout: `base-server.sh` (base) + `prod-server.sh` + `dev-server.sh` + `syslog-baseline.sh` (log receiver) + `wireguard-baseline.sh` (WireGuard peer). Docs live under `docs/`. Install model is **git clone + bash** (private repo — curl|bash was dropped in `cd225c4`).

### Open decision: inline vs pre-commit hook for the Docker block

The rootless Docker install (~70 lines) is currently **inlined and duplicated** between `prod-server.sh` (section 1/1) and `dev-server.sh` (section 1/5). `DRIFTCHECK.md` § 1 is the (manual) sync mechanism; `CLAUDE.md` editing guardrails require lockstep edits.

A `lib/docker-rootless.sh` was tried mid-refactor and reverted before commit. The install model has since changed to **git clone + bash** (private repo), but the self-containment rule still stands: each script must run individually without depending on siblings. That rules out a `source ./lib/…` approach; it does **not** rule out reproducibility.

The parked proposal that would give mechanical reproducibility without giving up the one-liner install:

- Wrap both Docker blocks with explicit markers: `# >>> DOCKER-ROOTLESS-INSTALL >>>` and `# <<< DOCKER-ROOTLESS-INSTALL <<<`.
- Add `.githooks/pre-commit` that `sed`-extracts the block from each script and `diff`s them — fails the commit if they've drifted.
- Wire with `git config core.hooksPath .githooks` (one-time per checkout).
- Update `CLAUDE.md` editing guardrails: "if you change Docker in one script, the pre-commit hook will refuse the commit unless the other matches."
- Update `DRIFTCHECK.md` § 1: replace the manual `diff` instruction with "the pre-commit hook handles this; an unexpected fire is the signal."

You already use this same hook pattern in your `claude-config` repo (commit-msg + secrets pre-commit), so the shape is familiar. Tradeoff: hook is *local* enforcement only — fine for a personal-maintainer repo, weaker if you ever take outside contributors (then back it with CI).

**Decision pending.** "Inline as-is" and "add the hook" are both defensible. Lean in fresh and pick.

### Other open items

1. **`shellcheck` was not run** in the session that added `wireguard-baseline.sh` and updated `syslog-baseline.sh`. The dev host didn't have it installed. All scripts pass `bash -n`. Full static analysis: `sudo apt install -y shellcheck`, then run the lint block in `CLAUDE.md` § "Working with the scripts".

2. **Pre-existing broken link.** `DRIFTCHECK.md` § Overview references a `DRIFT.md` ("General drift methodology lives in `DRIFT.md`") that doesn't exist in the repo. Either create it, drop the reference, or repoint it.

3. **GitHub vs GitLab: stay on GitHub.** Discussed in session ending `e735af9`. The "not doing well" content (AI training controversy, Microsoft ownership) doesn't affect a private repo. No action required; revisit only if pricing or a concrete incident changes the calculus.

### Context worth preserving (don't re-derive next session)

- **Why role-oriented and not tool-oriented:** we picked role scripts (`prod-server.sh`, `dev-server.sh`) over factoring tools (`docker.sh`, `node.sh`, ...) because the user-side mental model is "what kind of server am I spinning up?", not "which tools do I want?". A maintainer's DRY win wasn't worth a user's clarity loss.
- **Install model is git clone + bash (private repo):** curl|bash was dropped when the repo went private (`cd225c4`). Scripts are still individually self-contained — no `source ./lib/…`, no runtime curl of siblings — but there are no public one-liner URLs. See `~/.claude/projects/-home-willard-repos-debian-baseline/memory/install-model-curl-bash.md`.
- **Why `remote-syslog.sh` was deleted** (vs left dormant): it functionally duplicated baseline section 20 with no growth path the section couldn't absorb, which is the extraction-threshold violation called out in CLAUDE.md ("an extracted file that mirrors the in-baseline section is churn, not signal"). The sender side stays in section 20 forever; the only file that earns its own slot is the receiver (`syslog-baseline.sh`), which is qualitatively different work.

## Open follow-ups

- **UMASK 027 ↔ Docker bind-mount interaction.** See [`docs/reports/docker-umask-bind-mount-interaction.md`](docs/reports/docker-umask-bind-mount-interaction.md). The "What `base-server` could add" section proposes either a preflight note for Docker users or a CLAUDE.md sidebar covering the umask × `USERGROUPS_ENAB` × container-UID collision. Not yet implemented.
