# debian-baseline

```bash
curl -fsSL https://raw.githubusercontent.com/willardcsoriano/debian-baseline/main/baseline.sh | sudo bash
```

Run as root on a fresh Debian 13 server. Re-run anytime — the script is idempotent.

## Table of Contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [What happens](#what-happens)
- [Idempotent — safe to re-run](#idempotent-safe-to-re-run)
- [After it runs](#after-it-runs)

## What it does

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
| Cockpit | Browser-based server management (SSH tunnel access) |
| Netdata | Real-time CPU, RAM, disk, network, Docker monitoring |
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
| Operator tooling | Installs `git`, `tmux`, `jq` — not present on Debian minimal, needed to operate the box |
| Docker | Optional — prompted at start; installs rootless Docker CE (system daemon disabled, user daemon under the sudo account) |
| Remote syslog | Optional — forwards auth, auditd, fail2ban, kernel, daemon logs to a remote syslog server via TCP |

## Requirements

- Debian 13 (Trixie)
- Run as root (or via `sudo` on re-runs)
- SSH public key already added to `/root/.ssh/authorized_keys`

## What happens

The script asks for two things on first run: your sudo username (pre-filled on re-runs) and a sudo password for that user. Everything else is automatic.

One pause on first run: before locking down SSH, it asks you to verify your new account works in a second terminal. This prevents lockouts. Re-runs skip this pause automatically.

## Idempotent — safe to re-run

The script detects prior runs and adapts:

- Pre-fills sudo username from the existing sudo group
- Skips the SSH safety pause once root login is already disabled
- Preserves existing `authorized_keys`, UFW rules, rkhunter baseline, AIDE database, custom legal banners, `jail.local`, and Lynis baseline log
- Detects existing sudo password (`passwd -S`) and skips the prompt if one is already set
- Adds new UFW rules instead of resetting; merges `sshd_config` keys in place
- Re-runs Lynis to track hardening index improvement over time

Re-run any time you update the script or want to refresh policy.

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
