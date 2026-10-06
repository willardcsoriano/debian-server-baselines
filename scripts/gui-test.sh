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
echo -e "${BOLD}gui-test.sh${NC}"
echo -e "${DIM}Debian 13 disposable GUI test box — run as your sudo user, after base.sh${NC}"
echo ""
echo -e "  ${YELLOW}This role is meant for a throwaway box you break things on, not a daily driver.${NC}"
echo -e "  ${YELLOW}See docs/HETZNER-CLOUD.md to snapshot before a destructive run and rebuild after.${NC}"
echo ""

[[ $EUID -eq 0 ]] && fail "Run as your sudo user, not root.  Try: bash scripts/gui-test.sh"

[[ -f /etc/os-release ]] || fail "Cannot detect OS."
# shellcheck source=/dev/null
. /etc/os-release
[[ "$ID" == "debian" ]]    || fail "Debian only. Detected: $ID"
[[ "$VERSION_ID" -ge 13 ]] || fail "Requires Debian 13+. Detected: $VERSION_ID"

SERVER_IP=$(hostname -I | awk '{print $1}')
pass "Debian $VERSION_ID ($VERSION_CODENAME) on $SERVER_IP"

groups | grep -qw sudo \
  || fail "$USER is not in the sudo group. Run base.sh first."
grep -q "^PermitRootLogin no" /etc/ssh/sshd_config 2>/dev/null \
  || fail "base.sh has not run on this host (PermitRootLogin still on)."
systemctl is-active --quiet ufw \
  || fail "base.sh has not run on this host (UFW not active)."

# vncpasswd needs an interactive tty, same reasoning as base.sh's username prompt:
# a password must never be something this script can read back out of a file or
# a piped stdin, so refuse to proceed if there's no real terminal to prompt on.
[[ -t 0 || -r /dev/tty ]] \
  || fail "No tty available — vncpasswd needs one. Run this from a real terminal, not a non-interactive pipe."

# Needed by the VNC systemd --user service below, same constraint dev.sh
# documents for rootless Docker's user daemon.
_user_uid=$(id -u)
_user_bus="/run/user/$_user_uid/bus"
[[ -S "$_user_bus" ]] \
  || fail "No user session at $_user_bus. Log in via SSH as $USER and re-run."

pass "Preflight OK — $USER, session confirmed"
echo ""

# ─── 1/7  Desktop environment ────────────────────────────────────────────────

section "1/7  Desktop environment (XFCE)"

sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  xorg xfce4 xfce4-goodies xfce4-terminal dbus-x11 \
  fonts-liberation fonts-noto xfce4-taskmanager
pass "XFCE desktop, terminal, and fonts installed"

# ─── 2/7  Browsers ────────────────────────────────────────────────────────────

section "2/7  Browsers (Firefox, Chromium)"

sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq firefox-esr chromium
pass "Firefox ESR and Chromium installed"

# ─── 3/7  Remote desktop access (VNC, localhost-only) ────────────────────────

section "3/7  Remote desktop access (TigerVNC, SSH-tunnel only)"

# DRIFT: Debian's own tigervnc-standalone-server ships a packaged systemd
# template (name/scope has varied across guides — some document a root-level
# tigervncserver@:N.service driven by /etc/tigervnc/vncserver.users, others a
# per-user vncserver@N.service), and the manpage itself doesn't pin it down.
# Rather than depend on a name that can differ by package version, this
# defines its own systemd --user unit (same pattern dev.sh uses for rootless
# Docker's user daemon below) — no guessing required, and it's ours to debug.
# Last verified: 2026-10-06 (xstartup path, -localhost flag confirmed against
# the Debian trixie tigervnc-standalone-server(1) manpage).

sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  tigervnc-standalone-server tigervnc-common

mkdir -p "$HOME/.config/tigervnc"
XSTARTUP="$HOME/.config/tigervnc/xstartup"
if [[ ! -f "$XSTARTUP" ]]; then
  cat > "$XSTARTUP" <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
