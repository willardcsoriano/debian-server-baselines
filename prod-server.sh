#!/usr/bin/env bash
set -euo pipefail

# ─── Output helpers ───────────────────────────────────────────────────────────

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

pass()    { echo -e "  ${GREEN}✓${NC} $1"; }
warn()    { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail()    { echo -e "\n  ${RED}✗${NC} $1\n"; exit 1; }
section() { echo -e "\n${BOLD}▸ $1${NC}"; }
note()    { echo -e "  ${DIM}$1${NC}"; }

# ─── Preflight ────────────────────────────────────────────────────────────────

clear
echo -e "${BOLD}debian-prod-server${NC}"
echo -e "${DIM}Debian 13 prod host — container runtime only, no dev tooling${NC}"
echo ""

# Must run as the sudo user, NOT root.  Rootless Docker installs per-user;
# running as root silently breaks the entire workflow.
[[ $EUID -eq 0 ]] && fail "Run as your sudo user, not root.  Try: bash prod-server.sh"

[[ -f /etc/os-release ]] || fail "Cannot detect OS."
# shellcheck source=/dev/null
. /etc/os-release
[[ "$ID" == "debian" ]]    || fail "Debian only. Detected: $ID"
[[ "$VERSION_ID" -ge 13 ]] || fail "Requires Debian 13+. Detected: $VERSION_ID"

SERVER_IP=$(hostname -I | awk '{print $1}')
pass "Debian $VERSION_ID ($VERSION_CODENAME) on $SERVER_IP"

# Confirm user has sudo access
groups | grep -qw sudo \
  || fail "$USER is not in the sudo group. Run base-server.sh first."

# Confirm base-server.sh has run: root SSH is off and firewall is active
grep -q "^PermitRootLogin no" /etc/ssh/sshd_config 2>/dev/null \
  || fail "base-server.sh has not run on this host (PermitRootLogin still on)."
systemctl is-active --quiet ufw \
  || fail "base-server.sh has not run on this host (UFW not active)."

# Confirm a user session is live — required by rootless Docker's systemd user
# daemon.  An SSH login gives you one automatically.  Running via sudo -s or su
# does not; log in as the user directly and re-run.
_user_uid=$(id -u)
_user_bus="/run/user/$_user_uid/bus"
[[ -S "$_user_bus" ]] \
  || fail "No user session at $_user_bus. Log in via SSH as $USER and re-run."

pass "Preflight OK — $USER, session confirmed"
echo ""

# ─── 1/1  Docker Engine (rootless) + Compose ─────────────────────────────────

section "1/1  Docker Engine (rootless) + Compose"

# DRIFT: apt repo format, package names, and rootless install procedure
# change roughly annually.  Verify before editing:
#   https://docs.docker.com/engine/install/debian/
#   https://docs.docker.com/engine/security/rootless/
# Last verified: 2026-05-19
# NOTE: this block is intentionally duplicated in dev-server.sh — the repo
# ships scripts via curl|bash (one link per script, no clone), so a shared
# lib/ helper would break the install model.  Keep both copies in sync;
# DRIFTCHECK.md tracks the canonical Docker source.

sudo mkdir -p /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
  sudo curl -fsSL https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
fi
if [[ ! -f /etc/apt/sources.list.d/docker.sources ]]; then
  cat <<EOF | sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  sudo apt-get update -qq
fi
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin \
  docker-ce-rootless-extras uidmap

# Disable the system-mode daemon — rootless replaces it
sudo systemctl disable --now docker.service docker.socket 2>/dev/null || true

# Rootless Docker requires /etc/subuid and /etc/subgid entries (65536 UIDs).
# adduser creates these automatically, but pre-existing users (e.g. from a
# VPS image) may be missing them.  Ensure they exist before running setup.
if ! grep -q "^$USER:" /etc/subuid 2>/dev/null; then
  sudo usermod --add-subuids 100000-165535 "$USER"
  note "Added subuid range for $USER"
fi
if ! grep -q "^$USER:" /etc/subgid 2>/dev/null; then
  sudo usermod --add-subgids 100000-165535 "$USER"
  note "Added subgid range for $USER"
fi

# Set up rootless daemon.  Check for the systemd user service file, not the
# binary — the binary exists even after a partial setup without XDG_RUNTIME_DIR,
# so a partial install would otherwise be silently skipped on re-run.
_docker_svc="$HOME/.config/systemd/user/docker.service"
if [[ ! -f "$_docker_svc" ]]; then
  XDG_RUNTIME_DIR="/run/user/$_user_uid" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=$_user_bus" \
  dockerd-rootless-setuptool.sh install \
    || warn "Rootless setup failed — run 'dockerd-rootless-setuptool.sh install' manually"
fi

# Enable user daemon and linger so the daemon survives logout
XDG_RUNTIME_DIR="/run/user/$_user_uid" \
DBUS_SESSION_BUS_ADDRESS="unix:path=$_user_bus" \
systemctl --user enable --now docker \
  || warn "Could not enable docker user service — run 'systemctl --user enable --now docker' manually"
sudo loginctl enable-linger "$USER"

# Persist DOCKER_HOST in .bashrc so docker commands work after login
if ! grep -q 'DOCKER_HOST' "$HOME/.bashrc" 2>/dev/null; then
  cat >> "$HOME/.bashrc" <<'EOF'

# rootless Docker
export PATH=/usr/bin:$PATH
export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock
EOF
fi

pass "Docker (rootless) + Compose installed; user daemon enabled; linger on"

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  debian-prod-server complete${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${GREEN}✓${NC} Docker: rootless + Compose, user daemon enabled, linger on"
echo ""
echo -e "  Log in as: ${BOLD}ssh $USER@$SERVER_IP${NC}"
echo -e "  ${YELLOW}Reload your shell${NC} (${DIM}exec \$SHELL -l${NC}) to activate DOCKER_HOST."
echo -e "  ${DIM}Authenticate to your container registry next:${NC} docker login ghcr.io"
echo -e "  ${DIM}This script is idempotent — re-run anytime to refresh.${NC}"
echo ""
