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
echo -e "${BOLD}debian-dev-baseline${NC}"
echo -e "${DIM}Debian 13 developer tooling — run after debian-baseline${NC}"
echo ""

[[ $EUID -ne 0 ]]          && fail "Must run as root (or via sudo)."
[[ -f /etc/os-release ]]   || fail "Cannot detect OS."
# shellcheck source=/dev/null
. /etc/os-release
[[ "$ID" == "debian" ]]    || fail "Debian only. Detected: $ID"
[[ "$VERSION_ID" -ge 13 ]] || fail "Requires Debian 13+. Detected: $VERSION_ID"

SERVER_IP=$(hostname -I | awk '{print $1}')
pass "Debian $VERSION_ID ($VERSION_CODENAME) on $SERVER_IP"

echo ""
[[ -t 0 || -r /dev/tty ]] || fail "No tty available — this script requires interactive input."
EXISTING_SUDO=$(getent group sudo | cut -d: -f4 | tr ',' '\n' | grep -v '^$' | grep -v '^root$' | head -1 || true)
if [[ -n "$EXISTING_SUDO" ]]; then
  read -rp "  Sudo username [$EXISTING_SUDO]: " NEW_USER </dev/tty
  NEW_USER="${NEW_USER:-$EXISTING_SUDO}"
else
  read -rp "  Sudo username: " NEW_USER </dev/tty
fi
echo ""

[[ -z "$NEW_USER" ]]                        && fail "Username cannot be empty."
[[ "$NEW_USER" == "root" ]]                 && fail "Cannot use 'root'."
[[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]   || fail "Invalid username. Lowercase, numbers, hyphens only."
id "$NEW_USER" &>/dev/null                  || fail "User $NEW_USER does not exist. Run debian-baseline first."

USER_HOME="/home/$NEW_USER"

# ─── 1/1  Docker rootless ─────────────────────────────────────────────────────

section "1/1  Docker (rootless)"

# Rootless Docker needs an active user session for $NEW_USER so we can run
# 'systemctl --user' against it. The DBus session bus socket at
# /run/user/<uid>/bus exists when the user has either an active login OR
# linger enabled from a prior run. If neither, pause and ask the user to log in.
_user_uid=$(id -u "$NEW_USER")
_user_bus="/run/user/$_user_uid/bus"
if [[ ! -S "$_user_bus" ]]; then
  echo ""
  echo -e "  ${YELLOW}Rootless Docker needs an active session for $NEW_USER.${NC}"
  echo ""
  echo -e "  Open a new terminal and run:"
  echo -e "  ${BOLD}    ssh $NEW_USER@$SERVER_IP${NC}"
  echo ""
  echo -e "  ${DIM}  If that fails with 'Permission denied (publickey)', your SSH client may${NC}"
  echo -e "  ${DIM}  not be loading the right key. Try your SSH alias for this host instead,${NC}"
  echo -e "  ${DIM}  or add -i /path/to/your/private/key to the command above.${NC}"
  echo ""
  echo -e "  Keep that session open, then press ${BOLD}Enter${NC} here to continue..."
  read -r </dev/tty
  if [[ ! -S "$_user_bus" ]]; then
    echo ""
    note "SSH diagnostics:"
    note "  AllowUsers in sshd_config: $(grep -i '^AllowUsers' /etc/ssh/sshd_config || echo '(not set)')"
    note "  $NEW_USER in sudo group:   $(getent group sudo | grep -ow "$NEW_USER" || echo 'NO')"
    note "  authorized_keys:           $(ls -la "$USER_HOME/.ssh/authorized_keys" 2>/dev/null || echo 'MISSING')"
    note "  home dir permissions:      $(stat -c '%A %U:%G' "$USER_HOME" 2>/dev/null)"
    fail "No user session at $_user_bus. Fix SSH access for $NEW_USER (see diagnostics above), then re-run."
  fi
  pass "User session detected for $NEW_USER"
fi

mkdir -p /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
fi
if [[ ! -f /etc/apt/sources.list.d/docker.sources ]]; then
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update -qq
fi
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin \
  docker-ce-rootless-extras uidmap

# Disable the system-mode daemon — rootless replaces it
systemctl disable --now docker.service docker.socket 2>/dev/null || true

# Rootless Docker requires /etc/subuid and /etc/subgid entries (65536 UIDs).
# adduser creates these automatically, but pre-existing users (e.g. from a
# VPS image) may be missing them. Ensure they exist before running setup.
if ! grep -q "^$NEW_USER:" /etc/subuid 2>/dev/null; then
  usermod --add-subuids 100000-165535 "$NEW_USER"
  note "Added subuid range for $NEW_USER"
fi
if ! grep -q "^$NEW_USER:" /etc/subgid 2>/dev/null; then
  usermod --add-subgids 100000-165535 "$NEW_USER"
  note "Added subgid range for $NEW_USER"
fi

# Set up rootless daemon as $NEW_USER if not already configured.
# Check for the systemd user service, not just the binary — the binary
# gets created even when setup runs without systemd (missing XDG_RUNTIME_DIR),
# so a partial install would otherwise be silently skipped on re-run.
_user_home=$(getent passwd "$NEW_USER" | cut -d: -f6)
_docker_svc="$_user_home/.config/systemd/user/docker.service"
if [[ ! -f "$_docker_svc" ]]; then
  su - "$NEW_USER" -c "XDG_RUNTIME_DIR=/run/user/$_user_uid DBUS_SESSION_BUS_ADDRESS=unix:path=$_user_bus dockerd-rootless-setuptool.sh install" || \
    warn "Rootless setup failed — run 'dockerd-rootless-setuptool.sh install' as $NEW_USER manually"
fi

# Enable the user daemon and linger so it survives logout
su - "$NEW_USER" -c "XDG_RUNTIME_DIR=/run/user/$_user_uid DBUS_SESSION_BUS_ADDRESS=unix:path=$_user_bus systemctl --user enable --now docker" \
  || warn "Could not enable docker user service — start it manually as $NEW_USER"
loginctl enable-linger "$NEW_USER"

# Persist DOCKER_HOST in the user's shell if not already set
_bashrc="$_user_home/.bashrc"
if ! grep -q 'DOCKER_HOST' "$_bashrc" 2>/dev/null; then
  cat >> "$_bashrc" <<'EOF'

# rootless Docker
export PATH=/usr/bin:$PATH
export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock
EOF
fi

pass "Docker (rootless) installed; user daemon enabled; linger on"

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  debian-dev complete${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${GREEN}✓${NC} Docker: rootless, system daemon disabled, $NEW_USER daemon enabled"
echo ""
echo -e "  Log in as: ${BOLD}ssh $NEW_USER@$SERVER_IP${NC}"
echo -e "  ${DIM}This script is idempotent — re-run anytime to refresh.${NC}"
echo ""
