# Bitwarden Secrets Manager (bws) Primer

## Overview

`bws` is the CLI for Bitwarden **Secrets Manager** — a separate product from the regular Bitwarden password vault, meant for machine/service credentials (registry PATs, API keys, DB passwords) rather than personal logins. `prod.sh` and `dev.sh` both install it so deploy-time secrets never have to sit in a plaintext `.env` file or get typed into an interactive prompt that persists to disk. This doc covers the one-time web-vault setup (project, machine account, access token — none of which the CLI itself can bootstrap), the core `project`/`secret`/`run` commands, and the two patterns this repo actually uses them for: authenticating to a container registry without persisting the credential, and injecting Compose secrets without a checked-in `.env`. If you're looking for the personal-vault CLI instead (unlocking your own vault, `bw get item`, etc.), that's `bw` — a different binary, installed alongside `bws` but unrelated to it.

## Table of Contents

- [Overview](#overview)
- [`bw` vs `bws` — don't confuse them](#bw-vs-bws-dont-confuse-them)
- [One-time setup (web vault)](#one-time-setup-web-vault)
- [Authenticating the CLI](#authenticating-the-cli)
- [Core commands](#core-commands)
  - [`project`](#project)
  - [`secret`](#secret)
  - [`run` — the one you'll actually use](#run-the-one-youll-actually-use)
- [Applied patterns for this repo](#applied-patterns-for-this-repo)
  - [Registry login without a persisted credential](#registry-login-without-a-persisted-credential)
  - [Compose deploy secrets, no `.env` on disk](#compose-deploy-secrets-no-env-on-disk)
- [Output formats](#output-formats)
- [Gotchas](#gotchas)
- [Where this fits in the repo](#where-this-fits-in-the-repo)

## `bw` vs `bws` — don't confuse them

- **`bw`** — the personal password-manager CLI. Unlocks *your* vault, reads *your* items. Interactive, session-token based (`bw unlock`, `bw login`).
- **`bws`** — the Secrets Manager CLI. Reads secrets from a shared **project** that a **machine account** has been granted access to. No unlock step, no session — it's authenticated per-invocation by a long-lived access token. This is the one for server-side automation; `bw` is not.

They're separate Bitwarden products with separate binaries, separate auth models, and separate mental models. Both happen to get installed on dev/prod hosts by this repo's scripts, which is the only reason they're ever mentioned together.

## One-time setup (web vault)

`bws` cannot bootstrap its own credentials — the access token has to come from the web vault first. Do this once per project you want a machine to read from:

1. Log into the Bitwarden web vault, go to your organization's **Secrets Manager**.
2. Create a **project** (e.g. `acme-prod`) — this is the container secrets get grouped into.
3. Create a **machine account**, and grant it access to that project (read, or read/write if this box will also be creating secrets).
4. Generate an **access token** for the machine account, scoped to that project. **It is shown exactly once** — copy it immediately, there's no way to retrieve it again later (you'd have to generate a new one).

None of this has a CLI equivalent — it's web-vault-only by design, so a leaked `bws` binary or compromised host can't mint its own credentials.

## Authenticating the CLI

No `bws login` / `bws logout` — every command just needs the access token, via either:

```bash
export BWS_ACCESS_TOKEN=<token>          # for the rest of the shell session
```

or per-command:

```bash
bws <command> --access-token <token>
```

**Don't hardcode the token in `.bashrc`** — that defeats a good chunk of the point. If you want it to survive reconnects, put it in a file only you can read (`chmod 600`) and export it explicitly when needed, rather than sourcing it unconditionally on every login.

## Core commands

### `project`

| Action | Command |
|---|---|
| Create | `bws project create <NAME>` |
| List | `bws project list` |
| Get | `bws project get <PROJECT_ID>` |
| Rename | `bws project edit <PROJECT_ID> --name <NEW_NAME>` |
| Delete | `bws project delete <PROJECT_ID> [<PROJECT_ID> ...]` |

### `secret`

| Action | Command |
|---|---|
| Create | `bws secret create <KEY> <VALUE> <PROJECT_ID> [--note <NOTE>]` |
| List | `bws secret list [PROJECT_ID]` |
| Get | `bws secret get <SECRET_ID>` |
| Edit | `bws secret edit <SECRET_ID> [--key <KEY>] [--value <VALUE>] [--note <NOTE>] [--project-id <PROJECT_ID>]` |
| Delete | `bws secret delete <SECRET_ID> [<SECRET_ID> ...]` |

`create`/`edit`/`get`/`delete` all take **IDs**, not names — `bws secret list` is how you find a secret's ID when you only remember its key.

### `run` — the one you'll actually use

```bash
bws run --project-id <PROJECT_ID> -- <command>
```

Injects every secret in the project as an environment variable into `<command>`'s process only — never written to disk, never in shell history, gone the moment the subprocess exits. This is the command that matters day to day; `project`/`secret` subcommands above are setup and bookkeeping.

Useful flags:

| Flag | Purpose |
|---|---|
| `--project-id <UUID>` | Limit injected secrets to one project (omit to pull every project the token can see) |
| `--shell <shell>` | Override the shell used to run the command |
| `--no-inherit-env` | Start from a minimal environment (still keeps `$PATH`) instead of inheriting the current shell's env |
| `--uuids-as-keynames` | Use the secret's UUID as the env var name instead of its key — needed if the key isn't a POSIX-compliant identifier |

Wrap multi-part commands in single quotes so the shell doesn't try to interpret pipes/redirects *before* `bws run` sets up the environment:

```bash
bws run --project-id <id> -- bash -c 'echo "$MY_SECRET" | some-command'
```

## Applied patterns for this repo

### Registry login without a persisted credential

`docker login` writes the credential to `~/.docker/config.json` as base64 (not encrypted) the moment it succeeds, and leaves it there indefinitely. Route the PAT through `bws` so it never touches shell history on the way in, then strip the resulting file entry back out immediately after:

```bash
bws run --project-id <id> -- bash -c \
  'echo "$GHCR_PAT" | docker login ghcr.io -u <github-username> --password-stdin'

# ... do the pull/deploy that needed the login ...

docker logout ghcr.io   # removes the persisted entry from ~/.docker/config.json
```

`GHCR_PAT` above is whatever key you used in `bws secret create` — match it exactly, `bws run` exposes secrets under their stored key names by default.

### Compose deploy secrets, no `.env` on disk

Instead of a `.env` file sitting next to `compose.yaml` (a full-secrets read behind one `cat` for anything that compromises the account the app runs under — which, for rootless Docker, is the same account the daemon itself runs as):

```bash
bws run --project-id <id> -- docker compose up -d
```

Compose picks up the injected env vars the same way it would a `.env` file, as long as your `compose.yaml` references them (`environment:` / `${VAR}` interpolation). Nothing is ever written to a secrets file on the host.

## Output formats

`-o, --output <format>` on any read command: `json` (default), `yaml`, `table`, `tsv`, `none`, or `env` (`KEY=VALUE` lines — non-POSIX key names get commented out). `table` is the fastest to eyeball when you just want to check what's in a project:

```bash
bws secret list <project-id> --output table
```

## Gotchas

- **Env var names must be POSIX-compliant** for most shells to consume them cleanly. If a secret's key isn't (spaces, leading digits, etc.), either rename the key or use `--uuids-as-keynames` and reference secrets by UUID instead.
- **Syntax changed in Secrets Manager 0.3.0**: old docs/blog posts may show `bws list secrets` / `bws get secret <id>` — current syntax is `bws secret list` / `bws secret get <id>`. If a command from an older guide doesn't work, this is almost certainly why.
- **A local state file** (`~/.config/bws/state`) caches encrypted auth state to cut down on rate limiting. Harmless to delete if you ever need to force a clean re-auth; `bws` regenerates it.
- **Access tokens are project-scoped at creation time**, not adjustable after the fact from the CLI — if a machine account needs access to a new project, that's another web-vault trip, not a `bws` command.

## Where this fits in the repo

`bws` is installed identically by `prod.sh` (§2/2) and `dev.sh` (§7/8) — intentionally duplicated per this repo's no-shared-`lib/` install model (see [`CLAUDE.md`](../CLAUDE.md) editing guardrails). `driftcheck.md` tracks keeping both copies in sync. This doc is the "how do I actually use the thing" reference; `driftcheck.md` is "how do I keep the install steps from drifting between the two scripts."
