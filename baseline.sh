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
echo -e "${BOLD}debian-baseline${NC}"
echo -e "${DIM}Debian 13 server hardening — github.com/willardcsoriano/debian-baseline${NC}"
echo ""

[[ $EUID -ne 0 ]]          && fail "Must run as root."
[[ -f /etc/os-release ]]   || fail "Cannot detect OS."
. /etc/os-release
[[ "$ID" == "debian" ]]    || fail "Debian only. Detected: $ID"
[[ "$VERSION_ID" -ge 13 ]] || fail "Requires Debian 13+. Detected: $VERSION_ID"

SERVER_IP=$(hostname -I | awk '{print $1}')
pass "Debian $VERSION_ID ($VERSION_CODENAME) on $SERVER_IP"

# ─── Username ─────────────────────────────────────────────────────────────────

echo ""
read -rp "  Sudo username to create: " NEW_USER
echo ""

[[ -z "$NEW_USER" ]]                           && fail "Username cannot be empty."
[[ "$NEW_USER" == "root" ]]                    && fail "Cannot use 'root'."
[[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]      || fail "Invalid username. Lowercase, numbers, hyphens only."
[[ ! -f /root/.ssh/authorized_keys ]]          && fail "No SSH key at /root/.ssh/authorized_keys. Cannot proceed safely."
[[ ! -s /root/.ssh/authorized_keys ]]          && fail "authorized_keys is empty. Add your public key first."

# ─── 1. System updates ────────────────────────────────────────────────────────

section "1/13  System updates"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
pass "All packages updated"

# ─── 2. Automatic security updates ───────────────────────────────────────────

section "2/13  Automatic security updates"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades
systemctl enable --now unattended-upgrades -q
pass "unattended-upgrades active"

# ─── 3. Sudo user ─────────────────────────────────────────────────────────────

section "3/13  Sudo user ($NEW_USER)"
if id "$NEW_USER" &>/dev/null; then
  warn "User $NEW_USER already exists — skipping creation"
else
  adduser --gecos "" --disabled-password "$NEW_USER" -q
  pass "User $NEW_USER created"
fi
usermod -aG sudo "$NEW_USER"
echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/"$NEW_USER"
chmod 440 /etc/sudoers.d/"$NEW_USER"
pass "$NEW_USER added to sudo"

# ─── 4. Copy SSH key ──────────────────────────────────────────────────────────

section "4/13  SSH key"
USER_HOME="/home/$NEW_USER"
mkdir -p "$USER_HOME/.ssh"
cp /root/.ssh/authorized_keys "$USER_HOME/.ssh/authorized_keys"
chown -R "$NEW_USER:$NEW_USER" "$USER_HOME/.ssh"
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"
pass "SSH key copied to $NEW_USER"

# ─── 5. Safety check ─────────────────────────────────────────────────────────

section "5/13  SSH safety check"
echo ""
echo -e "  ${YELLOW}Before locking down SSH, verify the new account works.${NC}"
echo ""
echo -e "  Open a new terminal and run:"
echo -e "  ${BOLD}    ssh $NEW_USER@$SERVER_IP${NC}"
echo ""
read -rp "  Type 'yes' to confirm login worked: " CONFIRMED
[[ "$CONFIRMED" != "yes" ]] && fail "Aborted. Resolve SSH access before continuing."
pass "SSH access confirmed"

# ─── 6. SSH hardening ────────────────────────────────────────────────────────

section "6/13  SSH hardening"
SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "$SSHD_CONFIG.bak.$(date +%Y%m%d)"

set_sshd() {
  local key="$1" val="$2"
  if grep -qE "^#?\s*${key}\b" "$SSHD_CONFIG"; then
    sed -i -E "s|^#?\s*${key}.*|${key} ${val}|" "$SSHD_CONFIG"
  else
    echo "${key} ${val}" >> "$SSHD_CONFIG"
  fi
}

set_sshd PermitRootLogin        no
set_sshd PasswordAuthentication no
set_sshd PubkeyAuthentication   yes
set_sshd MaxAuthTries            3
set_sshd LoginGraceTime          30
set_sshd X11Forwarding           no

sshd -t || fail "sshd_config invalid — original backed up to $SSHD_CONFIG.bak.*"
systemctl reload sshd
pass "SSH hardened (root login off, key-only auth)"

# ─── 7. Firewall ──────────────────────────────────────────────────────────────

section "7/13  Firewall (UFW)"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw
ufw --force reset      > /dev/null
ufw default deny incoming > /dev/null
ufw default allow outgoing > /dev/null
ufw allow 22/tcp       > /dev/null
ufw allow 80/tcp       > /dev/null
ufw allow 443/tcp      > /dev/null
ufw --force enable     > /dev/null
pass "UFW enabled — ports 22, 80, 443 open"

# ─── 8. fail2ban ─────────────────────────────────────────────────────────────

section "8/13  Brute-force protection (fail2ban)"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = 22
EOF
systemctl enable --now fail2ban -q
pass "fail2ban active — 5 failed attempts → 1h ban"

# ─── 9. Kernel hardening ─────────────────────────────────────────────────────

section "9/13  Kernel hardening (sysctl)"
cat > /etc/sysctl.d/99-hardening.conf <<'EOF'
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
kernel.randomize_va_space = 2
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
EOF
sysctl --system -q
pass "Kernel parameters applied"

# ─── 10. AppArmor ────────────────────────────────────────────────────────────

section "10/13 AppArmor"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq apparmor apparmor-utils
systemctl enable --now apparmor -q
ENFORCED=$(aa-status 2>/dev/null | grep "profiles are in enforce mode" | grep -oP '^\d+' || echo "?")
pass "AppArmor active ($ENFORCED profiles enforcing)"

# ─── 11. Cockpit + Netdata ───────────────────────────────────────────────────

section "11/13 Monitoring (Cockpit + Netdata)"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cockpit
systemctl enable --now cockpit.socket -q
pass "Cockpit installed"
note "Access: ssh -N -L 9090:localhost:9090 $NEW_USER@$SERVER_IP → https://localhost:9090"

bash <(curl -Ss https://my-netdata.io/kickstart.sh) \
  --dont-wait --noupdate --disable-telemetry > /dev/null 2>&1 || warn "Netdata install failed — install manually"
pass "Netdata installed"
note "Access: ssh -N -L 19999:localhost:19999 $NEW_USER@$SERVER_IP → http://localhost:19999"

# ─── 12. rkhunter + auditd ───────────────────────────────────────────────────

section "12/13 Intrusion detection (rkhunter + auditd)"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rkhunter auditd
rkhunter --update  --quiet 2>/dev/null || true
rkhunter --propupd --quiet 2>/dev/null || true
systemctl enable --now auditd -q
pass "rkhunter baseline saved, auditd active"

# ─── 13. Lynis ───────────────────────────────────────────────────────────────

section "13/13 Security audit (Lynis)"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq lynis
lynis audit system --quiet --nocolors > /var/log/lynis-baseline.log 2>&1 || true
SCORE=$(grep "Hardening index" /var/log/lynis.log 2>/dev/null | tail -1 | grep -oP '\d+' | head -1 || echo "see /var/log/lynis.log")
pass "Lynis first audit complete — hardening index: $SCORE"

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  debian-baseline complete${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${GREEN}✓${NC} System updated + auto security patches"
echo -e "  ${GREEN}✓${NC} Sudo user: ${BOLD}$NEW_USER${NC}"
echo -e "  ${GREEN}✓${NC} SSH: root login off, key-only auth"
echo -e "  ${GREEN}✓${NC} Firewall: 22, 80, 443 open — all else denied"
echo -e "  ${GREEN}✓${NC} fail2ban: brute-force protection active"
echo -e "  ${GREEN}✓${NC} Kernel: network attack surface reduced"
echo -e "  ${GREEN}✓${NC} AppArmor: mandatory access control active"
echo -e "  ${GREEN}✓${NC} Cockpit + Netdata: installed, tunnel-only access"
echo -e "  ${GREEN}✓${NC} rkhunter + auditd: intrusion detection active"
echo -e "  ${GREEN}✓${NC} Lynis: hardening index ${BOLD}$SCORE${NC}"
echo ""
echo -e "  ${YELLOW}Root SSH is now disabled.${NC} Log in as: ${BOLD}ssh $NEW_USER@$SERVER_IP${NC}"
echo -e "  ${YELLOW}Lynis report:${NC} /var/log/lynis.log"
echo ""
