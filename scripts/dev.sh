#!/usr/bin/env bash
set -Eeuo pipefail   # -E: the ERR trap below also fires inside functions

# ─── Output helpers ───────────────────────────────────────────────────────────

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

WARNINGS=()
CURRENT_SECTION="preflight"

pass()    { echo -e "  ${GREEN}✓${NC} $1"; }
warn()    { echo -e "  ${YELLOW}⚠${NC} $1"; WARNINGS+=("[$CURRENT_SECTION] $1"); }
fail()    { echo -e "\n  ${RED}✗${NC} $1\n"; exit 1; }
section() { CURRENT_SECTION="$1"; echo -e "\n${BOLD}▸ $1${NC}  ${DIM}$(date +%H:%M:%S)${NC}"; }
note()    { echo -e "  ${DIM}$1${NC}"; }

# ─── Logging and error reporting ──────────────────────────────────────────────

clear 2>/dev/null || true   # cosmetic; must not abort a run with no TERM

# Every run is logged in full (mode 600 -- it records hostnames and paths, no
# secrets: sudo reads its password from the terminal, never from this stream).
LOG_DIR="$HOME/.local/state/debian-server-baselines"
mkdir -p "$LOG_DIR" && chmod 700 "$LOG_DIR"
LOG="$LOG_DIR/dev-$(date +%Y%m%d-%H%M%S)-$$.log"
( umask 077 && : > "$LOG" )
exec > >(tee -a "$LOG") 2>&1

# Name the failing command, line and section instead of dying silently.
on_err() {
  local rc=$? line=$1 cmd=$2
  echo -e "\n  ${RED}✗${NC} Failed in section '$CURRENT_SECTION' at line $line (exit $rc):"
  echo -e "    ${DIM}$cmd${NC}"
}
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR

