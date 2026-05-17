# POST-INSTALL.md

## Overview

This document covers what to do **after** `baseline.sh` finishes — things you'd typically install or configure to actually use the hardened server as a working environment. It does not modify or weaken the script's defaults; instead it documents the safe drop-ins (e.g., an `sshd_config` override for VS Code Remote-SSH) and the habits (e.g., loopback-binding container ports) needed to live with those defaults. Each section is self-contained: skip what you don't need. If you only run the script and SSH in occasionally to manage services, you can ignore this entirely — but if you plan to do development on the box itself, this is the practical companion to `README.md` and `WALKTHROUGH.md`.

## Table of Contents

- [Overview](#overview)
- [Compatibility](#compatibility)
  - [VS Code Remote-SSH (and other `-L` / `-D` tunneling tools)](#vs-code-remote-ssh-and-other--l--d-tunneling-tools)

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
