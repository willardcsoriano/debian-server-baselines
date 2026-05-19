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
echo -e "${BOLD}syslog-baseline${NC}"
echo -e "${DIM}Debian 13 syslog receiver — run as root, after debian-baseline${NC}"
echo ""

[[ $EUID -ne 0 ]] && fail "Must run as root (or via sudo)."
[[ -f /etc/os-release ]] || fail "Cannot detect OS."
# shellcheck source=/dev/null
. /etc/os-release
[[ "$ID" == "debian" ]]    || fail "Debian only. Detected: $ID"
[[ "$VERSION_ID" -ge 13 ]] || fail "Requires Debian 13+. Detected: $VERSION_ID"

SERVER_IP=$(hostname -I | awk '{print $1}')
pass "Debian $VERSION_ID ($VERSION_CODENAME) on $SERVER_IP"

# Confirm baseline.sh has run
grep -q "^PermitRootLogin no" /etc/ssh/sshd_config 2>/dev/null \
  || fail "debian-baseline.sh has not run on this host (PermitRootLogin still on)."
systemctl is-active --quiet ufw \
  || fail "debian-baseline.sh has not run on this host (UFW not active)."

# rsyslog ships with Debian and baseline.sh does not remove it, but
# confirm it is present before modifying its config.
command -v rsyslogd &>/dev/null \
  || fail "rsyslogd not found — install rsyslog and re-run."

pass "Preflight OK"
echo ""

# ─── 1/3  rsyslog receiver ────────────────────────────────────────────────────

section "1/3  rsyslog receiver (TCP 514)"

mkdir -p /var/log/remote
chown syslog:adm /var/log/remote
chmod 750 /var/log/remote

cat > /etc/rsyslog.d/50-receiver.conf <<'EOF'
# Managed by syslog-baseline — receives remote syslog over TCP port 514.

module(load="imtcp")

# Dedicated ruleset for incoming TCP connections — keeps remote messages
# out of local log processing.  SecurePath="replace" substitutes path-
# traversal characters in hostnames and programnames sent by remote hosts,
# so a hostile sender cannot write outside /var/log/remote/.
ruleset(name="remote-tcp") {
  template(name="RemoteHostLog" type="list") {
    constant(value="/var/log/remote/")
    property(name="hostname"    SecurePath="replace")
    constant(value="/")
    property(name="programname" SecurePath="replace")
    constant(value=".log")
  }
  action(
    type="omfile"
    DynaFile="RemoteHostLog"
    FileCreateMode="0640"
    DirCreateMode="0750"
    FileOwner="syslog"
    FileGroup="adm"
  )
}

input(type="imtcp" port="514" ruleset="remote-tcp")
EOF

rsyslogd -N1 || fail "rsyslog config invalid — fix /etc/rsyslog.d/50-receiver.conf"
systemctl restart rsyslog
pass "rsyslog receiving on TCP 514 — /var/log/remote/<hostname>/<program>.log"

# ─── 2/3  Firewall ────────────────────────────────────────────────────────────

section "2/3  Firewall (UFW 514/tcp)"

# baseline.sh's sender side (section 20) forwards over TCP (@@).  Only TCP
# is opened here — UDP syslog is fire-and-forget with no delivery guarantee.
ufw allow 514/tcp > /dev/null
pass "UFW: 514/tcp open"

# ─── 3/3  Log rotation ────────────────────────────────────────────────────────

section "3/3  Log rotation"

cat > /etc/logrotate.d/remote-syslog <<'EOF'
# Managed by syslog-baseline.
/var/log/remote/*/*.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        systemctl reload rsyslog 2>/dev/null || true
    endscript
}
EOF

pass "logrotate: weekly rotation, 12-week retention, compressed"

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  syslog-baseline complete${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${GREEN}✓${NC} rsyslog: receiving on TCP 514"
echo -e "  ${GREEN}✓${NC} Logs: /var/log/remote/<hostname>/<program>.log"
echo -e "  ${GREEN}✓${NC} UFW: 514/tcp open"
echo -e "  ${GREEN}✓${NC} logrotate: weekly, 12-week retention, compressed"
echo ""
echo -e "  Point senders at: ${BOLD}$SERVER_IP:514${NC}"
echo -e "  On each sender, answer the remote syslog prompt in debian-baseline.sh"
echo -e "  or set it manually in /etc/rsyslog.d/50-remote-syslog.conf."
echo -e "  ${DIM}This script is idempotent — re-run anytime to refresh.${NC}"
echo ""
