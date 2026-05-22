# STATE.md

## Overview

Repo-scoped working notes that supplement [`CLAUDE.md`](CLAUDE.md). `CLAUDE.md` holds stable guidance (how the codebase works, editing rules); this file holds open follow-ups and conventions that aren't yet codified there. Move items into `CLAUDE.md` when they harden into stable rules; delete them when resolved.

## Table of Contents

- [Overview](#overview)
- [Next session pickup](#next-session-pickup)
  - [Open decision: inline vs pre-commit hook for the Docker block](#open-decision-inline-vs-pre-commit-hook-for-the-docker-block)
  - [Other open items from this session](#other-open-items-from-this-session)
  - [Context worth preserving (don't re-derive next session)](#context-worth-preserving-dont-re-derive-next-session)
- [Open follow-ups](#open-follow-ups)

## Next session pickup

This block exists so a future session can resume cold. The role-oriented script refactor landed in 7 commits ending `fa3947e`, all on `origin/main`. Repo layout is now: `debian-server-baseline.sh` (base) + `prod-server.sh` + `dev-server.sh` + `remote-syslog.sh` + `syslog-baseline.sh` (draft).

### Open decision: inline vs pre-commit hook for the Docker block

The rootless Docker install (~70 lines) is currently **inlined and duplicated** between `prod-server.sh` (section 1/1) and `dev-server.sh` (section 1/5). `DRIFTCHECK.md` § 1 is the (manual) sync mechanism; `CLAUDE.md` editing guardrails require lockstep edits.

A `lib/docker-rootless.sh` was tried mid-refactor and reverted before commit, because the install model is **one curl URL per script, no clone, no build step** (saved as `install-model-curl-bash.md` in `.claude` memory). That constraint rules out a *local* `lib/`; it does **not** rule out reproducibility.

The parked proposal that would give mechanical reproducibility without giving up the one-liner install:

- Wrap both Docker blocks with explicit markers: `# >>> DOCKER-ROOTLESS-INSTALL >>>` and `# <<< DOCKER-ROOTLESS-INSTALL <<<`.
- Add `.githooks/pre-commit` that `sed`-extracts the block from each script and `diff`s them — fails the commit if they've drifted.
- Wire with `git config core.hooksPath .githooks` (one-time per checkout).
- Update `CLAUDE.md` editing guardrails: "if you change Docker in one script, the pre-commit hook will refuse the commit unless the other matches."
- Update `DRIFTCHECK.md` § 1: replace the manual `diff` instruction with "the pre-commit hook handles this; an unexpected fire is the signal."

You already use this same hook pattern in your `claude-config` repo (commit-msg + secrets pre-commit), so the shape is familiar. Tradeoff: hook is *local* enforcement only — fine for a personal-maintainer repo, weaker if you ever take outside contributors (then back it with CI).

**Decision pending.** "Inline as-is" and "add the hook" are both defensible. Lean in fresh and pick.

### Other open items from this session

1. **GitHub repo rename: `debian-baseline` → `debian-server-baseline`** (UI action, not in this checkout). Until done, the `raw.githubusercontent.com/.../debian-server-baseline/...` URLs in `README.md` 404. GitHub auto-redirects the *repo* URL for clones and web; raw content URLs do **not** redirect after rename because both the path and the filename changed. Plan to do this right after pushing the 5 unpushed commits.

2. **`shellcheck` was not run.** `shellcheck` isn't installed on the dev host this session ran from. All four scripts pass `bash -n` syntax check. If you want full static analysis: `sudo apt install -y shellcheck`, then run the lint block in `CLAUDE.md` § "Working with the scripts".

3. **Syslog work is fully deferred per your call.** `syslog-baseline.sh` (the receiver-side draft) is still in the repo with its string refs synced to the new names (commit `c044f6b`). The actual rename to `syslog-server.sh` plus any content/feature work — TLS/relp, multi-receiver, schema rewrites, etc. — happens in its own session. Same with `remote-syslog.sh`: per the policy below, it stays as the dormant extracted forwarder until it grows features the in-baseline section 20 can't absorb.

4. **Pre-existing broken link (not from this refactor).** `DRIFTCHECK.md` § Overview references a `DRIFT.md` ("General drift methodology lives in `DRIFT.md`") that doesn't exist in the repo. Either create it, drop the reference, or repoint it — your call.

5. **Commits landed on `origin/main`** (most-recent first):
   - `fa3947e` docs: add next-session pickup notes to STATE.md
   - `0665490` docs: add ENV_STACK.md
   - `5dd0674` docs: align README/WALKTHROUGH/CLAUDE/STATE/DRIFTCHECK for role-oriented layout
   - `c044f6b` chore: sync stale baseline.sh references in syslog-baseline.sh
   - `091ee44` refactor: rename dev-baseline.sh → dev-server.sh
   - `30ea6f2` feat: add prod-server.sh for container-only prod hosts
   - `c06806e` chore: rename baseline.sh → debian-server-baseline.sh

6. **Bitwarden CLIs added to `dev-server.sh`** (follow-up session, verified end-to-end on a real Debian 13 host, idempotent on re-run, now on `origin/main`):
   - `c96e2e8` docs: record unpushed bw/bws commit in STATE.md pickup notes
   - `6931145` feat: add bw and bws to dev-server.sh — adds Bitwarden CLI (`bw`) and Bitwarden Secrets Manager CLI (`bws`) as sections 6/7 and 7/7, both as standalone binaries in `~/.local/bin` (the only install path that fits ENV_STACK's "no `npm -g`" rule and the baseline's mode-750 compilers). `bws` downloads are sha256-verified; `bw` has no equivalent checksum file published. PATH export to `~/.bashrc` is grep-guarded so it appends once.

### Context worth preserving (don't re-derive next session)

- **Why role-oriented and not tool-oriented:** we picked role scripts (`prod-server.sh`, `dev-server.sh`) over factoring tools (`docker.sh`, `node.sh`, ...) because the user-side mental model is "what kind of server am I spinning up?", not "which tools do I want?". A maintainer's DRY win wasn't worth a user's clarity loss.
- **Why curl|bash is non-negotiable:** see `~/.claude/projects/-home-willard-repos-debian-baseline/memory/install-model-curl-bash.md`. Every install is one curl URL per script. Don't propose clone-first, `lib/`-local, or build/bundle steps without flagging the constraint explicitly first.
- **Why `remote-syslog.sh` stays dormant** even though it now appears in README: it duplicates baseline section 20 today; surface as a *primary* role only once it grows features the in-baseline section can't absorb. Documenting it as "an optional log-forwarding helper" in README is the minimum disclosure, not promotion to primary role.

## Open follow-ups

- **UMASK 027 ↔ Docker bind-mount interaction.** See [`docs/reports/docker-umask-bind-mount-interaction.md`](docs/reports/docker-umask-bind-mount-interaction.md). The "What `debian-server-baseline` could add" section proposes either a preflight note for Docker users or a CLAUDE.md sidebar covering the umask × `USERGROUPS_ENAB` × container-UID collision. Not yet implemented.