vncconfig -nowin &
exec startxfce4
EOF
  chmod +x "$XSTARTUP"
  pass "xstartup written — VNC sessions launch XFCE"
else
  pass "xstartup already present"
fi

# A VNC password must exist before the service can start, and it's exactly the
# kind of thing that must never end up in a script-written file — vncpasswd
# owns writing its own (obfuscated) password file, this script never touches it.
if [[ -f "$HOME/.vnc/passwd" || -f "$HOME/.config/tigervnc/passwd" ]]; then
  pass "VNC password already set"
else
  echo -e "  ${DIM}Set a VNC password (separate from your login password):${NC}"
  vncpasswd </dev/tty
  pass "VNC password set"
fi

VNC_UNIT="$HOME/.config/systemd/user/vncserver.service"
mkdir -p "$(dirname "$VNC_UNIT")"
if [[ ! -f "$VNC_UNIT" ]]; then
  cat > "$VNC_UNIT" <<'EOF'
[Unit]
Description=TigerVNC server (display :1, localhost only)

[Service]
Type=forking
ExecStartPre=-/usr/bin/vncserver -kill :1
ExecStart=/usr/bin/vncserver :1 -localhost yes -geometry 1920x1080 -depth 24
ExecStop=/usr/bin/vncserver -kill :1
Restart=on-failure

[Install]
WantedBy=default.target
EOF
  pass "VNC systemd --user unit written (display :1, bound to 127.0.0.1 only)"
else
  pass "VNC systemd --user unit already present"
fi

XDG_RUNTIME_DIR="/run/user/$_user_uid" \
DBUS_SESSION_BUS_ADDRESS="unix:path=$_user_bus" \
systemctl --user daemon-reload
XDG_RUNTIME_DIR="/run/user/$_user_uid" \
DBUS_SESSION_BUS_ADDRESS="unix:path=$_user_bus" \
systemctl --user enable --now vncserver.service \
  || warn "Could not start vncserver.service — run 'systemctl --user status vncserver.service' to see why"
sudo loginctl enable-linger "$USER"

pass "VNC listening on 127.0.0.1:5901 only — never opened in UFW, reached only via SSH tunnel"

# ─── 4/7  Go toolchain ────────────────────────────────────────────────────────

section "4/7  Go toolchain"

# Matches prototype/go.mod's `go 1.25.0` in the thesis repo. Resolved against
# go.dev's own release JSON at run time rather than a version pinned here, so
# this script doesn't go stale every time Go ships a patch release.
GO_LINE="1.25"

if command -v go &>/dev/null && go version 2>/dev/null | grep -q "go${GO_LINE}\."; then
  pass "Go already installed ($(go version))"
else
  command -v jq &>/dev/null || sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq

  _go_rel=$(curl -fsSL "https://go.dev/dl/?mode=json" \
    | jq -r "[.[] | select(.stable==true) | select(.version | startswith(\"go${GO_LINE}.\"))][0]")
  [[ "$_go_rel" != "null" && -n "$_go_rel" ]] || fail "Could not find a stable go${GO_LINE}.x release from go.dev/dl"

  _go_filename=$(echo "$_go_rel" | jq -r '.files[] | select(.os=="linux" and .arch=="amd64" and .kind=="archive") | .filename')
  _go_sha256=$(echo "$_go_rel" | jq -r '.files[] | select(.os=="linux" and .arch=="amd64" and .kind=="archive") | .sha256')
  [[ -n "$_go_filename" ]] || fail "No linux-amd64 archive found for the resolved Go release"

  _tmp=$(mktemp -d)
  curl -fsSL -o "$_tmp/$_go_filename" "https://go.dev/dl/$_go_filename"
  echo "${_go_sha256}  $_tmp/$_go_filename" | sha256sum -c - \
    || fail "Go tarball checksum mismatch for $_go_filename"

  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf "$_tmp/$_go_filename"
  rm -rf "$_tmp"

  if [[ ! -f /etc/profile.d/go.sh ]]; then
    echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee /etc/profile.d/go.sh > /dev/null
  fi
  export PATH="$PATH:/usr/local/go/bin"
  pass "Go installed ($(go version))"
