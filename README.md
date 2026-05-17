# debian-baseline

One command to harden a fresh Debian 13 server.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/willardcsoriano/debian-baseline/main/baseline.sh)
```

Run as root. Takes ~5 minutes.

---

## What it does

Most hardening scripts lock your server and disappear. This one installs the tools to keep it hardened — so you have ongoing visibility, not just a one-time configuration.

| Step | What |
|---|---|
| System updates | Upgrades all packages, enables automatic security patches |
| Sudo user | Creates a non-root account, copies your SSH key |
| SSH hardening | Disables root login and password auth, key-only |
| Firewall | UFW — ports 22, 80, 443 open; everything else denied |
| fail2ban | Bans IPs after 5 failed SSH attempts (1h ban) |
| Kernel hardening | sysctl — SYN flood, spoofing, redirect protection |
| AppArmor | Mandatory access control, enforce mode |
| Cockpit | Browser-based server management (SSH tunnel access) |
| Netdata | Real-time CPU, RAM, disk, network, Docker monitoring |
| rkhunter | Rootkit detection, baseline saved |
| auditd | Kernel-level audit logging |
| Lynis | Security audit — scores your server, flags what to fix next |

## Requirements

- Debian 13 (Trixie)
- Run as root
- SSH public key already added to `/root/.ssh/authorized_keys`

## What happens

The script asks for one thing: your sudo username. Everything else is automatic.

One pause: before locking down SSH, it asks you to verify your new account works in a second terminal. This prevents lockouts.

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
