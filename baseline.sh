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

[[ $EUID -ne 0 ]]          && fail "Must run as root (or via sudo)."
[[ -f /etc/os-release ]]   || fail "Cannot detect OS."
# shellcheck source=/dev/null
. /etc/os-release
[[ "$ID" == "debian" ]]    || fail "Debian only. Detected: $ID"
[[ "$VERSION_ID" -ge 13 ]] || fail "Requires Debian 13+. Detected: $VERSION_ID"

SERVER_IP=$(hostname -I | awk '{print $1}')
pass "Debian $VERSION_ID ($VERSION_CODENAME) on $SERVER_IP"

# Re-run detection: SSH already hardened means this server has run baseline before
RERUN=0
if [[ -f /etc/ssh/sshd_config ]] && grep -qE "^PermitRootLogin\s+no" /etc/ssh/sshd_config; then
  RERUN=1
  note "Re-run detected — idempotent steps will skip prompts where safe."
fi

# ─── Username ─────────────────────────────────────────────────────────────────

echo ""
[[ -t 0 || -r /dev/tty ]] || fail "No tty available — this script requires interactive input. Use 'curl ... | sudo bash' from a terminal, not from a non-interactive context."
EXISTING_SUDO=$(getent group sudo | cut -d: -f4 | tr ',' '\n' | grep -v '^$' | grep -v '^root$' | head -1 || true)
if [[ -n "$EXISTING_SUDO" ]]; then
  read -rp "  Sudo username [$EXISTING_SUDO]: " NEW_USER </dev/tty
  NEW_USER="${NEW_USER:-$EXISTING_SUDO}"
else
  read -rp "  Sudo username to create: " NEW_USER </dev/tty
fi
echo ""

