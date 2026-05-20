# STATE.md

## Table of Contents

- [Open follow-ups](#open-follow-ups)
- [Conventions not yet in CLAUDE.md](#conventions-not-yet-in-claudemd)

Repo-scoped working notes that supplement [`CLAUDE.md`](CLAUDE.md). `CLAUDE.md` holds stable guidance (how the codebase works, editing rules); this file holds open follow-ups and conventions that aren't yet codified there. Move items into `CLAUDE.md` when they harden into stable rules; delete them when resolved.

## Open follow-ups

- **UMASK 027 ↔ Docker bind-mount interaction.** See [`docs/reports/docker-umask-bind-mount-interaction.md`](docs/reports/docker-umask-bind-mount-interaction.md). The "What `debian-baseline` could add" section proposes either a preflight note for Docker users or a CLAUDE.md sidebar covering the umask × `USERGROUPS_ENAB` × container-UID collision. Not yet implemented.
- **`remote-syslog.sh` is undocumented by design.** Committed in `b1ba545` but intentionally absent from `README.md` and `CLAUDE.md`. Today it duplicates `baseline.sh` section 20 behavior. Surface and document only once it grows features (TLS/relp, multiple receivers, schema rewrites) that the in-baseline section can't reasonably absorb.

## Conventions not yet in CLAUDE.md

- **Extraction threshold for optional sections.** Optional sections stay in `baseline.sh` with a `[y/N]` preflight prompt — the Cockpit/Netdata pattern. Pull a section out into its own script only when the new home will grow features that would bloat baseline. "It's a placeholder for later" is not enough justification — an extracted file that mirrors the in-baseline section is churn, not signal. Once a rule like this stops being revisited, fold it into `CLAUDE.md`'s "Architecture and conventions" section and remove it here.
