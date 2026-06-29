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
echo -e "${BOLD}wireguard-baseline${NC}"
echo -e "${DIM}WireGuard peer — run as root, after base-server${NC}"
echo ""

[[ $EUID -ne 0 ]] && fail "Must run as root (or via sudo)."
[[ -f /etc/os-release ]] || fail "Cannot detect OS."
# shellcheck source=/dev/null
. /etc/os-release
[[ "$ID" == "debian" ]]    || fail "Debian only. Detected: $ID"
[[ "$VERSION_ID" -ge 13 ]] || fail "Requires Debian 13+. Detected: $VERSION_ID"

SERVER_IP=$(hostname -I | awk '{print $1}')
pass "Debian $VERSION_ID ($VERSION_CODENAME) on $SERVER_IP"

grep -q "^PermitRootLogin no" /etc/ssh/sshd_config 2>/dev/null \
  || fail "base-server.sh has not run on this host (PermitRootLogin still on)."
systemctl is-active --quiet ufw \
  || fail "base-server.sh has not run on this host (UFW not active)."

WG_CONF="/etc/wireguard/wg0.conf"
WG_PUB="/etc/wireguard/publickey"

RERUN=0
[[ -f "$WG_CONF" ]] && RERUN=1

pass "Preflight OK"
echo ""

# ─── Interface config (first run only) ───────────────────────────────────────

[[ -t 0 || -r /dev/tty ]] || fail "No tty available — this script requires interactive input."

OVERLAY_IP=""
LISTEN_PORT="51820"
IP_FORWARD=0

