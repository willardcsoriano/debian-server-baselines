#!/usr/bin/env bash
set -euo pipefail

# ─── docker-upgrade.sh ───────────────────────────────────────────────────────
#
# Deliberate, verified upgrade of rootless Docker on a dev or prod host.
# dev.sh/prod.sh install Docker with --no-upgrade, so a re-run never moves the
# engine; this is the one place that does.  It:
#   1. records every running container and the current package versions,
#   2. upgrades only the Docker packages,
#   3. restarts the rootless daemon so the new engine is actually running,
#   4. starts any container that was running before but didn't come back
#      (containers with restart=no stay stopped after a daemon restart),
#   5. verifies, and prints the exact rollback command if anything is off.
#
# Run as your sudo user (not root), from an SSH login session:
#   bash scripts/docker-upgrade.sh          # upgrade
#   bash scripts/docker-upgrade.sh --check  # show what would be upgraded, change nothing
#
# Expect a short outage: every container stops while the daemon restarts.

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
pass() { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail() { echo -e "\n  ${RED}✗${NC} $1\n"; exit 1; }
note() { echo -e "  ${DIM}$1${NC}"; }

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin
      docker-compose-plugin docker-ce-rootless-extras)

[[ $EUID -eq 0 ]] && fail "Run as your sudo user, not root (rootless Docker is per-user)."
XDG_RUNTIME_DIR="/run/user/$(id -u)"
export XDG_RUNTIME_DIR
export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/docker.sock"
[[ -S "$XDG_RUNTIME_DIR/bus" ]] || fail "No user session bus. Log in via SSH as $USER and re-run."
docker info >/dev/null 2>&1 || fail "Rootless Docker isn't answering at $DOCKER_HOST."

STATE="${XDG_STATE_HOME:-$HOME/.local/state}/docker-upgrade/$(date +%Y%m%d-%H%M%S)"

installed_versions() {
  dpkg-query -W -f='${Package}=${Version}\n' "${PKGS[@]}" 2>/dev/null
}

echo -e "${BOLD}docker-upgrade.sh${NC}"
if (( CHECK )); then
  note "--check uses the existing apt cache (no sudo); it may lag the repo slightly."
else
  sudo apt-get update -qq
fi
mapfile -t upgradable < <(apt list --upgradable 2>/dev/null | cut -d/ -f1 \
  | grep -Fx -f <(printf '%s\n' "${PKGS[@]}") || true)

if (( ${#upgradable[@]} == 0 )); then
  pass "Docker is current: $(docker version --format '{{.Server.Version}}')"
  exit 0
fi

echo "  Upgradable:"
apt list --upgradable 2>/dev/null | grep -F -f <(printf '%s/\n' "${upgradable[@]}") | sed 's/^/    /'

mapfile -t running < <(docker ps --format '{{.Names}}')
no_restart=()
for c in "${running[@]}"; do
  policy=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c")
  [[ "$policy" == "no" || -z "$policy" ]] && no_restart+=("$c")
done
echo "  Running containers: ${#running[@]}"
(( ${#no_restart[@]} )) && note "Without a restart policy (this script restarts them; a reboot won't): ${no_restart[*]}"

(( CHECK )) && { note "--check: nothing changed."; exit 0; }

mkdir -p "$STATE"
installed_versions > "$STATE/versions-before.txt"
printf '%s\n' "${running[@]}" > "$STATE/running-before.txt"
note "Recorded versions and running containers in $STATE"

sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --only-upgrade "${upgradable[@]}"
installed_versions > "$STATE/versions-after.txt"
pass "Packages upgraded"

systemctl --user restart docker
for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 1; done
docker info >/dev/null 2>&1 || {
  echo -e "\n  ${RED}✗${NC} Docker didn't come back after the upgrade. Roll back with:"
  echo "    sudo apt-get install -y --allow-downgrades $(tr '\n' ' ' < "$STATE/versions-before.txt")"
  echo "    systemctl --user restart docker"
  exit 1
}
pass "Daemon running: $(docker version --format '{{.Server.Version}}')"

failed=()
for c in "${running[@]}"; do
  if [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" != "true" ]]; then
    docker start "$c" >/dev/null 2>&1 || true
  fi
done
sleep 5
for c in "${running[@]}"; do
  [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" == "true" ]] || failed+=("$c")
done

if (( ${#failed[@]} )); then
  warn "Not running after upgrade: ${failed[*]} (docker logs <name>)"
  echo "    Roll back with:"
  echo "    sudo apt-get install -y --allow-downgrades $(tr '\n' ' ' < "$STATE/versions-before.txt")"
  echo "    systemctl --user restart docker"
  exit 1
fi
pass "All ${#running[@]} previously running containers are running again"
