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
echo -e "${DIM}Debian 13 developer tooling — run as your sudo user, after base-server${NC}"
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

# ─── 1/8  Docker Engine (rootless) + Compose ─────────────────────────────────

section "1/8  Docker Engine (rootless) + Compose"

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

# Allow rootless Docker to bind to port 80 (nginx).  Without this, the
# kernel rejects unprivileged binds below 1024 and the nginx container
# fails to start with nothing in the logs.
if ! grep -q "ip_unprivileged_port_start=80" /etc/sysctl.d/99-unprivileged-ports.conf 2>/dev/null; then
  echo "net.ipv4.ip_unprivileged_port_start=80" \
    | sudo tee /etc/sysctl.d/99-unprivileged-ports.conf > /dev/null
  sudo sysctl net.ipv4.ip_unprivileged_port_start=80 > /dev/null
fi

pass "Docker (rootless) + Compose installed; user daemon enabled; linger on"

# ─── 2/8  nvm + Node LTS ─────────────────────────────────────────────────────

section "2/8  nvm + Node LTS"

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

# ─── 3/8  Corepack ───────────────────────────────────────────────────────────

section "3/8  Corepack"

# Enables pnpm and yarn on demand per project via package.json#packageManager.
# No global install needed; corepack downloads the right version at first use.
corepack enable
pass "Corepack enabled"

# ─── 4/8  Claude Code CLI ────────────────────────────────────────────────────

section "4/8  Claude Code CLI"

# DRIFT: Anthropic's native installer is the recommended path.  The npm
# package @anthropic-ai/claude-code still ships but couples claude to a
# specific nvm-managed Node version — when nvm bumps LTS the global bin
# is orphaned and claude appears uninstalled.  The native installer
# drops a self-updating binary in ~/.local/bin/claude, decoupled from
# Node entirely.  Verify before editing:
#   https://code.claude.com/docs/en/setup
# Last verified: 2026-05-22

# Per-user bin dir shared with bw (6/8) and bws (7/8); set up here so
# claude's install location is on PATH before its idempotency check runs.
mkdir -p "$HOME/.local/bin"
if ! grep -q 'HOME/.local/bin' "$HOME/.bashrc" 2>/dev/null; then
  cat >> "$HOME/.bashrc" <<'EOF'

# Per-user binaries (claude, bw, bws)
export PATH="$HOME/.local/bin:$PATH"
EOF
fi
export PATH="$HOME/.local/bin:$PATH"

if command -v claude &>/dev/null; then
  CLAUDE_VER=$(claude --version 2>/dev/null | head -1 || echo "installed")
  pass "Claude Code already installed ($CLAUDE_VER)"
else
  curl -fsSL https://claude.ai/install.sh | bash
  CLAUDE_VER=$(claude --version 2>/dev/null | head -1 || echo "installed")
  pass "Claude Code CLI installed ($CLAUDE_VER)"
fi

# ─── 5/8  Operator extras: gh, make ──────────────────────────────────────────

section "5/8  Operator extras (gh, make)"

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

# ─── 6/8  Bitwarden CLI (bw) ─────────────────────────────────────────────────

section "6/8  Bitwarden CLI (bw)"

# DRIFT: bw is published as prebuilt zips on GitHub releases under
# bitwarden/clients with tag format cli-vYYYY.M.P.  Asset names follow
# bw-linux-<version>.zip (amd64) and bw-linux-arm64-<version>.zip (arm64).
# Bitwarden's documented bitwarden.com/download/?app=cli&platform=linux
# redirect serves amd64 only — GitHub releases give arch coverage and
# version visibility.  Verify if release-asset naming changes:
#   https://bitwarden.com/help/cli/
#   https://github.com/bitwarden/clients/releases
# ENV_STACK.md forbids npm -g entirely, so the standalone binary is the
# only path that fits.
# Last verified: 2026-05-22

# Per-user bin dir and PATH are set up in section 4/8 (shared with claude).

# unzip is required by both bw and bws install steps; apt-get is idempotent.
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unzip

if command -v bw &>/dev/null; then
  BW_VER=$(bw --version 2>/dev/null || echo "installed")
  pass "Bitwarden CLI already installed ($BW_VER)"
