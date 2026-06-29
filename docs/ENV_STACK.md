# Environment Stack

## Overview

My personal default tech stack across all projects. Captures the host-level baseline (`base-server.sh` hardening + `prod-server.sh` / `dev-server.sh` role layers), the tooling I reach for first on top of that baseline (rootless Docker, corepack-managed pnpm, language-managed toolchains in `$HOME`), the network access pattern (SSH tunnels for everything beyond 22/80/443), the editor connection model (VSCode Remote-SSH-style multiplexing), the deployment target (my own prod server, never managed PaaS), and the git forge (GitHub via `gh`). Exists primarily as a checkpoint AI assistants can read so they don't suggest rootful Docker, `npm install -g`, or PaaS-flavored defaults that don't match this environment. Update when defaults change; keep terse.

---

## Table of Contents

- [Overview](#overview)
- [Defaults](#defaults)
- [Dev tooling (from dev-server.sh)](#dev-tooling-from-dev-serversh)
- [Hardening (from base-server.sh)](#hardening-from-base-serversh)

## Defaults

- **Docker: rootless only.** Installed by `prod-server.sh` (prod boxes) or `dev-server.sh` (dev boxes) — same install logic in both (duplicated by design; see install model). The system-mode `docker.service`/`docker.socket` are **disabled** — only the user daemon runs (`systemctl --user`). Socket is `$XDG_RUNTIME_DIR/docker.sock` (= `/run/user/<uid>/docker.sock`). `docker compose` (v2 plugin) — never `docker-compose`. Never `sudo apt install docker.io`, never `sudo systemctl start docker`.
- **Node: nvm + corepack.** Node comes from `nvm` (per-user, `~/.nvm`), LTS by default. Project package managers come from `corepack` via `package.json#packageManager` — `pnpm` is the default. Never `npm install -g <anything>` — use `pnpm`, or for standalone tools install via the vendor's native installer into `~/.local/bin`. nvm bumps the LTS over time, so `npm -g` globals get orphaned under the old Node version and silently disappear from PATH.
- **No sudo for language toolchains.** Node via corepack, Python via `uv` or `pipx` (never `sudo pip install`), Go/Rust via their own installers (`rustup`, official Go tarball) into `$HOME`. System package manager is for system packages only.
- **Ports: SSH tunnel by default.** Servers expose 22/80/443 on UFW. Anything else (dev servers like Vite/Next, Cockpit, Netdata, container ports, DB ports) reaches me via `ssh -L`, not by opening firewall ports.
- **Editor: VSCode Remote-SSH or similar tunnel workflow.** SSH config tolerates this (MaxSessions 10, keepalives) — don't suggest tmux-as-editor or local-only flows as a workaround for connection issues.
- **Deployment target: my own prod server.** Don't default to Vercel / Fly / Cloudflare / Render / etc. Deploy artifacts are containers (rootless Docker) or systemd user units on a server I own; web traffic is fronted by a reverse proxy on that server.
- **Git forge: GitHub only.** Use `gh` for PR/issue/release/CI work — don't suggest `glab` or other forges. `gh` is preinstalled from `cli.github.com`'s apt repo.

---

## Dev tooling (from dev-server.sh)

`dev-server.sh` (8 sections, run as the sudo user after `base-server.sh`) installs the per-user dev stack. Inventory and the things that surprise:

- **Docker rootless + Compose v2.** Packages: `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`, `docker-ce-rootless-extras`, `uidmap`. System-mode daemon disabled. Setup via `dockerd-rootless-setuptool.sh install`, then `systemctl --user enable --now docker` + `loginctl enable-linger $USER` so the daemon survives logout. `subuid`/`subgid` allocated `100000-165535`. `DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock` is exported in `~/.bashrc`. **Gotcha:** the daemon needs a live user dbus at `/run/user/<uid>/bus` — log in via SSH (real PAM session). `sudo -s` / `su <user>` does not give you one, and the role scripts (`prod-server.sh`, `dev-server.sh`) refuse to run without it. The install logic is identical to `prod-server.sh`; only `dev-server.sh` then layers the rest below.
- **Node via nvm.** `nvm` installed to `~/.nvm`; Node LTS installed and `lts/*` is the default alias. `nvm` init lines are appended to `~/.bashrc` by its installer. After install, `exec $SHELL -l` to pick up `nvm` and `DOCKER_HOST` in the current shell.
- **Corepack** is enabled system-wide. `pnpm`/`yarn` are downloaded on demand per project from `package.json#packageManager`. Don't `npm i -g pnpm` — corepack handles it.
- **Claude Code CLI** (`claude`) — installed via Anthropic's native installer (`curl -fsSL https://claude.ai/install.sh | bash`), which drops a self-updating binary in `~/.local/bin/claude`. Not `npm -g` — that path orphaned the binary every time nvm bumped the LTS.
- **`gh`** — GitHub CLI from `cli.github.com` apt repo (keyring at `/etc/apt/keyrings/github-cli.gpg`). Not snap, not a release-tarball download.
- **`make`** — plain GNU make from apt for project-level orchestration (Makefiles are fine; the host has `make`, just not `gcc`).
- **Bitwarden CLI (`bw`)** and **Secrets Manager CLI (`bws`)** — standalone binaries from `bitwarden/clients` / `bitwarden/sdk-sm` GitHub releases, dropped into `~/.local/bin` (`bws` is sha256-verified). Not `npm -g` (banned) and not `cargo install` (host compilers are root-only per the baseline).
- **Gemini CLI (`gemini`)** — unlike `claude`, Google ships **no** native binary; `@google/gemini-cli` is npm-only. We install the `gemini-cli-bundle.zip` from `google-gemini/gemini-cli` GitHub releases — a multi-file, code-split ESM bundle (no shebang) — into `~/.local/lib/gemini-cli`, with a thin launcher in `~/.local/bin` that runs `node bundle/gemini.js`. **Node-dependent** (needs the nvm Node ≥ 20), not standalone — the one tool here that isn't decoupled from the toolchain.

Re-runnable: `dev-server.sh` is idempotent. Preflight refuses to run as root, refuses if `base-server.sh` hasn't run (checks `PermitRootLogin no` + UFW active), and refuses without a live user session.

---

## Hardening (from base-server.sh)

Every host has run `base-server.sh` (Debian 13 + 20 hardening sections). The defaults above already capture the network surface (UFW 22/80/443 only). The rest of what bites if assumed away:

- **`/tmp` is tmpfs, mounted `noexec,nosuid,nodev`.** Installers/builders that download-and-exec from `/tmp` fail with `Permission denied`. Set `TMPDIR=$HOME/tmp` or work under `$HOME`.
- **Compilers are root-only (mode 750).** `gcc`, `g++`, `cc`, `c++`, `cpp`, `as`, plus versioned variants. Non-root cannot compile — native node modules (`better-sqlite3`, `node-gyp` builds), `CGO_ENABLED=1` Go builds, and Python wheels with C extensions all break on the host. Build in a container or CI.
- **`UMASK 027` system-wide.** Files default to 640, dirs 750. Docker bind mounts especially: the container's user typically can't read host-written files without explicit `chmod` or `--user` matching.
- **SSH is locked down.** Key-only, no root login, `AllowUsers` = explicit allowlist of sudo-group members (new non-sudo accounts cannot SSH until added), `AllowTcpForwarding local` (only `-L` works — no `-R` remote forwards, no `-D` dynamic/SOCKS), `AllowAgentForwarding no` (no `ssh -A` — for git-over-SSH from the server use a deploy key or HTTPS+token, not a forwarded agent), `X11Forwarding no`, `MaxSessions 10` (for IDE multiplexing), 60s keepalive × 3. fail2ban: 5 failed attempts → 1h ban — don't iterate on wrong keys.
- **Sudo always needs a password.** No `NOPASSWD` anywhere — don't suggest CI/automation patterns that assume passwordless sudo (use systemd units or scoped capabilities instead). Existing sudo users have 90-day password aging (1-day min, 7-day warn) applied via `chage`.
- **`auditd` is watching:** `/etc/{passwd,shadow,group,gshadow,sudoers,sudoers.d/}`, `/etc/ssh/sshd_config{,.d/}`, `/etc/audit/`, login records (`wtmp`/`btmp`/`lastlog`/`faillock`), `adjtimex`/`settimeofday`/`clock_settime`, and kernel module load/unload. Anything touching those leaves an audit trail.
- **Other passive watchers.** AIDE has a filesystem baseline at `/var/lib/aide/aide.db`. rkhunter baseline at `/var/lib/rkhunter/db/rkhunter.dat`. debsums runs daily. sysstat + acct log process/resource activity. AppArmor is enforcing — most apps fine; niche custom binaries may need a profile or `aa-complain`.
- **`unattended-upgrades` is active.** Security patches apply automatically and may restart services via `needrestart` (preconfigured to auto-restart, no prompts). Don't be surprised by overnight package version changes.
- **Kernel modules blacklisted:** `usb-storage`, `firewire-core`/`-ohci`/`-sbp2` (no USB-drive mounting on servers), and rare network protocols `dccp`, `sctp`, `rds`, `tipc`.
- **Re-runnable.** `base-server.sh` is idempotent — re-run anytime to refresh. State that is preserved on re-run: authorized_keys, sudo password, UFW rules (additive), AIDE/rkhunter baselines, Netdata install, Lynis baseline log, `/etc/issue{,.net}` if customized, `/etc/fail2ban/jail.local` (user override slot — script writes to `jail.d/00-baseline.conf` instead).
