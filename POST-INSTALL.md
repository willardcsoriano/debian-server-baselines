# POST-INSTALL.md

## Overview

This document covers what to do **after** `baseline.sh` finishes — things you'd typically install or configure to actually use the hardened server as a working environment. It does not modify or weaken the script's defaults; instead it documents the safe drop-ins (e.g., an `sshd_config` override for VS Code Remote-SSH) and the habits (e.g., loopback-binding container ports) needed to live with those defaults. Each section is self-contained: skip what you don't need. If you only run the script and SSH in occasionally to manage services, you can ignore this entirely — but if you plan to do development on the box itself, this is the practical companion to `README.md` and `WALKTHROUGH.md`.

## Table of Contents

- [Overview](#overview)
- [Compatibility](#compatibility)
  - [VS Code Remote-SSH (and other `-L` / `-D` tunneling tools)](#vs-code-remote-ssh-and-other--l--d-tunneling-tools)
- [Installing additional services](#installing-additional-services)
  - [Docker on a hardened host](#docker-on-a-hardened-host)
    - [Living with the script's hardening](#living-with-the-scripts-hardening)
- [Running and monitoring services](#running-and-monitoring-services)
  - [Keep things actually running](#keep-things-actually-running)
  - [Check status from the terminal](#check-status-from-the-terminal)
  - [Browser dashboards via SSH tunnel](#browser-dashboards-via-ssh-tunnel)
  - [VS Code Container Tools sidebar](#vs-code-container-tools-sidebar)
  - [A pragmatic combo](#a-pragmatic-combo)

## Compatibility

### VS Code Remote-SSH (and other `-L` / `-D` tunneling tools)

The script sets `AllowTcpForwarding no` so a leaked SSH key can't be used as a generic tunnel. That also blocks the dynamic SOCKS forward Remote-SSH opens to reach `vscode-server` on the remote loopback, so connections fail with:

```
channel N: open failed: administratively prohibited: open failed
ERROR: TCP port forwarding appears to be disabled on the remote host.
```

To re-enable the lower-risk directions (`-L` local, `-D` dynamic) while keeping reverse forwards (`-R`) blocked, drop in an override after running this script:

```bash
sudo tee /etc/ssh/sshd_config.d/10-remote-dev.conf > /dev/null <<EOF
AllowTcpForwarding local
EOF
sudo sshd -t && sudo systemctl reload ssh
```

The drop-in survives re-runs because the script edits `/etc/ssh/sshd_config` directly, not the `.d/` directory. OpenSSH evaluates the first matching directive, so `local` from the drop-in wins over `no` in the main file.

## Installing additional services

### Docker on a hardened host

Docker isn't auto-installed by anything (not even VS Code's Remote-SSH magic — that only installs `vscode-server`, not a container runtime). The daemon is a system service and has to live on whichever machine runs the containers. If your laptop is small and you want the VPS to be your dev environment, Docker has to go on the VPS.

The script doesn't touch Docker so the install is a clean addition. Use Docker's official apt repo, not Debian's `docker.io` package — the official repo tracks current releases; the distro package lags.

**1. Remove any distro-shipped Docker packages first** (no-op on a fresh install, but cheap to run):

```bash
sudo apt remove $(dpkg --get-selections docker.io docker-compose docker-doc podman-docker containerd runc | cut -f1)
```

**2. Add Docker's apt repo** (deb822 `.sources` format with an ASCII-armored key — this is the current Docker-recommended layout, not the older `.list` + binary `.gpg` style):

```bash
sudo apt update
sudo apt install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update
```

**3. Install Docker Engine, CLI, containerd, and the buildx/compose plugins:**

```bash
sudo apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

The Debian package enables and starts the `docker` service via its postinst hook, so no separate `systemctl enable --now docker` is needed. Verify with:

```bash
sudo docker run hello-world
```

**4. (Optional) Run Docker without `sudo`** — add your user to the `docker` group, then log out and back in:

```bash
sudo usermod -aG docker $USER
exit
# SSH back in, then:
docker run hello-world
```

Heads up: being in the `docker` group is **effectively root**, because a container with `-v /:/host` can read or modify anything on the host. For a solo dev on your own box this is the standard tradeoff; just know it weakens the "sudo requires a password" defense the script set up.

#### Living with the script's hardening

Three habits worth forming, all driven by what `baseline.sh` already configured:

- **Bind container ports to loopback.** Docker writes its own iptables rules below UFW, so `-p 8080:80` exposes a container to the public internet even though UFW only allows 22/80/443. Get in the habit of `-p 127.0.0.1:8080:80` and then tunnel from your laptop with `ssh -L 8080:localhost:8080 ...` (or VS Code's Forwarded Ports panel). Same pattern the script already uses for Cockpit and Netdata.
- **Build inside containers, not on the host shell.** Section 16 of the script sets `gcc`, `g++`, `cc`, and `as` to mode 750 — root-only — so a host-side `npm install` or `pip install` with native dependencies will fail for your sudo user. Inside a container the toolchain is unrestricted, so the rule of thumb "always build in a container" makes the restriction invisible.
- **Expect AIDE and rkhunter noise around `/var/lib/docker`.** Both scanners will report constant changes under Docker's data directory because images and containers churn there. Either tune those tools to ignore `/var/lib/docker` and `/var/lib/containerd`, or learn to skim past container-related diffs when reviewing reports.

That's the whole post-install for Docker: one apt sequence, one optional group add, three habits.

## Running and monitoring services

Once you've installed Docker and started building things, the next concern is keeping projects up and knowing what they're doing without sitting at the terminal. The box is headless, so visibility is the part that's easiest to neglect — these are the four layers to think about.

### Keep things actually running

Anything you start as a foreground process in an SSH session dies the moment you disconnect, the box reboots, or the process crashes. Three legitimate ways to keep something up:

- **Docker with `--restart unless-stopped`** (or `restart: unless-stopped` in a compose file). Docker auto-starts these containers on boot and restarts them if they crash. Natural default if Docker is already your workflow.
- **systemd units** for non-containerized services. Write a unit file at `/etc/systemd/system/myapp.service`, then `sudo systemctl enable --now myapp`. `Restart=on-failure` handles crashes; `enable` covers boot.
- **tmux / screen** are for *interactive* sessions you want to detach from and reattach later — long builds, REPLs, ad-hoc debugging. Not for production processes, and they don't survive reboots.

### Check status from the terminal

For Docker:

```bash
docker ps                # what's running
docker stats             # live CPU/memory per container
docker logs -f myapp     # tail logs (Ctrl-C to stop tailing)
docker compose ps        # status of a compose stack
```

For systemd services:

```bash
systemctl status myapp
journalctl -u myapp -f
```

For "is it actually listening on a port?":

```bash
ss -tlnp                 # all listening TCP ports and the owning process
```

`ss -tlnp` is the truth. If your container says it's running but `ss` doesn't show its port, the publish flag is wrong or the process bound to a different interface — start debugging there.

### Browser dashboards via SSH tunnel

The script already installed Cockpit and Netdata; you just haven't tunneled to them yet. Both are intentionally **not** exposed in UFW — access is local-only via SSH forwarding, so a leaked dashboard URL can't be reached from the internet.

**Cockpit** — service list, system resources, journal logs, an embedded terminal, package updates:

```bash
ssh -N -L 9090:localhost:9090 you@vps
# then open https://localhost:9090 in your browser
```

For Docker visibility inside Cockpit, install `cockpit-podman` (works with Docker too) or the community Docker plugin.

**Netdata** — real-time per-second metrics, with **Docker container CPU/memory/network out of the box**, no configuration:

```bash
ssh -N -L 19999:localhost:19999 you@vps
# then open http://localhost:19999 in your browser
```

For sustained use, VS Code's "Forwarded Ports" panel can hold both tunnels open in the background while you work — no need for separate `ssh -N` terminals.

### VS Code Container Tools sidebar

The Container Tools extension (auto-installs into `vscode-server` when you enable it remotely) adds a Docker icon to the activity bar with Containers, Images, Volumes, and Networks panes. Right-click a container for View Logs / Attach Shell / Restart / Inspect. It's effectively a click-driven replacement for `docker ps` and `docker logs` — saves real keystrokes on a workflow you'll repeat constantly.

### A pragmatic combo

For day-to-day operation, pick one tool per layer rather than running all of them at once:

- **Stays running:** Docker `--restart unless-stopped` for containerized work, systemd for the rest.
- **Day-to-day status and logs:** VS Code Container Tools sidebar (containers) or `journalctl -u name -f` (systemd services).
- **"How healthy is the box, where is the load going?":** Netdata via tunnel — leave it open in a browser tab while you work.
- **Service config / system overview:** Cockpit via tunnel — open it when you need it, not always.
