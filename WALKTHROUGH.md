# debian-baseline — walkthrough

## Overview

This is the section-by-section explainer for `baseline.sh` — what each of the 18 numbered sections actually does to a Debian 13 box, which files it writes, which services it starts, the attack it's defending against, and the command you can run afterward to verify it took effect. It complements `README.md` (the one-glance feature table) and is the right place to look when something on your hardened server surprises you or when you want to understand a step before re-running. Sections are linear (1 → 18), preceded by a pre-flight check description, and followed by reference material: a paths cheatsheet, day-to-day usage commands, the re-run preservation contract, deliberate gaps the script does not try to close, troubleshooting, and a note on why this script is server-flavored and would hurt a desktop. Skim the "At a glance" block below if 60 seconds is all you have.

## Table of Contents

- [Overview](#overview)
- [At a glance](#at-a-glance)
- [Pre-flight (before any section runs)](#pre-flight-before-any-section-runs)
- [1/18 — System updates](#118-system-updates)
- [2/18 — Automatic security updates](#218-automatic-security-updates)
- [3/18 — Sudo user](#318-sudo-user)
- [4/18 — SSH key copy](#418-ssh-key-copy)
- [5/18 — SSH safety check (first run only)](#518-ssh-safety-check-first-run-only)
- [6/18 — SSH hardening](#618-ssh-hardening)
- [7/18 — Firewall (UFW)](#718-firewall-ufw)
- [8/18 — fail2ban (brute-force protection)](#818-fail2ban-brute-force-protection)
- [9/18 — Kernel hardening (sysctl)](#918-kernel-hardening-sysctl)
- [10/18 — AppArmor](#1018-apparmor)
- [11/18 — Monitoring (Cockpit + Netdata)](#1118-monitoring-cockpit-netdata)
- [12/18 — Intrusion detection (rkhunter + auditd + AIDE)](#1218-intrusion-detection-rkhunter-auditd-aide)
  - [rkhunter](#rkhunter)
  - [AIDE (Advanced Intrusion Detection Environment)](#aide-advanced-intrusion-detection-environment)
  - [auditd](#auditd)
- [13/18 — Legal banners](#1318-legal-banners)
- [14/18 — Password policy (login.defs)](#1418-password-policy-logindefs)
- [15/18 — Debian goodies + PAM strength](#1518-debian-goodies-pam-strength)
- [16/18 — Disable unused kernel modules + restrict compilers](#1618-disable-unused-kernel-modules-restrict-compilers)
  - [Kernel module blacklist](#kernel-module-blacklist)
  - [Compiler restriction](#compiler-restriction)
- [17/18 — Process accounting (acct + sysstat)](#1718-process-accounting-acct-sysstat)
- [18/18 — Security audit (Lynis)](#1818-security-audit-lynis)
- [Where things live (paths cheatsheet)](#where-things-live-paths-cheatsheet)
- [How to use the box after the script runs](#how-to-use-the-box-after-the-script-runs)
- [What re-running the script does (and doesn't)](#what-re-running-the-script-does-and-doesnt)
- [Deliberate gaps (what this script does NOT do)](#deliberate-gaps-what-this-script-does-not-do)
- [Troubleshooting](#troubleshooting)
- [A note on running this on a desktop (not a server)](#a-note-on-running-this-on-a-desktop-not-a-server)

## At a glance

If you only have 60 seconds, here's what changes about your box after `baseline.sh` finishes.

**Login surface**

- SSH: root login off, passwords off, key-only auth, brute-force protection via [fail2ban](#818--fail2ban-brute-force-protection)
- New non-root user with sudo, [requires a password you set during the run](#318--sudo-user) — so a leaked SSH key alone can't escalate
- [Password aging](#1418--password-policy-logindefs) (90-day expiry) and complexity rules via PAM

**Network**

- [UFW firewall](#718--firewall-ufw): only TCP 22 / 80 / 443 reachable; everything else dropped
- [Kernel network stack](#918--kernel-hardening-sysctl) hardened against SYN floods, source spoofing, ICMP redirects
- [Rare protocols (DCCP/SCTP/RDS/TIPC) and USB/firewire storage drivers blacklisted](#1618--disable-unused-kernel-modules--restrict-compilers)

**Monitoring & forensics**

- [Cockpit + Netdata](#1118--monitoring-cockpit--netdata) installed, reachable only via SSH tunnel — never exposed publicly
- [auditd](#1218--intrusion-detection-rkhunter--auditd--aide) logs identity changes, SSH config edits, audit tampering, login records, time changes, module loads
- [AIDE](#1218--intrusion-detection-rkhunter--auditd--aide) maintains a filesystem-integrity baseline so you can detect drift
- [rkhunter](#1218--intrusion-detection-rkhunter--auditd--aide) scans for known rootkit signatures
- [debsums](#1518--debian-goodies--pam-strength) daily-cron verifies package files match their manifests
- [Lynis](#1818--security-audit-lynis) audits the whole box and gives you a 0–100 score

**Defense in depth**

- [AppArmor](#1018--apparmor) profiles in enforce mode (mandatory access control)
- [Compilers (gcc/g++/cc/as) locked to root](#1618--disable-unused-kernel-modules--restrict-compilers) — blocks the build-local-exploit step of most privesc chains
- [Automatic security updates](#218--automatic-security-updates) via `unattended-upgrades`

**Day-to-day usage**

- Log in: `ssh <user>@<server-ip>` with your key, then `sudo` with the password you set
- Read logs: `journalctl -f`, `sudo ausearch -k identity`, `sudo fail2ban-client status sshd`
- Web UIs (Cockpit, Netdata): via SSH tunnel (commands in [section 11](#1118--monitoring-cockpit--netdata))
- Re-run anytime — the script is idempotent and preserves your customizations

**Not appropriate for**

- Desktops or laptops — [see why](#a-note-on-running-this-on-a-desktop-not-a-server)
- Anything pre-Debian 13
- A box without an SSH public key in `/root/.ssh/authorized_keys` before you start (the script refuses to run)

---

## Pre-flight (before any section runs)

The script first checks it's safe to start:

| Check | Why |
|---|---|
| Running as root (UID 0) | Almost every action below requires root. |
| `/etc/os-release` exists and says Debian 13+ | The package names, paths, and systemd unit names assume Debian 13 (trixie). On Ubuntu or other distros, things would silently misbehave. |
| `/root/.ssh/authorized_keys` exists and is non-empty | Section 6 is about to disable root login and password auth. If there's no SSH key for the new user to inherit, you'd lock yourself out the moment the script finishes. |
| A controlling terminal exists | The script needs to prompt for a username (and sometimes a password). It reads from `/dev/tty` directly so it works under `curl | sudo bash`, but it still needs a terminal to read from. |
| Re-run detection | If `/etc/ssh/sshd_config` already has `PermitRootLogin no`, the script knows it's been run before and skips interactive confirmations where safe. |

Then it asks for the sudo username — pre-filled from the existing sudo group on re-runs, prompted fresh on first run.

---

## 1/18 — System updates

**What it does:** Runs `apt-get update` then `apt-get upgrade -y` to bring every installed package to its current version.

**Files/state changed:** Package cache at `/var/lib/apt/lists/`, all installed packages.

**Threat model:** Unpatched packages are the #1 vector for opportunistic attackers. A Debian 13 image cut three months ago has known CVEs by the time you boot it. This closes them.

**Verify after:** `apt list --upgradable` should print nothing.

---

## 2/18 — Automatic security updates

**What it does:** Installs `unattended-upgrades` and enables its systemd timer. From now on, security patches install themselves automatically.

**Files/state changed:**
- Package: `unattended-upgrades`
- Service: `unattended-upgrades.service` (enabled + started)
- Config: ships defaults at `/etc/apt/apt.conf.d/50unattended-upgrades` — only `security` updates are auto-applied by default.

**Threat model:** Without this, you'd need to remember to log in and run `apt upgrade` every week. With it, security fixes land within hours of release.

**Verify after:** `systemctl status unattended-upgrades` shows `active`. `cat /var/log/unattended-upgrades/unattended-upgrades.log` shows recent activity (will be empty for the first few days).

---

## 3/18 — Sudo user

**What it does:** Creates a non-root user (or finds the existing one), adds them to the `sudo` group, prompts for a sudo password if they don't have one, and writes a sudoers drop-in.

**Files/state changed:**
- New user account in `/etc/passwd`, `/etc/shadow`
- Membership in the `sudo` group (`/etc/group`)
- `/etc/sudoers.d/<username>` containing `<user> ALL=(ALL) ALL`
- User's password (set interactively if not already set)

**Threat model:** Root SSH (next sections) is going away. You need *some* non-root account to log in as. That account needs sudo for admin work. Requiring a password for sudo means a leaked SSH key alone can't escalate to root — the attacker would also need your password.

**Verify after:**
- `id <username>` shows `sudo` in the group list
- `cat /etc/sudoers.d/<username>` shows `ALL=(ALL) ALL` (no `NOPASSWD`)
- `passwd -S <username>` should print `<user> P …` (P = password set)

---

## 4/18 — SSH key copy

**What it does:** Copies `/root/.ssh/authorized_keys` to `/home/<user>/.ssh/authorized_keys` so the new user can SSH in with the same key root has been using.

**Files/state changed:**
- `/home/<user>/.ssh/` (mode 700)
- `/home/<user>/.ssh/authorized_keys` (mode 600, owned by the new user)

**Re-run behavior:** If the user already has a non-empty `authorized_keys`, the existing file is preserved — re-running won't clobber keys you added later.

**Verify after:**
```bash
ls -la /home/<user>/.ssh/
ssh-keygen -l -f /home/<user>/.ssh/authorized_keys   # show key fingerprint
```

---

## 5/18 — SSH safety check (first run only)

**What it does:** Pauses and tells you to open a *second terminal* and SSH in as the new user before letting the script disable root SSH. You type `yes` to confirm.

**Why this gate exists:** If your SSH key got copied wrong, or the user has a permissions problem, or your firewall is misbehaving, you'll find out *now* — while you still have root SSH access to fix it. Without this pause, a broken setup would only reveal itself after section 6 locked the door.

**Re-run behavior:** Skipped automatically. The script knows it's already locked SSH (re-run detection) and trusts you've been logging in successfully since.

---

## 6/18 — SSH hardening

**What it does:** Edits `/etc/ssh/sshd_config` to disable root login, password auth, and a bunch of forwarding features. Backs up the original first, validates the new config with `sshd -t`, then reloads `sshd`.

**Files/state changed:**
- Backup: `/etc/ssh/sshd_config.bak.<timestamp>`
- `/etc/ssh/sshd_config` modified

**Specific changes:**

| Directive | Value | Why |
|---|---|---|
| `PermitRootLogin` | `no` | Forces attackers to also guess your username, not just `root`. |
| `PasswordAuthentication` | `no` | Brute-force password attacks against SSH stop working entirely. |
| `PubkeyAuthentication` | `yes` | Only way in now: cryptographic key. |
| `MaxAuthTries` | `3` | Connection drops after 3 wrong attempts — fail2ban (section 8) bans you for 1h after 5 such drops. |
| `LoginGraceTime` | `30` | If you don't complete login in 30s, you're disconnected. Limits slow scanning. |
| `X11Forwarding` | `no` | Server isn't running X — no reason to expose the protocol. |
| `AllowTcpForwarding` | `no` | Prevents an attacker who has SSH from using your box as a TCP proxy. |
| `AllowAgentForwarding` | `no` | Prevents accidentally forwarding your local SSH agent to a compromised server. |
| `MaxSessions` | `2` | Caps how many concurrent SSH channels one connection can open. |
| `ClientAliveCountMax` | `2` | Idle connections get pruned. |
| `LogLevel` | `VERBOSE` | More detail in `/var/log/auth.log` for forensics. |
| `TCPKeepAlive` | `no` | Use SSH's own keepalive (more honest about idle state). |

**Verify after:**
```bash
sudo sshd -T | grep -iE 'permitroot|passwordauth|pubkeyauth|maxauthtries'
```

---

## 7/18 — Firewall (UFW)

**What it does:** Installs and enables UFW (Uncomplicated Firewall — a friendly wrapper over iptables/nftables). Default: deny all incoming. Allow only TCP 22 (SSH), 80 (HTTP), 443 (HTTPS).

**Files/state changed:**
- Package: `ufw`
- Service: `ufw` enabled
- Rules stored in `/etc/ufw/*.rules`

**Threat model:** Without a firewall, every service that binds to `0.0.0.0` is exposed to the entire internet. With UFW, only the three ports you explicitly allow accept connections. Everything else (databases listening on default ports, dev servers, monitoring daemons) is dropped at the kernel level.

**Note on Cockpit (9090) and Netdata (19999):** These ports are *deliberately not opened* in UFW. You reach them via SSH tunnel only (see sections 11 below).

**Verify after:**
```bash
sudo ufw status verbose
sudo iptables -L INPUT -n -v   # raw rules
```

---

## 8/18 — fail2ban (brute-force protection)

**What it does:** Installs fail2ban, writes a baseline jail config, and starts it. fail2ban watches `auth.log`; if an IP fails SSH 5 times in 10 minutes, it gets banned for 1 hour via the firewall.

**Files/state changed:**
- Package: `fail2ban`
- Service: `fail2ban` enabled + started
- `/etc/fail2ban/jail.d/00-baseline.conf` — our policy (read by fail2ban after `jail.conf`)
- `/etc/fail2ban/jail.local` — empty, reserved for *your* overrides (don't share with anyone, this is your space)

**Why `jail.d/` and not `jail.local`:** `jail.local` is fail2ban's documented operator-override slot. Earlier versions of this script wrote to it, which collided with anyone wanting to add their own rules. We moved to a namespaced drop-in (`jail.d/00-baseline.conf`) so operator overrides have a clean place to live.

**Verify after:**
```bash
sudo fail2ban-client status sshd     # shows currently banned IPs
sudo journalctl -u fail2ban -f       # live log of bans
```

---

## 9/18 — Kernel hardening (sysctl)

**What it does:** Writes a kernel-parameters file to `/etc/sysctl.d/99-hardening.conf` and applies it. These are runtime kernel switches that change how the network stack and process memory behave.

**Files/state changed:**
- `/etc/sysctl.d/99-hardening.conf` (new file)
- Kernel runtime state via `sysctl --system`

**Specific changes:**

| Parameter | Value | Effect |
|---|---|---|
| `net.ipv4.tcp_syncookies` | `1` | Defeats SYN flood DoS attacks against the listen queue. |
| `net.ipv4.conf.{all,default}.rp_filter` | `1` | Drops packets whose source IP can't be reached via the same interface (anti-spoofing). |
| `net.ipv4.conf.{all,default}.accept_redirects` | `0` | Ignores ICMP redirects — an attacker on the local network can't trick your box into routing through them. |
| `net.ipv6.conf.{all,default}.accept_redirects` | `0` | Same as above, IPv6. |
| `net.ipv4.conf.all.send_redirects` | `0` | Stops your box from emitting redirects (you're not a router). |
| `net.ipv4.icmp_echo_ignore_broadcasts` | `1` | Don't reply to broadcast pings — defeats Smurf-style amplification attacks. |
| `kernel.randomize_va_space` | `2` | Full ASLR — process memory layout randomized on every exec, making memory-corruption exploits much harder. |
| `kernel.dmesg_restrict` | `1` | Non-root can't read kernel ring buffer (`dmesg`) — hides driver/init details from attackers. |
| `kernel.kptr_restrict` | `2` | Kernel pointers in `/proc` show as `0x000…` to non-root — defeats one of the easier kernel exploit primitives. |

**Verify after:**
```bash
sysctl net.ipv4.tcp_syncookies kernel.kptr_restrict kernel.dmesg_restrict
```

---

## 10/18 — AppArmor

**What it does:** Installs AppArmor (Linux's mandatory access control system) and ensures profiles in `/etc/apparmor.d/` are loaded in *enforce* mode.

**Files/state changed:**
- Packages: `apparmor`, `apparmor-utils`
- Service: `apparmor` enabled

**Threat model:** Even if a program (say, your web server) is compromised via an RCE, AppArmor restricts what files it can read/write, what syscalls it can make, what network it can reach. Defense in depth: a hole in nginx doesn't become a hole in the whole box.

**Verify after:**
```bash
sudo aa-status
```

You should see profiles listed under "enforce mode." Six is typical on a fresh Debian 13.

---

## 11/18 — Monitoring (Cockpit + Netdata)

**What it does:** Installs two web-based monitoring tools, but doesn't open their ports in the firewall — you reach them over SSH tunnels only.

**Files/state changed:**
- Package: `cockpit`
- Service: `cockpit.socket` enabled (web on port 9090, localhost-bound)
- Netdata installed to `/opt/netdata/` via its kickstart script (web on port 19999, also bound)

**Cockpit (port 9090):** Web UI for server management — view services, logs, network interfaces, accounts, software updates, terminal access. Think "GUI for systemd."

**Netdata (port 19999):** Real-time metrics — CPU, RAM, disk I/O, network, processes, Docker containers. Refreshes every second. Good for "is this thing actually loaded?"

**Why tunnel-only:** Both expose powerful interfaces (Cockpit can install packages, restart services, etc.). Putting them on the public internet would be giving attackers a GUI for breaking in. Tunneling means: only someone with your SSH key can reach them.

**How to access from your laptop:**
```bash
# Cockpit
ssh -N -L 9090:localhost:9090 <user>@<server-ip>
# then open https://localhost:9090 (accept the self-signed cert warning)

# Netdata
ssh -N -L 19999:localhost:19999 <user>@<server-ip>
# then open http://localhost:19999
```

---

## 12/18 — Intrusion detection (rkhunter + auditd + AIDE)

Three different tools, three different jobs:

### rkhunter

**What it does:** Scans for known rootkits, suspicious binaries, hidden processes. Stores a baseline of your filesystem on first run; on subsequent scans, alerts if files have unexpectedly changed.

**Files/state changed:**
- Package: `rkhunter`
- Baseline DB: `/var/lib/rkhunter/db/rkhunter.dat`

**Run manually:** `sudo rkhunter --check`

### AIDE (Advanced Intrusion Detection Environment)

**What it does:** Builds a cryptographic-hash database of every important file on the system. Later, you run `aide --check` and it tells you exactly what changed since the baseline.

**Files/state changed:**
- Package: `aide`
- Database: `/var/lib/aide/aide.db` (or `aide.db.gz`)
- Config: `/etc/aide/aide.conf` and `/etc/aide/aide.conf.d/`

**Why both AIDE and rkhunter:** rkhunter is signature-based (looks for *known* bad things). AIDE is generic — it catches *any* unexpected change, even from rootkits rkhunter has never heard of.

**Run manually:** `sudo aide --check` (warning: large output the first time after Debian package updates)

### auditd

**What it does:** Kernel-level audit logging — every time someone touches a watched file or invokes a watched syscall, the event is written to `/var/log/audit/audit.log` with timestamp, UID, and command.

**Files/state changed:**
- Packages: `auditd`
- Service: `auditd` enabled
- Rules: `/etc/audit/rules.d/50-baseline.rules` (added by us)

**What we watch (the `-k <tag>` is the search key):**
- `identity` — `/etc/{passwd,shadow,group,gshadow,sudoers,sudoers.d/}` writes
- `sshd_config` — SSH config changes
- `audit_config` — changes to the audit subsystem itself
- `logins` — `wtmp`, `btmp`, `lastlog`, `faillock`
- `time-change` — calls to `adjtimex`, `settimeofday`, `clock_settime`
- `modules` — kernel module load/unload

**Query the audit log:**
```bash
sudo ausearch -k identity        # everyone who touched passwd/shadow/sudoers
sudo ausearch -k sshd_config     # everyone who edited sshd_config
sudo ausearch -k modules         # every kernel module load
sudo aureport --summary          # high-level overview
```

---

## 13/18 — Legal banners

**What it does:** Writes warning text to `/etc/issue` (shown at local console login) and `/etc/issue.net` (shown at SSH login, before auth).

**Files/state changed:** `/etc/issue`, `/etc/issue.net`

**Why it's not just decoration:** In some jurisdictions, prosecuting an unauthorized-access case is easier if the system clearly announced that access requires authorization. The banner also signals that activity is logged, which can deter casual probing.

**Re-run behavior:** If you've customized the banner (anything other than empty, Debian default, or our previous banner content), the script leaves it alone with a warning.

---

## 14/18 — Password policy (login.defs)

**What it does:** Sets password aging defaults in `/etc/login.defs` and applies them to existing sudo users via `chage`.

**Files/state changed:**
- `/etc/login.defs` — directive rewrites
- Each sudo user's password-aging metadata in `/etc/shadow` (via `chage`)

**Specific values:**

| Setting | Value | Effect |
|---|---|---|
| `PASS_MAX_DAYS` | 90 | Password expires every 90 days. |
| `PASS_MIN_DAYS` | 1 | Can't change password more than once per day (prevents cycling back to a known one). |
| `PASS_WARN_AGE` | 7 | 7-day warning at login before expiry. |
| `UMASK` | 027 | New files default to mode 640 (owner rw, group r, other none). |
| `ENCRYPT_METHOD` | SHA512 | Password hashes use SHA-512 instead of older/weaker algorithms. |
| `SHA_CRYPT_MIN_ROUNDS` | 5000 | Minimum hash iterations — slows offline cracking. |
| `SHA_CRYPT_MAX_ROUNDS` | 100000 | Upper bound. |

**Note:** `login.defs` only binds at user *creation* time. We loop over existing sudo group members and run `chage -M 90 -m 1 -W 7` so the policy actually applies to them, not just future users.

**Verify after:**
```bash
sudo chage -l <username>     # shows aging info per user
```

---

## 15/18 — Debian goodies + PAM strength

**What it does:** Installs a bundle of small Debian-native packages that improve security or visibility:

| Package | What it does |
|---|---|
| `libpam-tmpdir` | Each user gets their own private `/tmp` — no more shared `/tmp` symlink attacks. |
| `libpam-passwdqc` | Enforces password strength (mixed case, length, dictionary checks). This is what shows the "passphrase or password" prompt when you run `passwd`. |
| `apt-listbugs` | Before installing a package, shows you any release-critical bugs filed against it. |
| `apt-listchanges` | Shows you the package changelog *before* you confirm the install. |
| `needrestart` | After every apt run, detects which services need restarting because their libraries changed. Auto-restarts them (pre-configured by us to be non-interactive). |
| `debsums` | Verifies installed package files against the manifest checksums. Runs daily via cron (we set `CRON_CHECK=daily` in `/etc/default/debsums`). |
| `apt-show-versions` | `apt-show-versions -u` lists upgradable packages with version diffs. |

**Threat model:** None of these individually move the needle dramatically, but together they give you *visibility* — what changed, when, whether it matches what the maintainer shipped.

**Verify after:**
```bash
grep ^CRON_CHECK /etc/default/debsums      # should say "CRON_CHECK=daily"
cat /etc/needrestart/conf.d/50-autorestart.conf
```

---

## 16/18 — Disable unused kernel modules + restrict compilers

**What it does:** Two unrelated hardening steps:

### Kernel module blacklist

Writes to `/etc/modprobe.d/`:
- `blacklist-rare-network.conf` — disables `dccp`, `sctp`, `rds`, `tipc` (network protocols you almost certainly don't use; each is a kernel attack surface)
- `blacklist-storage.conf` — disables `usb-storage`, `firewire-core`, `firewire-ohci`, `firewire-sbp2`

**Why blacklist USB storage on a server:** Someone with physical access plugging in a USB drive can sometimes auto-trigger driver bugs or exfiltrate data. On a remote VPS this is moot, but it's a CIS benchmark item.

### Compiler restriction

Sets `gcc`, `g++`, `cc`, `c++`, `cpp`, `as` and their versioned variants to mode 750 (root and root-group only). Non-root users can no longer compile code.

**Threat model:** If an attacker gets a non-root shell (e.g., via web app RCE), they often want to compile a local-privilege-escalation exploit. Stripping compiler access stops that path. They'd have to bring a pre-compiled binary — possible, but one more hurdle.

**Verify after:**
```bash
ls -l /usr/bin/gcc /usr/bin/cc /usr/bin/as
lsmod | grep -E 'usb_storage|firewire'   # should be empty after reboot
```

---

## 17/18 — Process accounting (acct + sysstat)

**What it does:**
- **acct**: logs every process that ran, with user, command, runtime, and exit status. Queryable later with `lastcomm` and `sa`.
- **sysstat**: collects CPU/memory/disk/network metrics every 10 minutes (via cron timer), keeps them in `/var/log/sysstat/`. Query with `sar`.

**Files/state changed:**
- Packages: `acct`, `sysstat`
- Services: `acct.service` (or `psacct.service`) + `sysstat.service` enabled
- `/etc/default/sysstat` — set `ENABLED="true"`

**Use cases:**
- "Who ran what at 3am yesterday?" → `lastcomm`
- "Was the box swapping at 11pm?" → `sar -r -s 23:00:00`
- "What was the disk throughput last Tuesday?" → `sar -d -f /var/log/sysstat/sa<day>`

**Verify after:**
```bash
sudo lastcomm | head -20
sar -u 1 5      # live CPU stats
```

---

## 18/18 — Security audit (Lynis)

**What it does:** Installs Lynis (from CISOfy's apt repo, not Debian's stale package), runs a full audit, saves the report.

**Files/state changed:**
- Packages: `lynis` (from `packages.cisofy.com`)
- GPG key: `/etc/apt/keyrings/cisofy.gpg`
- Apt source: `/etc/apt/sources.list.d/cisofy-lynis.list`
- Reports: `/var/log/lynis.log` (latest run), `/var/log/lynis-baseline.log` (first run, preserved as before/after reference), `/var/log/lynis-report.dat` (machine-readable)

**What the hardening index means:** Lynis scores from 0–100. Anything above 70 is decent. 80s is well-hardened. 90+ usually requires tradeoffs that hurt usability (separate partitions, GRUB password, SSH on a non-standard port). The number is a *proxy*, not the goal.

**Read suggestions:**
```bash
sudo grep '^suggestion' /var/log/lynis-report.dat
sudo lynis show details <TEST-ID>    # explain a specific finding
```

---

## Where things live (paths cheatsheet)

| What | Where |
|---|---|
| SSH config | `/etc/ssh/sshd_config` (backups: `*.bak.<timestamp>`) |
| Sudoers for the new user | `/etc/sudoers.d/<username>` |
| UFW rules | `/etc/ufw/*.rules`, status via `ufw status` |
| fail2ban baseline policy | `/etc/fail2ban/jail.d/00-baseline.conf` |
| fail2ban operator overrides | `/etc/fail2ban/jail.local` (empty, yours to edit) |
| Kernel hardening | `/etc/sysctl.d/99-hardening.conf` |
| Kernel module blacklists | `/etc/modprobe.d/blacklist-{rare-network,storage}.conf` |
| auditd rules | `/etc/audit/rules.d/50-baseline.rules` |
| auditd log | `/var/log/audit/audit.log` |
| Password policy | `/etc/login.defs`, per-user via `chage -l <user>` |
| needrestart auto-restart | `/etc/needrestart/conf.d/50-autorestart.conf` |
| AIDE database | `/var/lib/aide/aide.db(.gz)` |
| rkhunter database | `/var/lib/rkhunter/db/rkhunter.dat` |
| Lynis logs | `/var/log/lynis.log`, `/var/log/lynis-baseline.log`, `/var/log/lynis-report.dat` |

---

## How to use the box after the script runs

**Log in (root SSH is dead):**
```bash
ssh <user>@<server-ip>
```

**See what's been happening (no extra software needed):**
```bash
journalctl -f                       # live system log
journalctl -u ssh -n 50             # recent SSH events
journalctl -u fail2ban -f           # bans as they happen
sudo ausearch -k identity           # who touched user accounts
sudo fail2ban-client status sshd    # currently banned IPs
sudo ufw status                     # firewall rules + counters
```

**Use the web UIs (over SSH tunnel):**
```bash
ssh -N -L 9090:localhost:9090 <user>@<ip>    # then https://localhost:9090 (Cockpit)
ssh -N -L 19999:localhost:19999 <user>@<ip>  # then http://localhost:19999 (Netdata)
```

**Re-audit security:**
```bash
sudo lynis audit system
sudo aide --check                   # file integrity since baseline
sudo rkhunter --check
```

---

## What re-running the script does (and doesn't)

The script is idempotent — re-running produces the same end state without destroying operator changes:

| Preserved on re-run | Why |
|---|---|
| User's `~/.ssh/authorized_keys` | Only seeded from root's if empty/missing. |
| UFW rules | Additive — never `--force reset`. |
| AIDE database | Re-init would erase the integrity baseline. |
| rkhunter database | Same. |
| Lynis baseline log | Kept for before/after comparison. |
| Custom legal banner content | If `/etc/issue` doesn't match our or Debian's defaults, left alone. |
| `/etc/fail2ban/jail.local` | Reserved for your overrides. |

Re-run prompts that get skipped: username (pre-filled from existing sudo group), SSH safety check, sudo password (if already set).

---

## Deliberate gaps (what this script does NOT do)

These are conscious omissions, not oversights:

| Not done | Why |
|---|---|
| GRUB boot password | Risk of locking yourself out of recovery on a cloud VPS. |
| Separate `/home`, `/var`, `/tmp` partitions | Requires reinstall. Out of scope for a post-install hardening script. |
| SSH on non-standard port (e.g., 2222) | UFW complexity vs marginal benefit. fail2ban handles brute-force on 22. |
| Remote syslog | Useful for tamper-resistance, but pointless without a destination. Configure manually when you have one. |
| SELinux | AppArmor is the Debian-native MAC system. Mixing both is messy. |
| `iptables --policy DROP` directly | UFW provides equivalent functionality with a less foot-gun-prone interface. |

---

## Troubleshooting

**Locked out of SSH:** Use your VPS provider's web/serial console. Edit `/etc/ssh/sshd_config`, restore from a `.bak.*` backup if needed. fail2ban bans are in `iptables -L f2b-sshd` (unban with `fail2ban-client set sshd unbanip <IP>`).

**Sudo says "incorrect password":** That's expected now — you need to type your sudo password (set during section 3), not your SSH key passphrase.

**A service won't restart because of AppArmor:** `sudo journalctl -u apparmor` shows the denial. `sudo aa-complain <profile>` puts it in non-enforcing mode while you investigate.

**Netdata install failed:** The kickstart sometimes fails on first try (network, package conflicts). Re-run the script; it skips section 11's install if the binary is already there. If still failing, the script prints exactly what to run manually.

**AIDE complains about lots of changes:** Normal after an `apt upgrade` — package files moved or got new versions. After confirming the changes are legitimate, re-baseline with `sudo aide --init && sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db`.

---

## A note on running this on a desktop (not a server)

This script is written for *servers* — headless, single-purpose, network-exposed. Several sections actively hurt desktop use:

- **Section 16 blacklists `usb-storage`** — your USB drives, thumb drives, and external disks stop being recognized.
- **Section 16 restricts compilers to root** — if you do any development as your normal user (`make`, building from source, running language toolchains that invoke `gcc`), it breaks.
- **Section 7 firewall blocks inbound for everything except 22/80/443** — desktop services like CUPS printing, mDNS/Avahi for network discovery, game servers, local dev servers, file sharing, etc., all stop accepting connections.
- **Section 6 disables SSH password auth** — only matters if you SSH into your own desktop from elsewhere, but if you do, you'll need an SSH key.
- **Section 14 password aging** — your password expires every 90 days.

Running it unmodified on a desktop is a bad time. If you want a desktop-flavored hardening pass, you'd want to (at minimum) skip sections 7, 16's USB blacklist, 16's compiler restriction, and possibly relax section 14.
