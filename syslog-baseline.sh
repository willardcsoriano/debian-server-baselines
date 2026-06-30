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
echo -e "${DIM}Debian 13 syslog receiver — run as root, after base-server${NC}"
echo ""

[[ $EUID -ne 0 ]] && fail "Must run as root (or via sudo)."
[[ -f /etc/os-release ]] || fail "Cannot detect OS."
# shellcheck source=/dev/null
. /etc/os-release
[[ "$ID" == "debian" ]]    || fail "Debian only. Detected: $ID"
[[ "$VERSION_ID" -ge 13 ]] || fail "Requires Debian 13+. Detected: $VERSION_ID"

SERVER_IP=$(hostname -I | awk '{print $1}')
pass "Debian $VERSION_ID ($VERSION_CODENAME) on $SERVER_IP"

# Confirm base-server.sh has run
grep -q "^PermitRootLogin no" /etc/ssh/sshd_config 2>/dev/null \
  || fail "base-server.sh has not run on this host (PermitRootLogin still on)."
systemctl is-active --quiet ufw \
  || fail "base-server.sh has not run on this host (UFW not active)."

# rsyslog ships with Debian and base-server.sh does not remove it, but
# confirm it is present before modifying its config.
command -v rsyslogd &>/dev/null \
  || fail "rsyslogd not found — install rsyslog and re-run."

RERUN=0
if [[ -f /etc/rsyslog.d/50-receiver.conf ]]; then
  RERUN=1
  note "Re-run detected — config will be refreshed"
fi

pass "Preflight OK"
echo ""

# ─── Sender CIDR ──────────────────────────────────────────────────────────────

# SYSLOG_ALLOW_FROM can be set in the environment to skip the prompt, which is
# useful when running via curl | bash with a WireGuard or private-network CIDR:
#   SYSLOG_ALLOW_FROM=10.20.0.0/24 sudo bash syslog-baseline.sh
if [[ -z "${SYSLOG_ALLOW_FROM:-}" ]]; then
  [[ -t 0 || -r /dev/tty ]] || fail "No tty — set SYSLOG_ALLOW_FROM=<cidr> in the environment or run interactively."
  read -rp "  Restrict 514/tcp to CIDR (e.g. 10.20.0.0/24, blank = allow all): " SYSLOG_ALLOW_FROM </dev/tty
  SYSLOG_ALLOW_FROM="${SYSLOG_ALLOW_FROM// /}"
fi
if [[ -z "$SYSLOG_ALLOW_FROM" ]]; then
  warn "No CIDR — 514/tcp will be open to all sources (not recommended on a public IP)"
else
  note "514/tcp restricted to $SYSLOG_ALLOW_FROM"
fi
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

# KeepAlive detects dead TCP connections from senders that crashed or rebooted
# without sending FIN, so rsyslog reaps the half-open socket rather than waiting
# indefinitely.
input(type="imtcp" port="514" ruleset="remote-tcp" KeepAlive="on")
EOF

rsyslogd -N1 || fail "rsyslog config invalid — fix /etc/rsyslog.d/50-receiver.conf"
systemctl restart rsyslog
pass "rsyslog receiving on TCP 514 — /var/log/remote/<hostname>/<program>.log"

# ─── 2/3  Firewall ────────────────────────────────────────────────────────────

section "2/3  Firewall (UFW 514/tcp)"

# sender side (base-server.sh section 20) forwards over TCP (@@).
# Only TCP is opened here — UDP syslog is fire-and-forget with no delivery guarantee.
if [[ -n "$SYSLOG_ALLOW_FROM" ]]; then
  ufw allow from "$SYSLOG_ALLOW_FROM" to any port 514 proto tcp > /dev/null
  pass "UFW: 514/tcp open from $SYSLOG_ALLOW_FROM only"
else
  ufw allow 514/tcp > /dev/null
  pass "UFW: 514/tcp open (all sources)"
fi

# ─── 3/3  Log rotation ────────────────────────────────────────────────────────

section "3/3  Log rotation"

cat > /etc/logrotate.d/remote-syslog <<'EOF'
# Managed by syslog-baseline.
/var/log/remote/*/*.log {
    weekly
    rotate 12
    maxsize 500M
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

pass "logrotate: weekly rotation, 12-week retention, 500M maxsize, compressed"

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  syslog-baseline complete${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${GREEN}✓${NC} rsyslog: receiving on TCP 514"
echo -e "  ${GREEN}✓${NC} Logs: /var/log/remote/<hostname>/<program>.log"
if [[ -n "$SYSLOG_ALLOW_FROM" ]]; then
  echo -e "  ${GREEN}✓${NC} UFW: 514/tcp open from ${BOLD}$SYSLOG_ALLOW_FROM${NC} only"
else
  echo -e "  ${YELLOW}⚠${NC} UFW: 514/tcp open to all sources"
fi
echo -e "  ${GREEN}✓${NC} logrotate: weekly, 12-week retention, 500M maxsize, compressed"
echo ""
echo -e "  Point senders at: ${BOLD}$SERVER_IP:514${NC}"
echo -e "  ${DIM}(If using WireGuard, use this host's WireGuard IP instead of the above.)${NC}"
echo -e "  On each sender, answer the remote syslog prompt in base-server.sh"
echo -e "  or set it manually in /etc/rsyslog.d/50-remote-syslog.conf."
echo -e "  ${DIM}This script is idempotent — re-run anytime to refresh.${NC}"
echo ""
