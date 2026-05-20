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
echo -e "${BOLD}debian-remote-syslog${NC}"
echo -e "${DIM}Forward security logs to a remote syslog server — run as root, after debian-server-baseline${NC}"
echo ""

[[ $EUID -ne 0 ]]          && fail "Must run as root (or via sudo)."
[[ -f /etc/os-release ]]   || fail "Cannot detect OS."
# shellcheck source=/dev/null
. /etc/os-release
[[ "$ID" == "debian" ]]    || fail "Debian only. Detected: $ID"
[[ "$VERSION_ID" -ge 13 ]] || fail "Requires Debian 13+. Detected: $VERSION_ID"

# Confirm debian-server-baseline.sh has run — we depend on auditd from section 12 and on
# rsyslog/SSH hardening being in place.  Mirrors dev-server.sh's check.
grep -q "^PermitRootLogin no" /etc/ssh/sshd_config 2>/dev/null \
  || fail "debian-server-baseline.sh has not run on this host (PermitRootLogin still on)."
command -v rsyslogd &>/dev/null \
  || fail "rsyslog is not installed (expected on a debian-server-baseline host)."
[[ -d /etc/audit/plugins.d ]] \
  || fail "auditd plugins dir missing — run debian-server-baseline.sh first."

SERVER_IP=$(hostname -I | awk '{print $1}')
pass "Debian $VERSION_ID ($VERSION_CODENAME) on $SERVER_IP"

# Re-run detection: prior config file present means we've been here before
RERUN=0
EXISTING_SERVER=""
if [[ -f /etc/rsyslog.d/50-remote-syslog.conf ]]; then
  RERUN=1
  EXISTING_SERVER=$(grep -oP '@@\K[^:]+' /etc/rsyslog.d/50-remote-syslog.conf | head -1 || true)
  note "Re-run detected — existing forward target: ${EXISTING_SERVER:-unknown}"
fi

# ─── Log server ───────────────────────────────────────────────────────────────

echo ""
[[ -t 0 || -r /dev/tty ]] || fail "No tty available — this script requires interactive input."
if [[ -n "$EXISTING_SERVER" ]]; then
  read -rp "  Remote syslog server IP/hostname [$EXISTING_SERVER]: " LOG_SERVER </dev/tty
  LOG_SERVER="${LOG_SERVER:-$EXISTING_SERVER}"
else
  read -rp "  Remote syslog server IP/hostname: " LOG_SERVER </dev/tty
fi
LOG_SERVER="${LOG_SERVER// /}"
[[ -z "$LOG_SERVER" ]] && fail "Server cannot be empty. To remove forwarding, delete /etc/rsyslog.d/50-remote-syslog.conf and restart rsyslog."
echo ""

# ─── 1/1  Forward security logs via TCP ──────────────────────────────────────

section "1/1  Remote syslog forwarding → $LOG_SERVER:514 (TCP)"

# Enable auditd syslog plugin so audit events flow through rsyslog (local6).
cat > /etc/audit/plugins.d/syslog.conf <<'EOF'
active = yes
direction = out
path = builtin_syslog
type = builtin
args = LOG_INFO
format = string
EOF

# Forward security-relevant facilities via TCP (@@) to the log server.
# local6 captures auditd events once the syslog plugin above is active.
cat > /etc/rsyslog.d/50-remote-syslog.conf <<EOF
# Managed by debian-server-baseline/remote-syslog.sh — forward security logs.
auth,authpriv.*   @@${LOG_SERVER}:514
kern.warning      @@${LOG_SERVER}:514
daemon.*          @@${LOG_SERVER}:514
syslog.*          @@${LOG_SERVER}:514
local6.*          @@${LOG_SERVER}:514
EOF

systemctl restart auditd 2>/dev/null || true
systemctl restart rsyslog
pass "Security logs forwarding to $LOG_SERVER:514 via TCP"

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  debian-remote-syslog complete${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${GREEN}✓${NC} auditd syslog plugin: ${BOLD}/etc/audit/plugins.d/syslog.conf${NC}"
echo -e "  ${GREEN}✓${NC} rsyslog forwarder:    ${BOLD}/etc/rsyslog.d/50-remote-syslog.conf${NC}"
echo -e "  ${GREEN}✓${NC} Target: ${BOLD}$LOG_SERVER:514${NC} (TCP)"
if [[ $RERUN -eq 1 && -n "$EXISTING_SERVER" && "$EXISTING_SERVER" != "$LOG_SERVER" ]]; then
  echo -e "  ${YELLOW}⚠${NC} Target changed: $EXISTING_SERVER → $LOG_SERVER"
fi
echo ""
echo -e "  ${YELLOW}On the receiver,${NC} watch logs arrive: ${BOLD}sudo tail -f /var/log/syslog${NC}"
echo -e "  ${DIM}This script is idempotent — re-run anytime to change the target.${NC}"
echo ""