fi

# ─── 5/7  Ollama + qwen2.5-coder:3b ───────────────────────────────────────────

section "5/7  Ollama + qwen2.5-coder:3b"

# DRIFT: official install path. Verify before editing: https://ollama.com/download/linux
# Last verified: 2026-10-06

if command -v ollama &>/dev/null; then
  pass "Ollama already installed"
else
  curl -fsSL https://ollama.com/install.sh | sh
  pass "Ollama installed"
fi

sudo systemctl enable --now ollama >/dev/null 2>&1 || true

if ollama list 2>/dev/null | grep -q "qwen2.5-coder:3b"; then
  pass "qwen2.5-coder:3b already pulled"
else
  ollama pull qwen2.5-coder:3b
  pass "qwen2.5-coder:3b pulled"
fi

# ─── 6/7  Testing prerequisites ──────────────────────────────────────────────

section "6/7  Testing prerequisites"

# bubblewrap: the sandbox the thesis's effect-analysis resolvers run under
# (prototype/internal/effects) — see /home/willard/projects/thesis/CLAUDE.md.
# build-essential: Go's cgo and anything the pilot/corpus tooling needs to compile.
# git is already installed by base.sh's operator tooling.
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq bubblewrap build-essential
pass "bubblewrap and build-essential installed"

# ─── 7/7  Verify ──────────────────────────────────────────────────────────────

section "7/7  Verify"

XDG_RUNTIME_DIR="/run/user/$_user_uid" \
DBUS_SESSION_BUS_ADDRESS="unix:path=$_user_bus" \
systemctl --user is-active --quiet vncserver.service \
  && pass "vncserver.service is active" \
  || warn "vncserver.service is not active — check 'systemctl --user status vncserver.service'"

bwrap --version >/dev/null 2>&1 && pass "bubblewrap runs" || warn "bubblewrap did not run cleanly"

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  gui-test.sh complete${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${GREEN}✓${NC} XFCE desktop + Firefox ESR + Chromium"
echo -e "  ${GREEN}✓${NC} VNC on 127.0.0.1:5901 — never opened in UFW, SSH-tunnel only"
echo -e "  ${GREEN}✓${NC} Go: $(go version 2>/dev/null || echo 'see /usr/local/go/bin/go version')"
echo -e "  ${GREEN}✓${NC} Ollama + qwen2.5-coder:3b"
echo -e "  ${GREEN}✓${NC} bubblewrap + build-essential"
echo ""
echo -e "  From your local machine, tunnel then connect a VNC viewer:"
echo -e "    ${BOLD}ssh -N -L 5901:localhost:5901 $USER@$SERVER_IP${NC}"
echo -e "    then point a VNC client at ${BOLD}localhost:5901${NC}"
echo ""
echo -e "  Clone the thesis repo yourself with your own git credentials — this"
echo -e "  script never handles anything that needs your private key or a token:"
echo -e "    ${BOLD}git clone <your-remote> ~/thesis${NC}"
echo ""
echo -e "  ${YELLOW}This box is disposable by design.${NC} Before a destructive test round:"
echo -e "    ${BOLD}hcloud server create-image $(hostname) --type snapshot --description \"pre-test \$(date +%F)\"${NC}"
echo -e "  To reset back to that snapshot after breaking something:"
echo -e "    ${BOLD}hcloud server rebuild --image <snapshot-id> $(hostname)${NC}"
echo -e "  ${DIM}See docs/HETZNER-CLOUD.md for the full snapshot/rebuild workflow.${NC}"
echo ""
echo -e "  ${DIM}This script is idempotent — re-run anytime to refresh.${NC}"
echo ""