# Always end with a summary and one greppable RESULT line, success or not.
on_exit() {
  local rc=$?
  [[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
  echo ""
  if (( ${#WARNINGS[@]} )); then
    echo -e "${YELLOW}Warnings (${#WARNINGS[@]}):${NC}"
    printf '  - %s\n' "${WARNINGS[@]}"
  fi
  if (( rc == 0 )); then
    echo "RESULT: OK ($(date -Is), ${#WARNINGS[@]} warning(s))"
  else
    echo "RESULT: FAILED in section '$CURRENT_SECTION' (exit $rc, $(date -Is))"
  fi
  echo "Log: $LOG"
}
trap on_exit EXIT

# ─── Preflight ────────────────────────────────────────────────────────────────

echo -e "${BOLD}dev.sh${NC}"
echo -e "${DIM}Debian 13 developer tooling — run as your sudo user, after base.sh${NC}"
echo ""

# Must run as the sudo user, NOT root.  Rootless Docker, nvm, and Claude Code
# install per-user; running as root silently breaks the entire workflow.
[[ $EUID -eq 0 ]] && fail "Run as your sudo user, not root.  Try: bash scripts/dev.sh"

[[ -f /etc/os-release ]] || fail "Cannot detect OS."
# shellcheck source=/dev/null
. /etc/os-release
[[ "$ID" == "debian" ]]    || fail "Debian only. Detected: $ID"
[[ "$VERSION_ID" -ge 13 ]] || fail "Requires Debian 13+. Detected: $VERSION_ID"

SERVER_IP=$(hostname -I | awk '{print $1}')
pass "Debian $VERSION_ID ($VERSION_CODENAME) on $SERVER_IP"

# Confirm user has sudo access
groups | grep -qw sudo \
  || fail "$USER is not in the sudo group. Run base.sh first."

# Confirm base.sh has run: root SSH is off and firewall is active
grep -q "^PermitRootLogin no" /etc/ssh/sshd_config 2>/dev/null \
  || fail "base.sh has not run on this host (PermitRootLogin still on)."
systemctl is-active --quiet ufw \
  || fail "base.sh has not run on this host (UFW not active)."

# Confirm a user session is live — required by rootless Docker's systemd user
# daemon.  An SSH login gives you one automatically.  Running via sudo -s or su
# does not; log in as the user directly and re-run.
_user_uid=$(id -u)
_user_bus="/run/user/$_user_uid/bus"
[[ -S "$_user_bus" ]] \
  || fail "No user session at $_user_bus. Log in via SSH as $USER and re-run."

pass "Preflight OK — $USER, session confirmed"

# Ask for the sudo password once, up front, and keep the credential fresh so
# a slow step (nvm, apt) can't leave a later step waiting at a prompt.
sudo -v || fail "sudo authentication failed"
( while kill -0 $$ 2>/dev/null; do sudo -n true 2>/dev/null || true; sleep 50; done ) &
SUDO_KEEPALIVE_PID=$!
pass "sudo credential cached for this run"
note "Logging to $LOG"
echo ""

# ─── 1/9  Docker Engine (rootless) + Compose ─────────────────────────────────

section "1/9  Docker Engine (rootless) + Compose"

# DRIFT: apt repo format, package names, and rootless install procedure
# change roughly annually.  Verify before editing:
#   https://docs.docker.com/engine/install/debian/
#   https://docs.docker.com/engine/security/rootless/
# Last verified: 2026-05-19
# NOTE: this block is intentionally duplicated in prod.sh — the repo
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
# --no-upgrade: a re-run installs what's missing but never upgrades the
# engine under running containers.  Upgrading Docker is a deliberate act
# (apt-get install --only-upgrade docker-ce ...), not a side effect of refresh.
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-upgrade \
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

# ─── 2/9  nvm + Node LTS ─────────────────────────────────────────────────────

section "2/9  nvm + Node LTS"

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

# ─── 3/9  Corepack ───────────────────────────────────────────────────────────

section "3/9  Corepack"

# Enables pnpm and yarn on demand per project via package.json#packageManager.
# No global install needed; corepack downloads the right version at first use.
corepack enable
pass "Corepack enabled"

# ─── 4/9  Claude Code CLI ────────────────────────────────────────────────────

section "4/9  Claude Code CLI"

# DRIFT: Anthropic's native installer is the recommended path.  The npm
# package @anthropic-ai/claude-code still ships but couples claude to a
# specific nvm-managed Node version — when nvm bumps LTS the global bin
# is orphaned and claude appears uninstalled.  The native installer
# drops a self-updating binary in ~/.local/bin/claude, decoupled from
# Node entirely.  Verify before editing:
#   https://code.claude.com/docs/en/setup
# Last verified: 2026-05-22

# Per-user bin dir shared with bw (6/9) and bws (7/9); set up here so
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

# ─── 5/9  Operator extras: gh, make ──────────────────────────────────────────

section "5/9  Operator extras (gh, make)"

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

# ─── 6/9  Bitwarden CLI (bw) ─────────────────────────────────────────────────

section "6/9  Bitwarden CLI (bw)"

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

# Per-user bin dir and PATH are set up in section 4/9 (shared with claude).

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

# ─── 7/9  Bitwarden Secrets Manager CLI (bws) ────────────────────────────────

section "7/9  Bitwarden Secrets Manager CLI (bws)"

# DRIFT: bws is published as prebuilt zips on GitHub releases under
# bitwarden/sdk-sm with tag format bws-vX.Y.Z.  Asset names follow
# bws-<arch>-unknown-linux-gnu-<version>.zip with a sibling
# bws-sha256-checksums-<version>.txt.  cargo install bws is a non-starter:
# this host's compilers are mode 750 (root-only) per the baseline.
# Verify if Bitwarden ships an official install script or moves the repo:
#   https://bitwarden.com/help/secrets-manager-cli/
#   https://github.com/bitwarden/sdk-sm/releases
# NOTE: this block is intentionally duplicated in prod.sh (section
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

# ─── 8/9  Antigravity CLI ────────────────────────────────────────────────────

section "8/9  Antigravity CLI"

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

# Per-user bin dir and PATH are set up in section 4/9 (shared with claude).

if command -v agy &>/dev/null; then
  AGY_VER=$(agy --version 2>/dev/null | head -1 || echo "installed")
  pass "Antigravity CLI already installed ($AGY_VER)"
else
  curl -fsSL https://antigravity.google/cli/install.sh | bash
  AGY_VER=$(agy --version 2>/dev/null | head -1 || echo "installed")
  pass "Antigravity CLI installed ($AGY_VER)"
fi

# ─── 9/9  Long-running agent host ────────────────────────────────────────────

section "9/9  Long-running agent host"

# For hosts that keep many long-lived AI agent sessions (claude, agy) in tmux.
# Four failure modes, four fixes -- full rationale and operations in
# docs/agent-host.md:
#   a. Swap headroom: idle sessions page out and fill a small swap file,
#      leaving no buffer for a burst (several VS Code windows).
#   b. OOM victim choice: at the default oom_score_adj an agent scores the
#      same as vscode-server, so the kernel may kill an irreplaceable agent
#      before the reconnectable editor server.
#   c. Reboots: a reboot kills every session.  agent-sessions records each
#      tmux session's conversation ID so one command brings them all back.
#   d. Transcript retention: Claude Code deletes transcripts after
#      cleanupPeriodDays (default 30), after which an idle session can't be
#      resumed.  Raised machine-wide via managed settings.  PRIVACY: longer
#      retention keeps more conversation data -- possibly client records --
#      on disk; this host's disk is the boundary that has to protect it.
# Tunables (env): SWAP_TARGET_GB (default 16), CLAUDE_RETENTION_DAYS (default 90)

SWAP_TARGET_GB="${SWAP_TARGET_GB:-16}"
CLAUDE_RETENTION_DAYS="${CLAUDE_RETENTION_DAYS:-90}"

# ── a. Swap ───────────────────────────────────────────────────────────────────

# Adds a second swap file for the shortfall instead of resizing the existing
# one: resizing means swapoff, which forces every paged-out idle session back
# into RAM at once.  Swap lives on the server's local disk -- no extra cost.
_extra_swap=/swapfile.agents
_gib=$((1024 * 1024))   # KiB per GiB
_swap_kb=$(awk '/^SwapTotal:/ { print $2 }' /proc/meminfo)
if [[ -e "$_extra_swap" ]] && ! grep -q "^$_extra_swap " /proc/swaps; then
  sudo swapon "$_extra_swap" && note "Re-activated existing $_extra_swap"
  _swap_kb=$(awk '/^SwapTotal:/ { print $2 }' /proc/meminfo)
fi
if (( _swap_kb + _gib >= SWAP_TARGET_GB * _gib )); then
  pass "Swap: $(( (_swap_kb + _gib / 2) / _gib )) GiB (target ${SWAP_TARGET_GB} GiB)"
elif [[ -e "$_extra_swap" ]]; then
  warn "Swap below target but $_extra_swap already exists -- inspect with: swapon --show"
else
  _need_gb=$(( (SWAP_TARGET_GB * _gib - _swap_kb + _gib - 1) / _gib ))
  _fs=$(findmnt -no FSTYPE /)
  _free_gb=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')
  if [[ "$_fs" != ext4 && "$_fs" != xfs ]]; then
    warn "Root filesystem is $_fs -- swap file not created (needs ext4 or xfs)"
  elif (( _free_gb < _need_gb + 20 )); then
    warn "Only ${_free_gb} GiB free -- need ${_need_gb} GiB plus 20 GiB headroom; swap not extended"
  else
    sudo fallocate -l "${_need_gb}G" "$_extra_swap"
    sudo chmod 600 "$_extra_swap"
    sudo mkswap -q "$_extra_swap"
    sudo swapon "$_extra_swap"
    grep -q "^$_extra_swap " /etc/fstab \
      || echo "$_extra_swap none swap sw 0 0" | sudo tee -a /etc/fstab > /dev/null
    _swap_kb=$(awk '/^SwapTotal:/ { print $2 }' /proc/meminfo)
    pass "Swap: added ${_need_gb} GiB at $_extra_swap -- now $(( (_swap_kb + _gib / 2) / _gib )) GiB"
  fi
fi

# ── b. OOM priority ───────────────────────────────────────────────────────────

# A root timer rather than a one-shot: processes started before the first run
# need it, and lowering oom_score_adj requires root.  systemd-oomd was
# considered and rejected -- it kills whole cgroups, i.e. several agents at once.
sudo tee /usr/local/sbin/agent-oom-priority > /dev/null <<'AGENT_OOM_EOF'
#!/usr/bin/env bash
# agent-oom-priority — when memory runs out, make the kernel kill VS Code's
# server (it reconnects) before long-lived tmux agent sessions (they don't).
#
# Sets oom_score_adj on every tmux server and everything under it (agent
# sessions, their MCP servers) to AGENT_ADJ, and on every ~/.vscode-server
# process tree to EDITOR_ADJ.  Children inherit oom_score_adj at fork, so new
# panes start protected; this pass covers processes that existed before it.
# Runs as root from agent-oom-priority.timer (lowering a score needs
# CAP_SYS_RESOURCE).  -n prints the changes instead of making them.
#
# Installed by debian-server-baselines scripts/dev.sh (section 9/9); see
# docs/agent-host.md.  Re-running dev.sh overwrites this file.
set -uo pipefail

AGENT_ADJ=-500   # not -1000: a genuinely runaway agent must stay killable
EDITOR_ADJ=500

dry=0
[[ "${1:-}" == "-n" ]] && dry=1

servers=" $(pgrep -x 'tmux: server' | tr '\n' ' ') "

ps -eo pid=,ppid=,args= | awk -v servers="$servers" -v a="$AGENT_ADJ" -v e="$EDITOR_ADJ" '
  { pid = $1; pp[pid] = $2; $1 = $2 = ""; args[pid] = $0; order[n++] = pid }
  END {
    for (i = 0; i < n; i++) {
      p = order[i]; q = p; adj = ""
      # The nearest matching ancestor decides; tmux servers are daemonized,
      # so a pane is never classified as vscode even if tmux was first
      # started from a VS Code terminal.
      while (q > 1 && (q in pp)) {
        if (index(servers, " " q " ")) { adj = a; break }
        if (args[q] ~ /\/\.vscode-server\//) { adj = e; break }
        q = pp[q]
      }
      if (adj != "") print p, adj
    }
  }' | while read -r pid want; do
    cur=$(cat "/proc/$pid/oom_score_adj" 2>/dev/null) || continue   # exited meanwhile
    [[ "$cur" == "$want" ]] && continue
    if (( dry )); then
      echo "$pid $(cat "/proc/$pid/comm" 2>/dev/null): $cur -> $want"
    else
      echo "$want" > "/proc/$pid/oom_score_adj" 2>/dev/null || true
    fi
  done
exit 0
AGENT_OOM_EOF
sudo chmod 0755 /usr/local/sbin/agent-oom-priority

sudo tee /etc/systemd/system/agent-oom-priority.service > /dev/null <<'EOF'
[Unit]
Description=Prefer vscode-server over tmux agent sessions as OOM victims

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/agent-oom-priority
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateNetwork=yes
EOF
sudo tee /etc/systemd/system/agent-oom-priority.timer > /dev/null <<'EOF'
[Unit]
Description=Re-apply agent OOM priorities every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now agent-oom-priority.timer > /dev/null
sudo systemctl start agent-oom-priority.service
pass "OOM priority: tmux agents -500, vscode-server +500 (agent-oom-priority.timer, every 1 min)"

# ── c. Session snapshot / restore ─────────────────────────────────────────────

tee "$HOME/.local/bin/agent-sessions" > /dev/null <<'AGENT_SESSIONS_EOF'
#!/usr/bin/env bash
# agent-sessions — remember which AI agent conversation runs in which tmux
# session, so a reboot doesn't cost you the sessions.
#
#   agent-sessions snapshot          record live tmux sessions (a user timer runs this every 5 min)
#   agent-sessions list              show what's recorded and whether each session is live
#   agent-sessions restore [-n]      recreate missing tmux sessions and resume each conversation
#                                    (-n: dry run, print what would happen)
#   agent-sessions forget NAME       drop a session from the record
#   agent-sessions hint              one-line notice if sessions are waiting to be restored
#
# Installed by debian-server-baselines scripts/dev.sh (section 9/9); see
# docs/agent-host.md.  Re-running dev.sh overwrites this file.
#
# DRIFT: reads ~/.claude/sessions/<pid>.json, an internal Claude Code file
# (fields used: pid, sessionId, cwd, tmux = "<session>:@<window>.%<pane>").
# It is not a documented interface.  If its shape changes, claude panes are
# recorded without a sessionId and `list`/`restore` say so -- nothing is
# guessed.  Last verified: 2026-10-12 against Claude Code 2.1.296.
set -euo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agent-sessions"
MANIFEST="$STATE_DIR/manifest.json"
CLAUDE_SESSIONS_DIR="$HOME/.claude/sessions"
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)

# Test seams: run against a private tmux server / a stand-in claude command.
TMUX_CMD=(tmux)
[[ -n "${AGENT_SESSIONS_TMUX_SOCKET:-}" ]] && TMUX_CMD=(tmux -L "$AGENT_SESSIONS_TMUX_SOCKET")
CLAUDE_RESUME_CMD="${AGENT_SESSIONS_CLAUDE_CMD:-claude}"

die() { echo "agent-sessions: $*" >&2; exit 1; }
command -v jq >/dev/null || die "jq is required"

load_manifest() {
  if [[ -s "$MANIFEST" ]] && jq -e '.sessions | type == "array"' "$MANIFEST" >/dev/null 2>&1; then
    cat "$MANIFEST"
  else
    echo '{"sessions":[]}'
  fi
}

# Live tmux sessions as JSON: [{tmux, cwd, command}] -- first pane of each session.
live_tmux_json() {
  "${TMUX_CMD[@]}" list-panes -a \
    -F '#{session_name}	#{window_index}	#{pane_index}	#{pane_current_path}	#{pane_current_command}' 2>/dev/null \
    | sort -t$'\t' -k1,1 -k2,2n -k3,3n \
    | awk -F'\t' '!seen[$1]++ { print $1 "\t" $4 "\t" $5 }' \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {tmux: .[0], cwd: .[1], command: .[2]})'
}

# Live claude processes that report a tmux pane: [{tmux, sessionId, cwd}].
live_claude_json() {
  local f pid out='[]'
  shopt -s nullglob
  for f in "$CLAUDE_SESSIONS_DIR"/*.json; do
    pid=$(basename "$f" .json)
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    # Skip stale files and recycled PIDs.
    [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == "claude" ]] || continue
    out=$(jq -c --argjson acc "$out" '
      if (.tmux | type) == "string" and (.sessionId | type) == "string"
      then $acc + [{tmux: (.tmux | split(":")[0]), sessionId, cwd}]
      else $acc end' "$f" 2>/dev/null || echo "$out")
  done
  echo "$out"
}

cmd_snapshot() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  local live claude old new
  live=$(live_tmux_json)
  claude=$(live_claude_json)
  old=$(load_manifest)
  new=$(jq -n -c --argjson live "$live" --argjson claude "$claude" --argjson old "$old" \
      --arg boot "$BOOT_ID" --arg now "$(date -Is)" '
    ($live | map(.tmux)) as $names
    | [ $live[] as $t
        | ([ $claude[] | select(.tmux == $t.tmux) ] | first) as $c
        | if $c then {tmux: $t.tmux, kind: "claude", cwd: ($c.cwd // $t.cwd), sessionId: $c.sessionId}
          else {tmux: $t.tmux, kind: "other", cwd: $t.cwd, command: $t.command} end
        | . + {boot: $boot, seen: $now} ]
    # Keep sessions last seen in an earlier boot (lost to a reboot, not yet
    # restored).  A session that disappeared during this boot was closed on
    # purpose, so it is dropped.
    + [ $old.sessions[] | select((.tmux | IN($names[])) | not) | select(.boot != $boot) ]
    | {version: 1, sessions: .}')
  printf '%s\n' "$new" > "$MANIFEST.tmp"
  mv "$MANIFEST.tmp" "$MANIFEST"
}

live_names() { "${TMUX_CMD[@]}" list-sessions -F '#{session_name}' 2>/dev/null || true; }

cmd_list() {
  local live
  live=$(live_names | jq -R -s -c 'split("\n") | map(select(length > 0))')
  load_manifest | jq -r --argjson live "$live" '
    .sessions[]
    | [ .tmux,
        (if (.tmux | IN($live[])) then "live" else "MISSING" end),
        .kind,
        (if .kind == "claude" then .sessionId else (.command // "-") end),
        .cwd,
        .seen ]
    | @tsv' | column -t -s $'\t' -N SESSION,STATE,KIND,CONVERSATION/CMD,CWD,LAST_SEEN
}

cmd_restore() {
  local dry=0
  [[ "${1:-}" == "-n" ]] && dry=1
  local live entries restored=0 skipped=0 seen_ids=" "
  live=" $(live_names | tr '\n' ' ') "
  entries=$(load_manifest | jq -c '.sessions[]')
  [[ -n "$entries" ]] || { echo "Nothing recorded yet."; return 0; }

  while IFS= read -r e; do
    local name kind cwd sid cmd
    name=$(jq -r '.tmux' <<<"$e"); kind=$(jq -r '.kind' <<<"$e")
    cwd=$(jq -r '.cwd' <<<"$e");   sid=$(jq -r '.sessionId // empty' <<<"$e")
    cmd=$(jq -r '.command // empty' <<<"$e")
    [[ "$live" == *" $name "* ]] && continue

    if [[ "$kind" == "claude" && -n "$sid" && "$seen_ids" == *" $sid "* ]]; then
      echo "  ! $name: conversation $sid is already being restored in another session -- skipped"
      echo "    (two live processes on one transcript corrupt it; resume it by hand if you really mean to)"
      skipped=$((skipped + 1)); continue
    fi
    [[ -d "$cwd" ]] || { echo "  ! $name: $cwd no longer exists, using \$HOME"; cwd=$HOME; }

    if (( dry )); then
      local what=${cmd:-shell}
      [[ -n "$sid" ]] && what="$CLAUDE_RESUME_CMD --resume $sid"
      echo "  would restore $name in $cwd: $what"
      [[ -n "$sid" ]] && seen_ids+="$sid "
      continue
    fi

    "${TMUX_CMD[@]}" new-session -d -s "$name" -c "$cwd"
    if [[ "$kind" == "claude" && -n "$sid" ]]; then
      # Typed into the pane's login shell so PATH and .bashrc apply, and
      # quitting claude leaves a shell behind, same as a hand-started session.
      "${TMUX_CMD[@]}" send-keys -t "$name" "$CLAUDE_RESUME_CMD --resume $sid" Enter
      seen_ids+="$sid "
      echo "  ✓ $name: resumed conversation $sid"
    elif [[ "$kind" == "claude" ]]; then
      echo "  ! $name: no conversation ID was recorded -- opened a shell; run 'claude --resume' to pick one"
    elif [[ -n "$cmd" && ! "$cmd" =~ ^(bash|sh|zsh|fish)$ ]]; then
      echo "  ! $name: was running '$cmd' -- opened a shell in $cwd; start it yourself"
    else
      echo "  ✓ $name: shell in $cwd"
    fi
    restored=$((restored + 1))
  done <<<"$entries"

  (( dry )) && return 0
  echo "Restored $restored session(s), skipped $skipped."
  # Record the restored sessions as seen in this boot right away, so closing
  # one before the next timer run counts as closing it on purpose.
  cmd_snapshot
}

cmd_forget() {
  [[ -n "${1:-}" ]] || die "usage: agent-sessions forget NAME"
  local new
  new=$(load_manifest | jq -c --arg n "$1" '.sessions |= map(select(.tmux != $n))')
  printf '%s\n' "$new" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
}

cmd_hint() {
  [[ -s "$MANIFEST" ]] || return 0
  local live n
  live=$(live_names | jq -R -s -c 'split("\n") | map(select(length > 0))')
  n=$(load_manifest | jq --argjson live "$live" --arg boot "$BOOT_ID"       '[.sessions[] | select(.boot != $boot) | select((.tmux | IN($live[])) | not)] | length' 2>/dev/null || echo 0)
  (( n > 0 )) && echo "agent-sessions: $n session(s) from before the last reboot are not running -- 'agent-sessions list' / 'agent-sessions restore'"
  return 0
}

case "${1:-}" in
  snapshot) cmd_snapshot ;;
  list)     cmd_list ;;
  restore)  shift; cmd_restore "$@" ;;
  forget)   shift; cmd_forget "$@" ;;
  hint)     cmd_hint ;;
  *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
AGENT_SESSIONS_EOF
chmod 0755 "$HOME/.local/bin/agent-sessions"

mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/agent-sessions-snapshot.service" <<'EOF'
[Unit]
Description=Record which agent conversation runs in which tmux session

[Service]
Type=oneshot
ExecStart=%h/.local/bin/agent-sessions snapshot
EOF
cat > "$HOME/.config/systemd/user/agent-sessions-snapshot.timer" <<'EOF'
[Unit]
Description=Snapshot tmux agent sessions every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
XDG_RUNTIME_DIR="/run/user/$_user_uid" \
DBUS_SESSION_BUS_ADDRESS="unix:path=$_user_bus" \
  systemctl --user daemon-reload
XDG_RUNTIME_DIR="/run/user/$_user_uid" \
DBUS_SESSION_BUS_ADDRESS="unix:path=$_user_bus" \
  systemctl --user enable --now agent-sessions-snapshot.timer > /dev/null
"$HOME/.local/bin/agent-sessions" snapshot \
  || warn "First agent-sessions snapshot failed -- run 'agent-sessions snapshot' to see why"

if ! grep -q 'agent-sessions hint' "$HOME/.bashrc" 2>/dev/null; then
  cat >> "$HOME/.bashrc" <<'EOF'

# After a reboot, say which tmux agent sessions are waiting to be restored
command -v agent-sessions > /dev/null && agent-sessions hint
EOF
fi
pass "agent-sessions: snapshot every 5 min (user timer, survives logout via linger)"

# ── d. Transcript retention ───────────────────────────────────────────────────

# DRIFT: managed settings file location and merge rules.  Verify before editing:
#   https://code.claude.com/docs/en/managed-settings
#   https://code.claude.com/docs/en/settings-reference#cleanupperioddays
# A drop-in under managed-settings.d/ leaves ~/.claude/settings.json (often a
# symlink into a personal config repo) untouched.  Managed values outrank user
# settings, so this is the floor for every user on this host.
# Last verified: 2026-10-12
sudo mkdir -p /etc/claude-code/managed-settings.d
echo "{ \"cleanupPeriodDays\": $CLAUDE_RETENTION_DAYS }" \
  | sudo tee /etc/claude-code/managed-settings.d/50-agent-host-retention.json > /dev/null
sudo chmod 0644 /etc/claude-code/managed-settings.d/50-agent-host-retention.json
pass "Claude Code transcript retention: ${CLAUDE_RETENTION_DAYS} days (managed setting)"

# ── Verify ────────────────────────────────────────────────────────────────────

# Check the live state, not just that the install commands returned 0.
section "9/9  Verify agent host"
_swap_kb=$(awk '/^SwapTotal:/ { print $2 }' /proc/meminfo)
if (( _swap_kb + _gib >= SWAP_TARGET_GB * _gib )); then
  pass "Swap active: $(( (_swap_kb + _gib / 2) / _gib )) GiB"
else
  warn "Swap is $(( _swap_kb / _gib )) GiB, below the ${SWAP_TARGET_GB} GiB target"
fi

if systemctl is-active --quiet agent-oom-priority.timer \
   && [[ "$(systemctl show -p Result --value agent-oom-priority.service)" == "success" ]]; then
  pass "agent-oom-priority.timer active, last run succeeded"
else
  warn "agent-oom-priority not healthy -- journalctl -u agent-oom-priority.service"
fi
_tmux_srv=$(pgrep -x 'tmux: server' | head -1 || true)
if [[ -n "$_tmux_srv" ]]; then
  _adj=$(cat "/proc/$_tmux_srv/oom_score_adj")
  if [[ "$_adj" == "-500" ]]; then
    pass "tmux server oom_score_adj = -500"
  else
    warn "tmux server oom_score_adj is $_adj, expected -500"
  fi
else
  note "No tmux server running -- OOM priority applies when one starts"
fi

if XDG_RUNTIME_DIR="/run/user/$_user_uid" systemctl --user is-active --quiet agent-sessions-snapshot.timer; then
  pass "agent-sessions-snapshot.timer active"
else
  warn "agent-sessions-snapshot.timer not active -- systemctl --user status agent-sessions-snapshot.timer"
fi
_manifest="$HOME/.local/state/agent-sessions/manifest.json"
if jq -e '.sessions | type == "array"' "$_manifest" > /dev/null 2>&1; then
  _n=$(jq '.sessions | length' "$_manifest")
  _no_id=$(jq '[.sessions[] | select(.kind == "claude" and (.sessionId // "") == "")] | length' "$_manifest")
  pass "agent-sessions recorded $_n tmux session(s)"
  (( _no_id == 0 )) || warn "$_no_id claude session(s) recorded without a conversation ID -- ~/.claude/sessions format may have changed (see docs/agent-host.md)"
else
  warn "agent-sessions manifest missing or invalid: $_manifest"
fi

if [[ "$(jq -r '.cleanupPeriodDays' /etc/claude-code/managed-settings.d/50-agent-host-retention.json 2>/dev/null)" == "$CLAUDE_RETENTION_DAYS" ]]; then
  pass "Managed retention file valid (${CLAUDE_RETENTION_DAYS} days)"
else
  warn "Managed retention file missing or not valid JSON"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  dev.sh complete${NC}"
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
echo -e "  ${GREEN}✓${NC} Agent host: swap target ${SWAP_TARGET_GB} GiB, OOM priority timer, agent-sessions, ${CLAUDE_RETENTION_DAYS}-day transcript retention"
echo ""
echo -e "  Log in as: ${BOLD}ssh $USER@$SERVER_IP${NC}"
echo -e "  ${YELLOW}Reload your shell${NC} (${DIM}exec \$SHELL -l${NC}) to activate nvm, DOCKER_HOST, and ~/.local/bin."
echo -e "  ${DIM}This script is idempotent — re-run anytime to refresh.${NC}"
echo ""