if [[ $RERUN -eq 0 ]]; then
  read -rp "  Overlay IP for this host (e.g. 10.20.0.1/24): " OVERLAY_IP </dev/tty
  OVERLAY_IP="${OVERLAY_IP// /}"
  [[ "$OVERLAY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] \
    || fail "Invalid overlay IP — use CIDR notation, e.g. 10.20.0.1/24."

  read -rp "  Listen port [51820]: " LISTEN_PORT </dev/tty
  LISTEN_PORT="${LISTEN_PORT// /}"
  LISTEN_PORT="${LISTEN_PORT:-51820}"
  [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] && [[ "$LISTEN_PORT" -ge 1 ]] && [[ "$LISTEN_PORT" -le 65535 ]] \
    || fail "Invalid port: $LISTEN_PORT"

  read -rp "  Enable IP forwarding? (needed if this host routes traffic for others) [y/N]: " _fwd </dev/tty
  [[ "${_fwd,,}" == "y" ]] && IP_FORWARD=1
  echo ""
else
  OVERLAY_IP=$(grep -oP '(?<=^Address = ).+' "$WG_CONF" | head -1 || echo "unknown")
  LISTEN_PORT=$(grep -oP '(?<=^ListenPort = )\d+' "$WG_CONF" | head -1 || echo "51820")
  PEER_COUNT=$(grep -c '^\[Peer\]' "$WG_CONF" || true)
  note "Re-run detected"
  note "Overlay IP: $OVERLAY_IP  |  Listen port: $LISTEN_PORT  |  Peers configured: ${PEER_COUNT:-0}"
  echo ""
  echo -e "  ${BOLD}Public key (share with peers):${NC}"
  echo -e "  ${GREEN}$(cat "$WG_PUB")${NC}"
  echo ""
fi

# ─── Peer config ──────────────────────────────────────────────────────────────

ADD_PEER=1
PEER_NAME=""
PEER_PUBKEY=""
PEER_ENDPOINT=""
PEER_ALLOWEDIPS=""

if [[ $RERUN -eq 1 ]]; then
  read -rp "  Add a new peer? [y/N]: " _add </dev/tty
  [[ "${_add,,}" == "y" ]] || ADD_PEER=0
  echo ""
fi

if [[ $ADD_PEER -eq 1 ]]; then
  read -rp "  Peer label (e.g. singapore-prod): " PEER_NAME </dev/tty
  PEER_NAME="${PEER_NAME// /-}"
  [[ -z "$PEER_NAME" ]] && fail "Peer label cannot be empty."

  read -rp "  Peer public key: " PEER_PUBKEY </dev/tty
  PEER_PUBKEY="${PEER_PUBKEY// /}"
  [[ "$PEER_PUBKEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
    || fail "Invalid WireGuard public key — expected 44-character base64."

  if [[ $RERUN -eq 1 ]] && grep -qF "$PEER_PUBKEY" "$WG_CONF" 2>/dev/null; then
    fail "A peer with this public key is already in the config."
  fi

  read -rp "  Peer endpoint IP:port (blank if peer initiates connections): " PEER_ENDPOINT </dev/tty
  PEER_ENDPOINT="${PEER_ENDPOINT// /}"

  read -rp "  Allowed IPs for peer (e.g. 10.20.0.2/32): " PEER_ALLOWEDIPS </dev/tty
  PEER_ALLOWEDIPS="${PEER_ALLOWEDIPS// /}"
  [[ -z "$PEER_ALLOWEDIPS" ]] && fail "Allowed IPs cannot be empty."
  echo ""
fi

# ─── 1/3  Install + keys ─────────────────────────────────────────────────────

section "1/3  WireGuard tools"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wireguard-tools
pass "wireguard-tools installed"

if [[ $RERUN -eq 0 ]]; then
  # Private key: root-only (umask 077). Public key: world-readable (644) so
  # re-running the script always shows it without needing to parse wg0.conf.
  (umask 077; wg genkey | tee /etc/wireguard/privatekey | wg pubkey > "$WG_PUB")
  chmod 644 "$WG_PUB"
  pass "Keypair generated"
else
  pass "Keys preserved"
fi

# ─── 2/3  Interface + peer config ─────────────────────────────────────────────

section "2/3  wg0 config"

if [[ $RERUN -eq 0 ]]; then
  cat > "$WG_CONF" <<EOF
# Managed by wireguard-baseline — wg0 interface config.
[Interface]
PrivateKey = $(cat /etc/wireguard/privatekey)
Address = ${OVERLAY_IP}
ListenPort = ${LISTEN_PORT}
EOF
  chmod 600 "$WG_CONF"
  pass "Interface config written (overlay: $OVERLAY_IP, port: $LISTEN_PORT)"

  if [[ $IP_FORWARD -eq 1 ]]; then
    cat > /etc/sysctl.d/99-wireguard.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    sysctl --system >/dev/null
    pass "IP forwarding enabled (/etc/sysctl.d/99-wireguard.conf)"
  fi
fi

if [[ $ADD_PEER -eq 1 ]]; then
  {
    echo ""
    echo "# Peer: ${PEER_NAME} (added $(date +%Y-%m-%d))"
    echo "[Peer]"
    echo "PublicKey = ${PEER_PUBKEY}"
    if [[ -n "$PEER_ENDPOINT" ]]; then
      echo "Endpoint = ${PEER_ENDPOINT}"
    fi
    echo "AllowedIPs = ${PEER_ALLOWEDIPS}"
    echo "PersistentKeepalive = 25"
  } >> "$WG_CONF"
  pass "Peer '${PEER_NAME}' added"
fi

# ─── 3/3  Firewall + service ─────────────────────────────────────────────────

section "3/3  Firewall + service"
ufw allow "${LISTEN_PORT}"/udp > /dev/null
pass "UFW: ${LISTEN_PORT}/udp open"

if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
  systemctl restart wg-quick@wg0
  pass "WireGuard restarted"
else
  systemctl enable --now wg-quick@wg0
  pass "WireGuard enabled and started"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  wireguard-baseline complete${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${GREEN}✓${NC} Interface: ${BOLD}wg0${NC} — overlay ${BOLD}${OVERLAY_IP}${NC}, port ${BOLD}${LISTEN_PORT}/udp${NC}"
echo -e "  ${GREEN}✓${NC} UFW: ${LISTEN_PORT}/udp open"
if [[ $ADD_PEER -eq 1 ]]; then
  echo -e "  ${GREEN}✓${NC} Peer '${PEER_NAME}' configured"
  if [[ -z "$PEER_ENDPOINT" ]]; then
    echo -e "  ${YELLOW}⚠${NC} No endpoint set for '${PEER_NAME}' — this host waits for the peer to initiate"
  fi
fi
TOTAL_PEERS=$(grep -c '^\[Peer\]' "$WG_CONF" || true)
echo -e "  ${DIM}Total peers in config: ${TOTAL_PEERS:-0}${NC}"
echo ""
echo -e "  ${BOLD}This host's public key (share with peers):${NC}"
echo -e "  ${GREEN}$(cat "$WG_PUB")${NC}"
echo ""
echo -e "  Verify tunnel:     ${BOLD}wg show${NC}"
echo -e "  Check handshakes:  ${BOLD}wg show wg0 latest-handshakes${NC}"
echo -e "  ${DIM}Re-run anytime to add peers or retrieve this host's public key.${NC}"
echo ""
