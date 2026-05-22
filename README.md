# debian-server-baseline

```bash
curl -fsSL https://raw.githubusercontent.com/willardcsoriano/debian-server-baseline/main/debian-server-baseline.sh | sudo bash
```

Run as root on a fresh Debian 13 server. Re-run anytime — the script is idempotent.

## Overview

Idempotent hardening and role-specific tooling for Debian 13 servers. Every server starts with the mandatory base (`debian-server-baseline.sh`, 20 sections — SSH lockdown, UFW, fail2ban, auditd, AIDE, AppArmor, Lynis, kernel hardening) which runs as root. Then layer one or more role scripts as the sudo user: `prod-server.sh` for container-only hosts (rootless Docker + Compose), `dev-server.sh` for dev boxes (adds Node/Corepack, Claude Code CLI, `gh`, `make`), `remote-syslog.sh` for security-log forwarding. Each script is a single `curl | bash` one-liner; pick what the server actually needs. All scripts are idempotent — re-run any time to refresh.

## Table of Contents

- [Overview](#overview)
- [What the base does](#what-the-base-does)
- [Requirements](#requirements)
- [Role scripts](#role-scripts)
  - [prod-server.sh — container-only prod hosts](#prod-serversh-container-only-prod-hosts)
  - [dev-server.sh — developer workstation](#dev-serversh-developer-workstation)
  - [remote-syslog.sh — log forwarding](#remote-syslogsh-log-forwarding)
- [What happens](#what-happens)
- [Idempotent — safe to re-run](#idempotent-safe-to-re-run)
- [After it runs](#after-it-runs)

## What the base does

Most hardening scripts lock your server and disappear. This one installs the tools to keep it hardened — so you have ongoing visibility, not just a one-time configuration.

> Want a section-by-section walkthrough with verification commands and threat-model notes? See [WALKTHROUGH.md](WALKTHROUGH.md).

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

The base hardens any server type. Role scripts layer the tooling each kind of server actually needs. Run them **after** `debian-server-baseline.sh`, as your sudo user (not root).

### prod-server.sh — container-only prod hosts

```bash
curl -fsSL https://raw.githubusercontent.com/willardcsoriano/debian-server-baseline/main/prod-server.sh | bash
```

Installs rootless Docker + Compose v2 and nothing else. Disables the system-mode Docker daemon (rootless replaces it), allocates `subuid`/`subgid`, enables linger so the user daemon survives logout, exports `DOCKER_HOST` in `~/.bashrc`. No Node, no language toolchains — apps deploy as container images pulled from a registry. After install: `docker login ghcr.io` (or your registry of choice) and you're ready to `docker compose pull && up -d`.

### dev-server.sh — developer workstation

```bash
curl -fsSL https://raw.githubusercontent.com/willardcsoriano/debian-server-baseline/main/dev-server.sh | bash
```

Same Docker setup as `prod-server.sh`, plus:

- `nvm` + Node LTS (per-user in `~/.nvm`, `lts/*` aliased default)
- Corepack enabled — `pnpm`/`yarn` pulled on demand from `package.json#packageManager`
- Claude Code CLI (`@anthropic-ai/claude-code`, installed via `npm -g` — the only npm-global package on the host)
- GitHub CLI (`gh`) from `cli.github.com` apt repo
- GNU `make` for project-level orchestration
- Bitwarden CLI (`bw`) — standalone binary from `bitwarden/clients` GitHub releases, installed to `~/.local/bin` (no `npm -g`)
- Bitwarden Secrets Manager CLI (`bws`) — standalone binary from `bitwarden/sdk-sm` GitHub releases, sha256-verified, installed to `~/.local/bin`

### remote-syslog.sh — log forwarding

```bash
curl -fsSL https://raw.githubusercontent.com/willardcsoriano/debian-server-baseline/main/remote-syslog.sh | sudo bash
```

Forwards security-relevant log facilities (auth, authpriv, kern.warning, daemon, syslog, local6 for auditd) to a remote syslog server on port 514 via TCP. Equivalent to the in-baseline section 20 prompt — useful when you want to enable/disable forwarding without re-running the full baseline, or to point an existing host at a new log receiver. Prompts for the receiver IP/hostname.

## What happens

`debian-server-baseline.sh` asks for your sudo username on first run (pre-filled on re-runs) and a sudo password for that user. Everything else is automatic.

One pause on first run: before locking down SSH, it asks you to verify your new account works in a second terminal. This prevents lockouts. Re-runs skip this pause automatically.

`dev-server.sh` and `prod-server.sh` prompt only for the sudo password (when sudo's cached credential has timed out).

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
