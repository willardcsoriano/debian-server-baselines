# STATE.md

## Overview

Repo-scoped working notes that supplement [`CLAUDE.md`](CLAUDE.md). `CLAUDE.md` holds stable guidance (how the codebase works, editing rules); this file holds open follow-ups and conventions that aren't yet codified there. Move items into `CLAUDE.md` when they harden into stable rules; delete them when resolved.

## Table of Contents

- [Overview](#overview)
- [Open follow-ups](#open-follow-ups)

## Open follow-ups

- **UMASK 027 ↔ Docker bind-mount interaction.** See [`docs/reports/docker-umask-bind-mount-interaction.md`](docs/reports/docker-umask-bind-mount-interaction.md). The "What `debian-server-baseline` could add" section proposes either a preflight note for Docker users or a CLAUDE.md sidebar covering the umask × `USERGROUPS_ENAB` × container-UID collision. Not yet implemented.
