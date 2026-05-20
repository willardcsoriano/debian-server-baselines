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
echo -e "${BOLD}debian-dev-server${NC}"
echo -e "${DIM}Debian 13 developer tooling — run as your sudo user, after debian-server-baseline${NC}"
echo ""

# Must run as the sudo user, NOT root.  Rootless Docker, nvm, and Claude Code
# install per-user; running as root silently breaks the entire workflow.
[[ $EUID -eq 0 ]] && fail "Run as your sudo user, not root.  Try: bash dev-server.sh"

[[ -f /etc/os-release ]] || fail "Cannot detect OS."
# shellcheck source=/dev/null
. /etc/os-release
[[ "$ID" == "debian" ]]    || fail "Debian only. Detected: $ID"
[[ "$VERSION_ID" -ge 13 ]] || fail "Requires Debian 13+. Detected: $VERSION_ID"

SERVER_IP=$(hostname -I | awk '{print $1}')
pass "Debian $VERSION_ID ($VERSION_CODENAME) on $SERVER_IP"

# Confirm user has sudo access
groups | grep -qw sudo \
  || fail "$USER is not in the sudo group. Run debian-server-baseline.sh first."

# Confirm debian-server-baseline.sh has run: root SSH is off and firewall is active
grep -q "^PermitRootLogin no" /etc/ssh/sshd_config 2>/dev/null \
  || fail "debian-server-baseline.sh has not run on this host (PermitRootLogin still on)."
systemctl is-active --quiet ufw \
  || fail "debian-server-baseline.sh has not run on this host (UFW not active)."

# Confirm a user session is live — required by rootless Docker's systemd user
# daemon.  An SSH login gives you one automatically.  Running via sudo -s or su
# does not; log in as the user directly and re-run.
_user_uid=$(id -u)
_user_bus="/run/user/$_user_uid/bus"
[[ -S "$_user_bus" ]] \
  || fail "No user session at $_user_bus. Log in via SSH as $USER and re-run."

pass "Preflight OK — $USER, session confirmed"
echo ""

# ─── 1/5  Docker Engine (rootless) + Compose ─────────────────────────────────

section "1/5  Docker Engine (rootless) + Compose"

# DRIFT: apt repo format, package names, and rootless install procedure
# change roughly annually.  Verify before editing:
#   https://docs.docker.com/engine/install/debian/
#   https://docs.docker.com/engine/security/rootless/
# Last verified: 2026-05-19
# NOTE: this block is intentionally duplicated in prod-server.sh — the repo
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

# ─── 2/5  nvm + Node LTS ─────────────────────────────────────────────────────

section "2/5  nvm + Node LTS"

# DRIFT: version string in the raw GitHub URL changes with every nvm release.
# Check the latest tag before editing:
#   https://github.com/nvm-sh/nvm/releases
# The install script appends nvm init lines to ~/.bashrc — expected behavior.
# Last verified: 2026-05-19

NVM_DIR="$HOME/.nvm"
export NVM_DIR

if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
fi

# Source nvm into this shell — not automatic in a non-interactive script,
# even after the installer runs.
# shellcheck source=/dev/null
. "$NVM_DIR/nvm.sh"

nvm install --lts
nvm alias default 'lts/*'
NODE_VER=$(node --version)
pass "nvm installed; Node $NODE_VER (LTS) active"

# ─── 3/5  Corepack ───────────────────────────────────────────────────────────

section "3/5  Corepack"

# Enables pnpm and yarn on demand per project via package.json#packageManager.
# No global install needed; corepack downloads the right version at first use.
corepack enable
pass "Corepack enabled"

# ─── 4/5  Claude Code CLI ────────────────────────────────────────────────────

section "4/5  Claude Code CLI"

# DRIFT: package name and recommended install command may change.
# Verify before editing:
#   https://docs.anthropic.com/en/docs/claude-code
# Last verified: 2026-05-19

if command -v claude &>/dev/null; then
  CLAUDE_VER=$(claude --version 2>/dev/null | head -1 || echo "installed")
  pass "Claude Code already installed ($CLAUDE_VER)"
else
  npm install -g @anthropic-ai/claude-code
  CLAUDE_VER=$(claude --version 2>/dev/null | head -1 || echo "installed")
  pass "Claude Code CLI installed ($CLAUDE_VER)"
fi

# ─── 5/5  Operator extras: gh, make ──────────────────────────────────────────

section "5/5  Operator extras (gh, make)"

# ── gh ────────────────────────────────────────────────────────────────────────

# DRIFT: GPG key URL, sources entry format, and package name have changed before.
# Verify before editing:
#   https://github.com/cli/cli/blob/trunk/docs/install_linux.md
# Last verified: 2026-05-19

sudo mkdir -p /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/github-cli.gpg ]]; then
  sudo curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /etc/apt/keyrings/github-cli.gpg
  sudo chmod a+r /etc/apt/keyrings/github-cli.gpg
fi
if [[ ! -f /etc/apt/sources.list.d/github-cli.list ]]; then
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/github-cli.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
  sudo apt-get update -qq
fi
if command -v gh &>/dev/null; then
  GH_VER=$(gh --version 2>/dev/null | head -1 || echo "installed")
  pass "gh already installed ($GH_VER)"
else
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gh
  GH_VER=$(gh --version 2>/dev/null | head -1 || echo "installed")
  pass "gh installed ($GH_VER)"
fi

# ── make ──────────────────────────────────────────────────────────────────────

if command -v make &>/dev/null; then
  pass "make already installed"
else
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq make
  pass "make installed"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  debian-dev-server complete${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${GREEN}✓${NC} Docker: rootless + Compose, user daemon enabled, linger on"
echo -e "  ${GREEN}✓${NC} nvm + Node LTS: ${BOLD}$NODE_VER${NC}"
echo -e "  ${GREEN}✓${NC} Corepack: pnpm and yarn available on demand"
echo -e "  ${GREEN}✓${NC} Claude Code: $CLAUDE_VER"
echo -e "  ${GREEN}✓${NC} gh: $GH_VER"
echo -e "  ${GREEN}✓${NC} make: $(make --version | head -1)"
echo ""
echo -e "  Log in as: ${BOLD}ssh $USER@$SERVER_IP${NC}"
echo -e "  ${YELLOW}Reload your shell${NC} (${DIM}exec \$SHELL -l${NC}) to activate nvm and DOCKER_HOST."
echo -e "  ${DIM}This script is idempotent — re-run anytime to refresh.${NC}"
echo ""
