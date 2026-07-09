# debian-server-baselines

## Quick Reference

| Script | Command | Purpose |
|---|---|---|
| Base | `sudo bash base-server.sh` | SSH, UFW, fail2ban, auditd, AIDE, AppArmor, Lynis — every server first |
| Prod | `bash prod-server.sh` | Rootless Docker + Compose, Bitwarden secrets CLI — container-only prod hosts |
| Dev | `bash dev-server.sh` | Node, Claude Code CLI, `gh`, `make`, Bitwarden — developer workstation |
| Syslog | `sudo bash syslog-baseline.sh` | rsyslog TCP 514 receiver, per-sender log buckets — central log host |
| WireGuard | `sudo bash wireguard-baseline.sh` | WireGuard keypair + peer management — server-to-server tunnel |

## Overview

Idempotent hardening and role-specific tooling for Debian 13 servers. Every server starts with the mandatory base (`base-server.sh`, 20 sections — SSH lockdown, UFW, fail2ban, auditd, AIDE, AppArmor, Lynis, kernel hardening) run as root. Then layer role scripts for each server's purpose: `prod-server.sh` (rootless Docker + Compose), `dev-server.sh` (Node, Claude Code CLI, `gh`, `make`, Bitwarden), `syslog-baseline.sh` (central log receiver), `wireguard-baseline.sh` (server-to-server encrypted tunnel). All scripts are idempotent — re-run any time to refresh.

## Table of Contents