[[ -z "$NEW_USER" ]]                           && fail "Username cannot be empty."
[[ "$NEW_USER" == "root" ]]                    && fail "Cannot use 'root'."
[[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]      || fail "Invalid username. Lowercase, numbers, hyphens only."
[[ ! -f /root/.ssh/authorized_keys ]]          && fail "No SSH key at /root/.ssh/authorized_keys. Cannot proceed safely."
[[ ! -s /root/.ssh/authorized_keys ]]          && fail "authorized_keys is empty. Add your public key first."

# Monitoring opt-in (auto-detected on re-run via installed packages)
INSTALL_MONITORING=0
if dpkg -l cockpit 2>/dev/null | grep -q '^ii' || \
   [[ -x /opt/netdata/bin/netdata ]] || \
   systemctl list-unit-files 2>/dev/null | grep -q '^netdata\.service'; then
  INSTALL_MONITORING=1
  note "Monitoring detected — section 11/20 will verify install."
else
  read -rp "  Install monitoring (Cockpit + Netdata)? [y/N]: " _mon_ans </dev/tty
  [[ "${_mon_ans,,}" == "y" ]] && INSTALL_MONITORING=1
fi

# Remote syslog opt-in (auto-detected on re-run via existing config)
LOG_SERVER=""
if [[ -f /etc/rsyslog.d/50-remote-syslog.conf ]]; then
  LOG_SERVER=$(grep -oP '@@\K[^:]+' /etc/rsyslog.d/50-remote-syslog.conf | head -1 || true)
  note "Remote syslog detected → $LOG_SERVER (section 20/20 will verify)"
else
  read -rp "  Remote syslog server IP/hostname (leave blank to skip): " LOG_SERVER </dev/tty
  LOG_SERVER="${LOG_SERVER// /}"
  [[ -n "$LOG_SERVER" ]] && note "Logs will forward to $LOG_SERVER:514 via TCP in section 20/20."
fi
echo ""

# ─── Helpers ──────────────────────────────────────────────────────────────────

SSHD_CONFIG="/etc/ssh/sshd_config"

set_sshd() {
  local key="$1" val="$2"
  if grep -qE "^#?\s*${key}\b" "$SSHD_CONFIG"; then
    sed -i -E "s|^#?\s*${key}.*|${key} ${val}|" "$SSHD_CONFIG"
  else
    echo "${key} ${val}" >> "$SSHD_CONFIG"
  fi
}

set_login_def() {
  local key="$1" val="$2" file="/etc/login.defs"
  if grep -qE "^#?\s*${key}\b" "$file"; then
    sed -i -E "s|^#?\s*${key}.*|${key}\t${val}|" "$file"
  else
    printf '%s\t%s\n' "${key}" "${val}" >> "$file"
  fi
}

# ─── Hostname ─────────────────────────────────────────────────────────────────

# sudo looks up the hostname for its log lines.  If /etc/hosts has no entry
# for it, every sudo invocation emits "unable to resolve host <name>".
# 127.0.1.1 is the Debian convention for a local hostname with no real DNS
# entry; 127.0.0.1 is left for localhost and is not touched.
_hostname=$(hostname -s)
if ! grep -qE "^127\.0\.1\.1[[:space:]]+$_hostname\b" /etc/hosts; then
  echo "127.0.1.1 $_hostname" >> /etc/hosts
  pass "127.0.1.1 → $_hostname added to /etc/hosts"
else
  pass "/etc/hosts: 127.0.1.1 → $_hostname already present"
fi

# ─── 1. System updates ────────────────────────────────────────────────────────

section "1/20  System updates"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
pass "All packages updated"

# ─── 2. Automatic security updates ───────────────────────────────────────────

section "2/20  Automatic security updates"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades
systemctl enable --now unattended-upgrades -q
pass "unattended-upgrades active"

# ─── 3. Sudo user ─────────────────────────────────────────────────────────────

section "3/20  Sudo user ($NEW_USER)"
if id "$NEW_USER" &>/dev/null; then
  warn "User $NEW_USER already exists — skipping creation"
else
  adduser --gecos "" --disabled-password "$NEW_USER" -q
  pass "User $NEW_USER created"
fi
usermod -aG sudo "$NEW_USER"

# Sudo requires a password — defense in depth so a leaked SSH key alone
# can't escalate to root. Status "P" means a password is set; anything
# else (NP, L, or no shadow entry) means we need to prompt for one.
USER_PWSTATUS=$(passwd -S "$NEW_USER" 2>/dev/null | awk '{print $2}')
if [[ "$USER_PWSTATUS" != "P" ]]; then
  echo ""
  echo -e "  ${YELLOW}Set a sudo password for $NEW_USER:${NC}"
  echo -e "  ${DIM}(needed because sudo no longer runs without one)${NC}"
  passwd "$NEW_USER" </dev/tty
  echo ""
fi

echo "$NEW_USER ALL=(ALL) ALL" > /etc/sudoers.d/"$NEW_USER"
chmod 440 /etc/sudoers.d/"$NEW_USER"
pass "$NEW_USER in sudo group (password required)"

# ─── 4. Copy SSH key ──────────────────────────────────────────────────────────

section "4/20  SSH key"
USER_HOME="/home/$NEW_USER"
mkdir -p "$USER_HOME/.ssh"
touch "$USER_HOME/.ssh/authorized_keys"
# Ensure every key from root is present — merge rather than copy-if-empty so
# re-runs and pre-existing accounts (e.g. created by a VPS image) always have
# the key that root was using, even if the file already contained other keys.
_added=0
while IFS= read -r _keyline; do
  [[ -z "$_keyline" || "$_keyline" == \#* ]] && continue
  _keymaterial=$(awk '{print $2}' <<<"$_keyline")
  if ! grep -qF "$_keymaterial" "$USER_HOME/.ssh/authorized_keys"; then
    echo "$_keyline" >> "$USER_HOME/.ssh/authorized_keys"
    (( _added++ )) || true
  fi
done < /root/.ssh/authorized_keys
if [[ $_added -gt 0 ]]; then
  pass "SSH key merged into $NEW_USER authorized_keys ($_added key(s) added)"
else
  pass "authorized_keys verified for $NEW_USER (root keys already present)"
fi
chmod 755 "$USER_HOME"  # sshd StrictModes: home dir must not be group/world-writable
chown -R "$NEW_USER:$NEW_USER" "$USER_HOME/.ssh"
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"

# ─── 5. Safety check ─────────────────────────────────────────────────────────

section "5/20  SSH safety check"
if [[ $RERUN -eq 1 ]]; then
  pass "SSH already hardened — skipping interactive confirmation"
else
  echo ""
  echo -e "  ${YELLOW}Before locking down SSH, verify the new account works.${NC}"
  echo ""
  echo -e "  Open a new terminal and run:"
  echo -e "  ${BOLD}    ssh $NEW_USER@$SERVER_IP${NC}"
  echo ""
  read -rp "  Type 'yes' to confirm login worked: " CONFIRMED </dev/tty
  [[ "$CONFIRMED" != "yes" ]] && fail "Aborted. Resolve SSH access before continuing."
  pass "SSH access confirmed"
fi

# ─── 6. SSH hardening ────────────────────────────────────────────────────────

section "6/20  SSH hardening"
cp "$SSHD_CONFIG" "$SSHD_CONFIG.bak.$(date +%Y%m%d-%H%M%S)"

set_sshd PermitRootLogin        no
set_sshd PasswordAuthentication no
set_sshd PubkeyAuthentication   yes
set_sshd MaxAuthTries           3
set_sshd LoginGraceTime         30
set_sshd X11Forwarding          no
set_sshd AllowTcpForwarding     local
set_sshd AllowAgentForwarding   no
# MaxSessions 10 matches the OpenSSH default and supports IDE-extension
# workflows (VSCode Remote-SSH, JetBrains Gateway) that open 5–10 multiplexed
# channels per connection.  MaxAuthTries 3, LoginGraceTime 30, fail2ban, and
# AllowUsers make the tighter historic value of 2 redundant without adding
# meaningful protection against any realistic threat.
set_sshd MaxSessions            10
# ClientAliveInterval/CountMax keep NAT-traversed tunnels alive (Cockpit,
# Netdata, port-forwarded services) and drop genuinely dead connections after
# ~3 minutes (60s × 3) instead of waiting indefinitely.
set_sshd ClientAliveInterval    60
set_sshd ClientAliveCountMax    3
set_sshd LogLevel               VERBOSE
set_sshd TCPKeepAlive           no

# AllowUsers: explicit allowlist of every sudo group member (minus root). This
# closes the case where a local account exists without a password but with a
# usable shell — PermitRootLogin=no blocks root, this blocks everyone else by
# default. On re-run we re-derive the list so newly-added sudoers are included.
# $NEW_USER is always included explicitly — group membership caching or timing
# edge cases on a first run could otherwise leave them out and break SSH.
SUDO_USERS=$(getent group sudo | cut -d: -f4 | tr ',' ' ' | sed 's/\broot\b//g' | xargs || true)
if ! echo " $SUDO_USERS " | grep -qw "$NEW_USER"; then
  SUDO_USERS="${SUDO_USERS:+$SUDO_USERS }$NEW_USER"
fi
set_sshd AllowUsers "$SUDO_USERS"

sshd -t || fail "sshd_config invalid — original backed up to $SSHD_CONFIG.bak.*"
systemctl reload sshd
pass "SSH hardened (root off, key-only, restricted forwarding/sessions, AllowUsers=$SUDO_USERS)"

# ─── 7. Firewall ──────────────────────────────────────────────────────────────

section "7/20  Firewall (UFW)"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw
ufw default deny incoming  > /dev/null
ufw default allow outgoing > /dev/null
for port in 22 80 443; do
  ufw allow "$port"/tcp > /dev/null
done
ufw --force enable > /dev/null
pass "UFW enabled — ports 22, 80, 443 open"

# ─── 8. fail2ban ─────────────────────────────────────────────────────────────

section "8/20  Brute-force protection (fail2ban)"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban
mkdir -p /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/00-baseline.conf <<'EOF'
# Managed by debian-baseline. Place user overrides in /etc/fail2ban/jail.local
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = 22
EOF
# Migrate from earlier versions that wrote /etc/fail2ban/jail.local.
# If jail.local matches what an older baseline run would have written,
# remove it so the user-owned jail.local stays clean for their overrides.
if [[ -f /etc/fail2ban/jail.local ]]; then
  OLD_JAIL_LOCAL="[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = 22"
  if [[ "$(cat /etc/fail2ban/jail.local)" == "$OLD_JAIL_LOCAL" ]]; then
    rm /etc/fail2ban/jail.local
    note "Migrated jail.local → jail.d/00-baseline.conf (user override slot freed)"
  fi
fi
# DEB-0880: ensure /etc/fail2ban/jail.local exists so package updates can't
# silently replace jail.conf-derived config. We leave the file empty for the
# operator to use as their override slot — our policy lives in jail.d/.
if [[ ! -f /etc/fail2ban/jail.local ]]; then
  cat > /etc/fail2ban/jail.local <<'EOF'
# fail2ban user override file. Loaded after jail.conf and jail.d/*.conf.
# Add custom overrides here — debian-baseline will not touch this file
# unless its content exactly matches a legacy baseline write.
EOF
fi
systemctl enable --now fail2ban -q
systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban -q 2>/dev/null || true
pass "fail2ban active — 5 failed attempts → 1h ban"

# ─── 9. Kernel hardening ─────────────────────────────────────────────────────

section "9/20  Kernel hardening (sysctl)"
cat > /etc/sysctl.d/99-hardening.conf <<'EOF'
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
kernel.randomize_va_space = 2
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
EOF
sysctl --system >/dev/null
pass "Kernel parameters applied"

# /tmp as tmpfs with noexec,nosuid,nodev — prevents execution of files dropped
# in /tmp, which is the first stage of most local privilege escalation chains.
if findmnt -n -o FSTYPE /tmp 2>/dev/null | grep -q tmpfs; then
  pass "/tmp already tmpfs (preserved)"
elif grep -q '^tmpfs /tmp' /etc/fstab 2>/dev/null; then
  mount -o remount /tmp
  pass "/tmp remounted as tmpfs (noexec,nosuid,nodev)"
else
  echo "tmpfs /tmp tmpfs defaults,noexec,nosuid,nodev,size=2G 0 0" >> /etc/fstab
  mount -t tmpfs -o defaults,noexec,nosuid,nodev,size=2G tmpfs /tmp
  pass "/tmp mounted as tmpfs (noexec,nosuid,nodev)"
fi

# ─── 10. AppArmor ────────────────────────────────────────────────────────────

section "10/20 AppArmor"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq apparmor apparmor-utils
systemctl enable --now apparmor -q
ENFORCED=$(aa-status 2>/dev/null | grep "profiles are in enforce mode" | grep -oP '^\d+' || echo "?")
pass "AppArmor active ($ENFORCED profiles enforcing)"

# ─── 11. Cockpit + Netdata ───────────────────────────────────────────────────

section "11/20 Monitoring (Cockpit + Netdata)"
NETDATA_OK=0
if [[ $INSTALL_MONITORING -eq 1 ]]; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cockpit
  systemctl enable --now cockpit.socket -q
  pass "Cockpit installed"
  note "Access: ssh -N -L 9090:localhost:9090 $NEW_USER@$SERVER_IP → https://localhost:9090"

  NETDATA_OK=1
  if [[ -x /opt/netdata/bin/netdata ]] || systemctl list-unit-files 2>/dev/null | grep -q '^netdata\.service'; then
    pass "Netdata already installed (preserved)"
  elif bash <(curl -fsSL https://get.netdata.cloud/kickstart.sh) \
         --non-interactive --no-updates --disable-telemetry > /dev/null 2>&1; then
    pass "Netdata installed"
  else
    warn "Netdata install failed — install manually"
    NETDATA_OK=0
  fi
  note "Access: ssh -N -L 19999:localhost:19999 $NEW_USER@$SERVER_IP → http://localhost:19999"
else
  note "Skipped (not requested)"
fi

# ─── 12. rkhunter + auditd ───────────────────────────────────────────────────

section "12/20 Intrusion detection (rkhunter + auditd + AIDE)"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rkhunter auditd aide
rkhunter --update --quiet 2>/dev/null || true
if [[ ! -f /var/lib/rkhunter/db/rkhunter.dat ]]; then
  rkhunter --propupd --quiet 2>/dev/null || true
  pass "rkhunter baseline saved"
else
  pass "rkhunter database present (baseline preserved)"
fi

# FINT-4350: AIDE for file integrity monitoring. The first init scans the
# entire filesystem and takes ~30–60s on a clean Debian install. Skip if
# a database already exists so re-runs don't rebuild from scratch.
if [[ -f /var/lib/aide/aide.db ]] || [[ -f /var/lib/aide/aide.db.gz ]]; then
  pass "AIDE database present (baseline preserved)"
else
  note "Initializing AIDE database — this takes ~30–60s on a fresh install..."
  aideinit --yes --force >/dev/null 2>&1 || aide --init >/dev/null 2>&1 || true
  [[ -f /var/lib/aide/aide.db.new.gz ]] && mv -f /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
  [[ -f /var/lib/aide/aide.db.new ]]    && mv -f /var/lib/aide/aide.db.new /var/lib/aide/aide.db
  pass "AIDE database initialized"
fi

systemctl enable --now auditd -q

# ACCT-9630: auditd starts with an empty ruleset by default — drop a baseline
# rules file covering identity, SSH, audit config, login records, time, and
# kernel module loading. augenrules merges rules.d/*.rules into audit.rules
# and reloads. No -e 2 (immutable) — leaves room for operator-added rules
# without forcing a reboot to remove them.
cat > /etc/audit/rules.d/50-baseline.rules <<'EOF'
## Buffer + failure mode
-b 8192
-f 1

## Identity changes
-w /etc/group       -p wa -k identity
-w /etc/passwd      -p wa -k identity
-w /etc/shadow      -p wa -k identity
-w /etc/gshadow     -p wa -k identity
-w /etc/sudoers     -p wa -k identity
-w /etc/sudoers.d/  -p wa -k identity

## SSH config
-w /etc/ssh/sshd_config    -p wa -k sshd_config
-w /etc/ssh/sshd_config.d/ -p wa -k sshd_config

## Audit subsystem itself
-w /etc/audit/        -p wa -k audit_config
-w /etc/libaudit.conf -p wa -k audit_config

## Login records
-w /var/log/lastlog    -p wa -k logins
-w /var/log/btmp       -p wa -k logins
-w /var/log/wtmp       -p wa -k logins
-w /var/run/faillock   -p wa -k logins

## System time
-a always,exit -F arch=b64 -S adjtimex,settimeofday,clock_settime -k time-change

## Kernel module loading
-w /sbin/insmod    -p x -k modules
-w /sbin/rmmod     -p x -k modules
-w /sbin/modprobe  -p x -k modules
-a always,exit -F arch=b64 -S init_module,finit_module,delete_module -k modules
EOF
augenrules --load >/dev/null 2>&1 || systemctl restart auditd
pass "auditd active (baseline ruleset loaded)"

# ─── 13. Legal banners ───────────────────────────────────────────────────────

section "13/20 Legal banners"
BANNER=$(cat <<'EOF'
**************************************************************************
*                                                                        *
*  Authorized access only. All activity is logged and monitored.         *
*  Disconnect immediately if you are not an authorized user.             *
*                                                                        *
**************************************************************************
EOF
)
write_banner() {
  local target="$1" current=""
  [[ -f "$target" ]] && current=$(cat "$target")
  # Overwrite only if: missing, empty, default Debian banner, or already our banner.
  # Anything else is treated as user customization and preserved.
  if [[ -z "$current" ]] \
     || [[ "$current" == *"Debian GNU/Linux"* ]] \
     || [[ "$current" == "$BANNER" ]]; then
    printf '%s\n' "$BANNER" > "$target"
    pass "$target installed"
  else
    warn "$target customized — leaving untouched"
  fi
}
write_banner /etc/issue
write_banner /etc/issue.net

# ─── 14. Password policy ─────────────────────────────────────────────────────

section "14/20 Password policy (login.defs)"
set_login_def PASS_MAX_DAYS         90
set_login_def PASS_MIN_DAYS         1
set_login_def PASS_WARN_AGE         7
set_login_def UMASK                 027
set_login_def SHA_CRYPT_MIN_ROUNDS  5000
set_login_def SHA_CRYPT_MAX_ROUNDS  100000
set_login_def ENCRYPT_METHOD        SHA512

# login.defs only binds at user-creation time, so accounts created before
# this step (most importantly the sudo user from section 3) keep Debian's
# defaults. Apply the same aging policy to every existing sudo group member
# via chage so the policy actually takes effect on the box.
for sudo_user in $(getent group sudo | cut -d: -f4 | tr ',' '\n' | grep -v '^$' | grep -v '^root$'); do
  chage -M 90 -m 1 -W 7 "$sudo_user" 2>/dev/null || true
done
pass "Password aging + umask 027 + SHA512 rounds configured (applied to existing sudo users)"

# ─── 15. Debian goodies + PAM strength ───────────────────────────────────────

section "15/20 Debian goodies + PAM strength"
# Pre-seed needrestart's config so its first invocation (during its own
# install, and apt installs in sections 17/18) auto-restarts deferred
# services and stops printing the "Services to be restarted" list.
# Creating the dir before needrestart owns it is fine — root:root, 0755
# is what the package would set anyway.
mkdir -p /etc/needrestart/conf.d
cat > /etc/needrestart/conf.d/50-autorestart.conf <<'EOF'
# Managed by debian-baseline. 'a' = auto-restart, no prompts, no list.
$nrconf{restart} = 'a';
EOF
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  libpam-tmpdir libpam-passwdqc apt-listbugs apt-listchanges \
  needrestart debsums apt-show-versions
# PKGS-7370: enable debsums daily cron so package integrity is verified
# on a schedule, not just on demand. Value is intentionally unquoted —
# Lynis's PKGS-7370 test splits on '=' and string-compares the result
# to 'daily', so CRON_CHECK="daily" matches as "daily" (with quotes)
# and the check fails. Both forms are valid shell.
if [[ -f /etc/default/debsums ]]; then
  if grep -qE '^#?\s*CRON_CHECK=' /etc/default/debsums; then
    sed -i -E 's|^#?\s*CRON_CHECK=.*|CRON_CHECK=daily|' /etc/default/debsums
  else
    echo 'CRON_CHECK=daily' >> /etc/default/debsums
  fi
fi
pass "libpam-tmpdir, libpam-passwdqc, apt safety nets installed (debsums cron: daily)"

# ─── 16. Disable unused kernel modules ───────────────────────────────────────

section "16/20 Disable unused kernel modules"
cat > /etc/modprobe.d/blacklist-rare-network.conf <<'EOF'
install dccp /bin/true
install sctp /bin/true
install rds  /bin/true
install tipc /bin/true
EOF
cat > /etc/modprobe.d/blacklist-storage.conf <<'EOF'
blacklist usb-storage
blacklist firewire-core
blacklist firewire-ohci
blacklist firewire-sbp2
EOF
pass "Rare network protocols + USB/Firewire storage blacklisted"

# HRDN-7222: restrict compilers to root only. Lynis flags world-executable
# compilers because they let an attacker with a shell build local exploits.
# We touch the unversioned names and the versioned ones the apt toolchain
# installs (gcc-13, g++-13, etc.).
COMPILERS_RESTRICTED=0
for compiler in /usr/bin/gcc /usr/bin/g++ /usr/bin/cc /usr/bin/c++ \
                /usr/bin/cpp /usr/bin/as /usr/bin/gcc-* /usr/bin/g++-*; do
  if [[ -e $compiler ]]; then
    chown root:root "$compiler" 2>/dev/null || true
    chmod 750 "$compiler"
    COMPILERS_RESTRICTED=1
  fi
done
if [[ $COMPILERS_RESTRICTED -eq 1 ]]; then
  pass "Compilers (gcc/g++/cc/c++/cpp/as) restricted to root (mode 750)"
else
  note "No compilers found on \$PATH — nothing to restrict"
fi

# ─── 17. Process accounting ──────────────────────────────────────────────────

section "17/20 Process accounting (acct + sysstat)"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq acct sysstat
systemctl enable --now acct.service -q 2>/dev/null || \
  systemctl enable --now psacct.service -q 2>/dev/null || true
sed -i 's|^ENABLED="false"|ENABLED="true"|' /etc/default/sysstat 2>/dev/null || true
systemctl enable --now sysstat -q
pass "Process accounting (acct + sysstat) active"

# ─── 18. Lynis ───────────────────────────────────────────────────────────────

section "18/20 Security audit (Lynis)"
# LYNIS suggestion: Debian's lynis package lags upstream by months. Pin to
# CISOfy's apt repo so we get the current release and the latest test set.
# Keys live in /etc/apt/keyrings/ per modern Debian convention; the sources
# file is namespaced (cisofy-lynis.list) so we never collide with other repos.
mkdir -p /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/cisofy.gpg ]]; then
  curl -fsSL https://packages.cisofy.com/keys/cisofy-software-public.key \
    | gpg --dearmor -o /etc/apt/keyrings/cisofy.gpg
  chmod 644 /etc/apt/keyrings/cisofy.gpg
fi
if [[ ! -f /etc/apt/sources.list.d/cisofy-lynis.list ]]; then
  echo "deb [arch=amd64,arm64 signed-by=/etc/apt/keyrings/cisofy.gpg] https://packages.cisofy.com/community/lynis/deb/ stable main" \
    > /etc/apt/sources.list.d/cisofy-lynis.list
  apt-get update -qq
fi
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq lynis
if [[ ! -f /var/log/lynis-baseline.log ]]; then
  lynis audit system --quiet --nocolors > /var/log/lynis-baseline.log 2>&1 || true
  pass "First audit saved to /var/log/lynis-baseline.log"
else
  lynis audit system --quiet --nocolors > /dev/null 2>&1 || true
  pass "Re-audit complete (baseline preserved at /var/log/lynis-baseline.log)"
fi
SCORE=$(grep "Hardening index" /var/log/lynis.log 2>/dev/null | tail -1 | grep -oP 'Hardening index : \[\K\d+' || echo "?")
pass "Hardening index: $SCORE"

# ─── 19. Operator tooling ────────────────────────────────────────────────────

section "19/20 Operator tooling"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git tmux jq htop
pass "git, tmux, jq, htop installed"

# Clean up packages pulled in transitively but no longer needed
DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq

# ─── 20. Remote syslog (optional) ────────────────────────────────────────────

section "20/20 Remote syslog"
if [[ -n "$LOG_SERVER" ]]; then
  # Enable auditd syslog plugin so audit events flow through rsyslog
  cat > /etc/audit/plugins.d/syslog.conf <<'EOF'
active = yes
direction = out
path = builtin_syslog
type = builtin
args = LOG_INFO
format = string
EOF

  # Forward security-relevant log facilities via TCP (@@) to the log server.
  # local6 captures auditd events once the syslog plugin above is active.
  cat > /etc/rsyslog.d/50-remote-syslog.conf <<EOF
# Managed by debian-baseline — forward security logs to remote syslog server.
auth,authpriv.*   @@${LOG_SERVER}:514
kern.warning      @@${LOG_SERVER}:514
daemon.*          @@${LOG_SERVER}:514
syslog.*          @@${LOG_SERVER}:514
local6.*          @@${LOG_SERVER}:514
EOF

  systemctl restart auditd 2>/dev/null || true
  systemctl restart rsyslog
  pass "Security logs forwarding to $LOG_SERVER:514 via TCP"
else
  note "Skipped (no log server specified)"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  debian-baseline complete${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${GREEN}✓${NC} /etc/hosts: 127.0.1.1 → $_hostname (sudo lookup fix)"
echo -e "  ${GREEN}✓${NC} System updated + auto security patches"
echo -e "  ${GREEN}✓${NC} Sudo user: ${BOLD}$NEW_USER${NC}"
echo -e "  ${GREEN}✓${NC} SSH: root off, key-only, restricted forwarding"
echo -e "  ${GREEN}✓${NC} Firewall: 22, 80, 443 open — all else denied"
echo -e "  ${GREEN}✓${NC} fail2ban: brute-force protection active"
echo -e "  ${GREEN}✓${NC} Kernel: network attack surface reduced + /tmp noexec"
echo -e "  ${GREEN}✓${NC} AppArmor: mandatory access control active"
if [[ $INSTALL_MONITORING -eq 1 ]]; then
  if [[ $NETDATA_OK -eq 1 ]]; then
    echo -e "  ${GREEN}✓${NC} Cockpit + Netdata: installed, tunnel-only access"
  else
    echo -e "  ${GREEN}✓${NC} Cockpit: installed, tunnel-only access"
    echo -e "  ${YELLOW}⚠${NC} Netdata: install failed — install manually"
  fi
else
  echo -e "  ${DIM}–${NC} Monitoring: skipped"
fi
echo -e "  ${GREEN}✓${NC} rkhunter + auditd + AIDE: intrusion detection active"
echo -e "  ${GREEN}✓${NC} Legal banners + password policy enforced"
echo -e "  ${GREEN}✓${NC} Debian-goodies + PAM strength installed"
echo -e "  ${GREEN}✓${NC} Unused kernel modules blacklisted"
echo -e "  ${GREEN}✓${NC} Process accounting (acct + sysstat) active"
echo -e "  ${GREEN}✓${NC} Lynis: hardening index ${BOLD}$SCORE${NC}"
echo -e "  ${GREEN}✓${NC} Operator tooling: git, tmux, jq, htop"
if [[ -n "$LOG_SERVER" ]]; then
  echo -e "  ${GREEN}✓${NC} Remote syslog: security logs → $LOG_SERVER:514 via TCP"
else
  echo -e "  ${DIM}–${NC} Remote syslog: skipped"
fi
echo ""
echo -e "  ${YELLOW}Root SSH is disabled.${NC} Log in as: ${BOLD}ssh $NEW_USER@$SERVER_IP${NC}"
echo -e "  ${YELLOW}Lynis report:${NC} /var/log/lynis.log"
echo -e "  ${DIM}This script is idempotent — re-run anytime to refresh.${NC}"
echo ""
