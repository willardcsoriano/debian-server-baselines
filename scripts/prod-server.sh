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
[[ $EUID -eq 0 ]] && fail "Run as your sudo user, not root.  Try: bash scripts/prod-server.sh"

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

# ─── 1/2  Docker Engine (rootless) + Compose ─────────────────────────────────

section "1/2  Docker Engine (rootless) + Compose"

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

# Allow rootless Docker to bind to port 80 (nginx).  Without this, the
# kernel rejects unprivileged binds below 1024 and the nginx container
# fails to start with nothing in the logs.
if ! grep -q "ip_unprivileged_port_start=80" /etc/sysctl.d/99-unprivileged-ports.conf 2>/dev/null; then
  echo "net.ipv4.ip_unprivileged_port_start=80" \
    | sudo tee /etc/sysctl.d/99-unprivileged-ports.conf > /dev/null
  sudo sysctl net.ipv4.ip_unprivileged_port_start=80 > /dev/null
fi

pass "Docker (rootless) + Compose installed; user daemon enabled; linger on"

# ─── 2/2  Bitwarden Secrets Manager CLI (bws) ────────────────────────────────

section "2/2  Bitwarden Secrets Manager CLI (bws)"

# DRIFT: bws is published as prebuilt zips on GitHub releases under
# bitwarden/sdk-sm with tag format bws-vX.Y.Z.  Asset names follow
# bws-<arch>-unknown-linux-gnu-<version>.zip with a sibling
# bws-sha256-checksums-<version>.txt.  cargo install bws is a non-starter:
# this host's compilers are mode 750 (root-only) per the baseline.
# Verify if Bitwarden ships an official install script or moves the repo:
#   https://bitwarden.com/help/secrets-manager-cli/
#   https://github.com/bitwarden/sdk-sm/releases
# NOTE: this block is intentionally duplicated in dev-server.sh (section
# 7/8) — the repo ships scripts via curl|bash (one link per script, no
# clone), so a shared lib/ helper would break the install model.  Keep both
# copies in sync; DRIFTCHECK.md tracks the canonical bws source.
# Last verified: 2026-05-22

mkdir -p "$HOME/.local/bin"
if ! grep -q 'HOME/.local/bin' "$HOME/.bashrc" 2>/dev/null; then
  cat >> "$HOME/.bashrc" <<'EOF'

# Per-user binaries (bws)
export PATH="$HOME/.local/bin:$PATH"
EOF
fi
export PATH="$HOME/.local/bin:$PATH"

# unzip is required by the bws install step; apt-get is idempotent.
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unzip

if command -v bws &>/dev/null; then
  BWS_VER=$(bws --version 2>/dev/null || echo "installed")
  pass "bws already installed ($BWS_VER)"
else
  _bws_tag=$(curl -fsSL https://api.github.com/repos/bitwarden/sdk-sm/releases \
    | grep -oP '"tag_name":\s*"\Kbws-v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  [[ -n "$_bws_tag" ]] || fail "Could not determine latest bws release tag"
  _bws_ver="${_bws_tag#bws-v}"

  case "$(dpkg --print-architecture)" in
    amd64) _bws_arch="x86_64-unknown-linux-gnu" ;;
    arm64) _bws_arch="aarch64-unknown-linux-gnu" ;;
    *)     fail "Unsupported architecture for bws: $(dpkg --print-architecture)" ;;
  esac
  _bws_asset="bws-${_bws_arch}-${_bws_ver}.zip"

  _tmp=$(mktemp -d)
  curl -fsSL -o "$_tmp/$_bws_asset" \
    "https://github.com/bitwarden/sdk-sm/releases/download/${_bws_tag}/${_bws_asset}"
  curl -fsSL -o "$_tmp/checksums.txt" \
    "https://github.com/bitwarden/sdk-sm/releases/download/${_bws_tag}/bws-sha256-checksums-${_bws_ver}.txt"
  ( cd "$_tmp" && grep " ${_bws_asset}\$" checksums.txt | sha256sum -c - >/dev/null ) \
    || fail "bws checksum mismatch for ${_bws_asset}"
  unzip -q "$_tmp/$_bws_asset" -d "$_tmp"
  install -m 0755 "$_tmp/bws" "$HOME/.local/bin/bws"
  rm -rf "$_tmp"
  BWS_VER=$(bws --version 2>/dev/null || echo "installed")
  pass "bws installed ($BWS_VER)"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  debian-prod-server complete${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${GREEN}✓${NC} Docker: rootless + Compose, user daemon enabled, linger on"
echo -e "  ${GREEN}✓${NC} Unprivileged port 80 enabled for rootless nginx"
echo -e "  ${GREEN}✓${NC} Bitwarden Secrets Manager CLI: $BWS_VER"
echo ""
echo -e "  Log in as: ${BOLD}ssh $USER@$SERVER_IP${NC}"
echo -e "  ${YELLOW}Reload your shell${NC} (${DIM}exec \$SHELL -l${NC}) to activate DOCKER_HOST and ~/.local/bin."
echo -e "  ${DIM}Authenticate to your container registry next:${NC} docker login ghcr.io"
echo -e "  ${DIM}  (this persists a credential to ~/.docker/config.json — wrap it with${NC}"
echo -e "  ${DIM}   bws + docker logout if you want nothing sitting on disk between deploys)${NC}"
echo -e "  ${DIM}Inject deploy secrets without writing them to disk:${NC}"
echo -e "  ${DIM}  export BWS_ACCESS_TOKEN=<machine-account-token>   # never checked in${NC}"
echo -e "  ${DIM}  bws run --project-id <project-id> -- docker compose up -d${NC}"
echo -e "  ${DIM}This script is idempotent — re-run anytime to refresh.${NC}"
echo ""