- [Quick Reference](#quick-reference)
- [Overview](#overview)
- [Setup](#setup)
- [What the base does](#what-the-base-does)
- [Requirements](#requirements)
- [Role scripts](#role-scripts)
  - [prod-server.sh — container-only prod hosts](#prod-serversh-container-only-prod-hosts)
  - [dev-server.sh — developer workstation](#dev-serversh-developer-workstation)
  - [syslog-baseline.sh — central log receiver](#syslog-baselinesh-central-log-receiver)
  - [wireguard-baseline.sh — server-to-server tunnel](#wireguard-baselinesh-server-to-server-tunnel)
- [What happens](#what-happens)
- [Idempotent — safe to re-run](#idempotent-safe-to-re-run)
- [After it runs](#after-it-runs)

## Setup

Every script reads its prompts from `/dev/tty`, so both paths below behave identically — pick by whether the repo is public or private. Base, syslog, and WireGuard run as **root** (`sudo bash`); prod and dev run as your **sudo user** (plain `bash` — they escalate internally and refuse to run as root).

**Public repo — curl straight to bash, nothing to clone:**

```bash
# base — run as root:
curl -fsSL https://raw.githubusercontent.com/willardcsoriano/debian-server-baselines/main/base-server.sh | sudo bash

# prod — run as your sudo user (no sudo):
curl -fsSL https://raw.githubusercontent.com/willardcsoriano/debian-server-baselines/main/prod-server.sh | bash

# dev — run as your sudo user (no sudo):
curl -fsSL https://raw.githubusercontent.com/willardcsoriano/debian-server-baselines/main/dev-server.sh | bash

# syslog — run as root:
curl -fsSL https://raw.githubusercontent.com/willardcsoriano/debian-server-baselines/main/syslog-baseline.sh | sudo bash

# wireguard — run as root:
curl -fsSL https://raw.githubusercontent.com/willardcsoriano/debian-server-baselines/main/wireguard-baseline.sh | sudo bash
```

**Private repo — clone, then run locally:**

```bash
git clone git@github.com:willardcsoriano/debian-server-baselines.git
cd debian-server-baselines
sudo bash base-server.sh   # or, as your sudo user:  bash dev-server.sh
```

## What the base does

Most hardening scripts lock your server and disappear. This one installs the tools to keep it hardened — so you have ongoing visibility, not just a one-time configuration.

> Want a section-by-section walkthrough with verification commands and threat-model notes? See [WALKTHROUGH.md](docs/WALKTHROUGH.md).

| Step | What |
|---|---|
| System updates | Upgrades all installed packages to current versions |
| Automatic security updates | Installs `unattended-upgrades` so security patches apply on their own |
| Sudo user | Creates a non-root account and prompts for a sudo password (defense in depth — leaked SSH key alone can't escalate) |
| SSH key | Copies `/root/.ssh/authorized_keys` to the new user |
| SSH hardening | Disables root login and password auth, key-only, restricts forwarding/sessions |
| Firewall | UFW — ports 22, 80, 443 open; everything else denied |
| fail2ban | Bans IPs after 5 failed SSH attempts (1h ban) |
| Kernel hardening | sysctl — SYN flood, spoofing, redirect protection |
| AppArmor | Mandatory access control, enforce mode |
| Cockpit | Optional — browser-based server management (SSH tunnel access) |
| Netdata | Optional — real-time CPU, RAM, disk, network monitoring (SSH tunnel access) |
| rkhunter | Rootkit detection, baseline saved |
| auditd | Kernel-level audit logging with a baseline ruleset (identity, SSH, time, module loading) |
| AIDE | File integrity monitoring — database initialized on first run |
| Legal banners | `/etc/issue` + `/etc/issue.net` warning text |
| Password policy | Aging, umask 027, SHA512 hash rounds via `/etc/login.defs` |
| Debian goodies | `libpam-tmpdir`, `libpam-passwdqc`, `apt-listbugs/changes`, `needrestart`, `debsums`, `apt-show-versions` |
| Kernel modules | Blacklists rare protocols (dccp/sctp/rds/tipc) and USB/Firewire storage |
| Compiler restriction | `gcc`, `g++`, `cc`, `as` (and versioned variants) set to mode 750 — root-only, defeats local-privesc exploit building |
| Process accounting | `acct` + `sysstat` for command and resource history |
| Lynis | Security audit — scores your server, flags what to fix next |
| Operator tooling | Installs `git`, `tmux`, `jq`, `htop` — not present on Debian minimal, needed to operate the box |
| Remote syslog | Optional — forwards auth, auditd, fail2ban, kernel, daemon logs to a remote syslog server via TCP |

## Requirements

- Debian 13 (Trixie)
- Run as root (or via `sudo` on re-runs)
- SSH public key already added to `/root/.ssh/authorized_keys`

## Role scripts

The base hardens any server type. Role scripts layer the tooling each kind of server actually needs. Run them **after** `base-server.sh`.

### prod-server.sh — container-only prod hosts

```bash
bash prod-server.sh
```

Installs rootless Docker + Compose v2, plus the Bitwarden Secrets Manager CLI (`bws`) for pulling deploy secrets without storing them in a plaintext `.env` on disk. Disables the system-mode Docker daemon (rootless replaces it), allocates `subuid`/`subgid`, enables linger so the user daemon survives logout, exports `DOCKER_HOST` in `~/.bashrc`. No Node, no language toolchains — apps deploy as container images pulled from a registry. After install: `docker login ghcr.io` (or your registry of choice), then inject secrets at deploy time instead of committing them to disk:

```bash
export BWS_ACCESS_TOKEN=<machine-account-token>   # from your shell profile or a secret store, never checked in
bws run --project-id <project-id> -- docker compose up -d
```

### dev-server.sh — developer workstation

```bash
bash dev-server.sh
```

Same Docker setup as `prod-server.sh`, plus:

- `nvm` + Node LTS (per-user in `~/.nvm`, `lts/*` aliased default)
- Corepack enabled — `pnpm`/`yarn` pulled on demand from `package.json#packageManager`
- Claude Code CLI (`claude`) — Anthropic's native installer drops a self-updating binary in `~/.local/bin/claude`, decoupled from nvm
- GitHub CLI (`gh`) from `cli.github.com` apt repo
- GNU `make` for project-level orchestration
- Bitwarden CLI (`bw`) — standalone binary from `bitwarden/clients` GitHub releases, installed to `~/.local/bin` (no `npm -g`)
- Bitwarden Secrets Manager CLI (`bws`) — standalone binary from `bitwarden/sdk-sm` GitHub releases, sha256-verified, installed to `~/.local/bin`
- Antigravity CLI (`agy`) — Google's native installer (`antigravity.google/cli/install.sh`) drops a SHA512-verified, Node-independent binary in `~/.local/bin/agy`. Replaces the Gemini CLI, which Google retired on 2026-06-18 (now paid-Enterprise-API-key only). Import old config with `agy plugin import gemini`

### syslog-baseline.sh — central log receiver

```bash
sudo bash syslog-baseline.sh
```

Turns this host into a central log receiver: enables rsyslog's `imtcp` listener on TCP 514, opens 514/tcp in UFW (optionally restricted to a sender CIDR), and writes each sender's messages to `/var/log/remote/<hostname>/<program>.log` with weekly logrotate (12-week retention, 500M maxsize, compressed). Uses a dedicated `remote-tcp` ruleset with `SecurePath="replace"` so hostile senders can't write outside the bucket. Point the section 20 prompt of `base-server.sh` on each sender at this server's IP (or WireGuard overlay IP) and the logs land here automatically.

Prompts for a CIDR to restrict 514/tcp (e.g. `10.20.0.0/24` for a WireGuard subnet). Leave blank to allow all sources. Can also be set via env var:

```bash
SYSLOG_ALLOW_FROM=10.20.0.0/24 sudo bash syslog-baseline.sh
```

### wireguard-baseline.sh — server-to-server tunnel

```bash
sudo bash wireguard-baseline.sh
```

Sets up this host as a WireGuard peer: generates a keypair, writes `/etc/wireguard/wg0.conf`, opens the listen port in UFW, and enables `wg-quick@wg0`. On first run prompts for the host's overlay IP (e.g. `10.20.0.1/24`), listen port (default 51820), IP forwarding opt-in, and the first peer's details. Re-run anytime to add more peers or retrieve the public key — the script always prints the public key in the summary so you never have to dig through config files.

```
First run:   overlay IP, listen port, IP forwarding opt-in, first peer details
Re-run:      shows public key, existing peer count, prompts to add another peer
```

Run it on both sides of a tunnel, then exchange public keys and peer endpoints between the two. For the Singapore → Helsinki syslog pattern: run on Helsinki first, note the public key, then run on Singapore with Helsinki's public key and public IP as the endpoint.

## What happens

`base-server.sh` asks for your sudo username on first run (pre-filled on re-runs) and a sudo password for that user. Everything else is automatic.

One pause on first run: before locking down SSH, it asks you to verify your new account works in a second terminal. This prevents lockouts. Re-runs skip this pause automatically.

`dev-server.sh` and `prod-server.sh` prompt only for the sudo password (when sudo's cached credential has timed out).

`syslog-baseline.sh` prompts for a sender CIDR to restrict port 514 (leave blank to allow all). Can be passed via `SYSLOG_ALLOW_FROM=<cidr>` env var for unattended runs.

`wireguard-baseline.sh` prompts for overlay IP, listen port, IP forwarding opt-in, and the first peer's details on first run. Re-runs prompt only to add a new peer (default: no) and always display the public key for sharing.

## Idempotent — safe to re-run

All scripts detect prior runs and adapt:

- Pre-fills sudo username from the existing sudo group
- Skips the SSH safety pause once root login is already disabled
- Preserves existing `authorized_keys`, UFW rules, rkhunter baseline, AIDE database, custom legal banners, `jail.local`, and Lynis baseline log
- Detects existing sudo password (`passwd -S`) and skips the prompt if one is already set
- Adds new UFW rules instead of resetting; merges `sshd_config` keys in place
- Re-runs Lynis to track hardening index improvement over time
- Role scripts skip Docker / Node / etc. setup steps when their state checks pass

Re-run any time you update a script or want to refresh policy.

## After it runs

Root SSH is disabled. Log in as your new user:

```bash
ssh youruser@your-server-ip
```

Access Cockpit and Netdata via SSH tunnel (ports are closed in UFW):

```bash
ssh -N -L 9090:localhost:9090 youruser@your-server-ip
# open https://localhost:9090

ssh -N -L 19999:localhost:19999 youruser@your-server-ip
# open http://localhost:19999
```

Lynis report: `/var/log/lynis.log`