else
  _bw_tag=$(curl -fsSL https://api.github.com/repos/bitwarden/clients/releases \
    | grep -oP '"tag_name":\s*"\Kcli-v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  [[ -n "$_bw_tag" ]] || fail "Could not determine latest bw release tag"
  _bw_ver="${_bw_tag#cli-v}"

  case "$(dpkg --print-architecture)" in
    amd64) _bw_asset="bw-linux-${_bw_ver}.zip" ;;
    arm64) _bw_asset="bw-linux-arm64-${_bw_ver}.zip" ;;
    *)     fail "Unsupported architecture for bw: $(dpkg --print-architecture)" ;;
  esac

  _tmp=$(mktemp -d)
  curl -fsSL -o "$_tmp/bw.zip" \
    "https://github.com/bitwarden/clients/releases/download/${_bw_tag}/${_bw_asset}"
  unzip -q "$_tmp/bw.zip" -d "$_tmp"
  install -m 0755 "$_tmp/bw" "$HOME/.local/bin/bw"
  rm -rf "$_tmp"
  BW_VER=$(bw --version 2>/dev/null || echo "installed")
  pass "Bitwarden CLI installed ($BW_VER)"
fi

# ─── 7/8  Bitwarden Secrets Manager CLI (bws) ────────────────────────────────

section "7/8  Bitwarden Secrets Manager CLI (bws)"

# DRIFT: bws is published as prebuilt zips on GitHub releases under
# bitwarden/sdk-sm with tag format bws-vX.Y.Z.  Asset names follow
# bws-<arch>-unknown-linux-gnu-<version>.zip with a sibling
# bws-sha256-checksums-<version>.txt.  cargo install bws is a non-starter:
# this host's compilers are mode 750 (root-only) per the baseline.
# Verify if Bitwarden ships an official install script or moves the repo:
#   https://bitwarden.com/help/secrets-manager-cli/
#   https://github.com/bitwarden/sdk-sm/releases
# NOTE: this block is intentionally duplicated in prod-server.sh (section
# 2/2) — the repo ships scripts via curl|bash (one link per script, no
# clone), so a shared lib/ helper would break the install model.  Keep both
# copies in sync; DRIFTCHECK.md tracks the canonical bws source.
# Last verified: 2026-05-22

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

# ─── 8/8  Antigravity CLI ────────────────────────────────────────────────────

section "8/8  Antigravity CLI"

# DRIFT: Google deprecated Gemini CLI on 2026-06-18 — for AI Pro/Ultra and
# free-tier accounts it stopped serving requests and is superseded by
# Antigravity CLI (agy).  (Gemini CLI now works only with paid Gemini
# Enterprise API keys.)  Google's native installer is the supported path: it
# resolves the latest native binary from a Google-hosted manifest, verifies the
# download's SHA512 against that manifest (halts on mismatch), and drops a
# self-contained, Node-independent binary in ~/.local/bin/agy — no npm, no nvm
# coupling, mirroring the claude installer in section 4/8.  There is no
# version-pinning env var; it always installs the latest.  Verify before
# editing (installer path, binary name, or auth flow):
#   https://antigravity.google/docs/cli-install
#   https://github.com/google-antigravity/antigravity-cli
# On a headless server agy authenticates on first run by detecting the SSH
# session and printing a Google Sign-In URL to complete in a local browser.
# Import an existing Gemini CLI config with:  agy plugin import gemini
# Last verified: 2026-07-06

# Per-user bin dir and PATH are set up in section 4/8 (shared with claude).

if command -v agy &>/dev/null; then
  AGY_VER=$(agy --version 2>/dev/null | head -1 || echo "installed")
  pass "Antigravity CLI already installed ($AGY_VER)"
else
  curl -fsSL https://antigravity.google/cli/install.sh | bash
  AGY_VER=$(agy --version 2>/dev/null | head -1 || echo "installed")
  pass "Antigravity CLI installed ($AGY_VER)"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  debian-dev-server complete${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${GREEN}✓${NC} Docker: rootless + Compose, user daemon enabled, linger on"
echo -e "  ${GREEN}✓${NC} Unprivileged port 80 enabled for rootless nginx"
echo -e "  ${GREEN}✓${NC} nvm + Node LTS: ${BOLD}$NODE_VER${NC}"
echo -e "  ${GREEN}✓${NC} Corepack: pnpm and yarn available on demand"
echo -e "  ${GREEN}✓${NC} Claude Code: $CLAUDE_VER"
echo -e "  ${GREEN}✓${NC} gh: $GH_VER"
echo -e "  ${GREEN}✓${NC} make: $(make --version | head -1)"
echo -e "  ${GREEN}✓${NC} Bitwarden CLI: $BW_VER"
echo -e "  ${GREEN}✓${NC} Bitwarden Secrets Manager CLI: $BWS_VER"
echo -e "  ${GREEN}✓${NC} Antigravity CLI: $AGY_VER ${DIM}(native binary, no Node)${NC}"
echo ""
echo -e "  Log in as: ${BOLD}ssh $USER@$SERVER_IP${NC}"
echo -e "  ${YELLOW}Reload your shell${NC} (${DIM}exec \$SHELL -l${NC}) to activate nvm, DOCKER_HOST, and ~/.local/bin."
echo -e "  ${DIM}This script is idempotent — re-run anytime to refresh.${NC}"
echo ""
