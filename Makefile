# Recovery commands for the dev VM banner-exchange incident.
# See docs/reports/dev-vm-ssh-banner-timeout-cascade.md for the full story.
#
#   make recover           <- the one command to run when it happens again
#   make check              <- just look at metrics, no action taken
#   make postmortem         <- pull logs/process info from the VM right now
#   make verify-hardening   <- confirm the cascade's and agent-host's
#                              mitigations are actually live on dev, not
#                              just documented as applied

SHELL := /bin/bash
.ONESHELL:

SERVER  := dev
HCTX    := willard-mba15
LOGDIR  := $(HOME)/vm-incident-logs

.PHONY: check password-reset soft-reboot hard-reset wait-ssh postmortem recover verify-hardening

check:
	@hcloud context use $(HCTX) >/dev/null 2>&1
	now=$$(date -u +%Y-%m-%dT%H:%M:%SZ)
	start=$$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
	echo "Metrics window: $$start -> $$now"
	for t in cpu network disk; do
		echo "=== $$t (last 5 samples per series) ==="
		hcloud server metrics $(SERVER) --type $$t --start "$$start" --end "$$now" -o json \
			| jq -r '.metrics.time_series | to_entries[] | .key as $$k | .value.values[-5:][] | [$$k, (.[0] | todate), .[1]] | @tsv' \
			| column -t
	done

password-reset:
	@hcloud context use $(HCTX) >/dev/null 2>&1
	hcloud server reset-password $(SERVER) || echo "Failed (expected if the guest is too starved to respond - itself useful evidence)."

soft-reboot:
	@hcloud context use $(HCTX) >/dev/null 2>&1
	hcloud server reboot $(SERVER)

hard-reset:
	@hcloud context use $(HCTX) >/dev/null 2>&1
	@echo "Hard power-cycle - more abrupt than a soft reboot. Proceeding."
	hcloud server reset $(SERVER)

wait-ssh:
	@for i in $$(seq 1 18); do
		if timeout 5 ssh -o BatchMode=yes -o ConnectTimeout=4 $(SERVER) 'true' 2>/dev/null; then
			echo "SSH is up (after $$((i*5))s)."; exit 0
		fi
		echo "t+$$((i*5))s: still down"
		sleep 5
	done
	echo "Still down after 90s."
	exit 1

postmortem:
	@mkdir -p $(LOGDIR)
	out=$(LOGDIR)/$$(date -u +%Y%m%dT%H%M%SZ).log
	echo "Writing to $$out"
	{
		echo "=== uptime ==="; ssh $(SERVER) 'uptime' 2>&1
		echo "=== free -h ==="; ssh $(SERVER) 'free -h' 2>&1
		echo "=== top mem procs ==="; ssh $(SERVER) 'ps aux --sort=-%mem | head -15' 2>&1
		echo "=== docker.service (user) ==="; ssh $(SERVER) 'systemctl --user status docker.service --no-pager -l' 2>&1
		echo "=== docker ps -a ==="; ssh $(SERVER) 'docker ps -a' 2>&1
		echo "=== journalctl --list-boots ==="; ssh $(SERVER) 'journalctl --list-boots' 2>&1
		echo "=== journalctl -b -1, tail of the previous (likely crashed) boot ==="
		ssh $(SERVER) 'journalctl -b -1 --no-pager 2>&1 | tail -300'
	} | tee "$$out"
	echo ""
	echo "Saved to $$out - paste relevant parts back if you want this folded into docs/reports/dev-vm-ssh-banner-timeout-cascade.md."

verify-hardening:
	@echo "### docker.service crash-loop guard (cascade report, corrective actions) ###"
	ssh $(SERVER) 'systemctl --user show docker.service -p StartLimitIntervalUSec,StartLimitBurst' 2>&1
	echo ""
	echo "### user-1000.slice memory ceiling (cascade report, corrective actions) ###"
	ssh $(SERVER) 'systemctl show user-1000.slice -p MemoryMax,MemoryHigh' 2>&1
	echo ""
	echo "### vscode-server-reap timer (docs/agent-host.md #e) ###"
	ssh $(SERVER) 'systemctl is-enabled vscode-server-reap.timer vscode-server-reap-orphans.timer 2>&1; systemctl --no-pager list-timers vscode-server-reap.timer vscode-server-reap-orphans.timer 2>&1'
	echo ""
	echo "Red flags: 'infinity' on either memory line, '0 timers listed', or 'not-found'/'disabled' on either timer -"
	echo "that mitigation has silently regressed even though the docs say it's applied. Re-deploy via dev.sh rather"
	echo "than trusting a doc's status line."

recover:
	@echo "### Step 1: is SSH already back up? ###"
	if timeout 5 ssh -o BatchMode=yes -o ConnectTimeout=4 $(SERVER) 'true' 2>/dev/null; then
		echo "SSH is up. Capturing a quick snapshot in case this was a near-miss, no restart needed."
		$(MAKE) --no-print-directory postmortem
		exit 0
	fi

	echo "### SSH is down. Step 2: check metrics (read-only) ###"
	$(MAKE) --no-print-directory check

	echo "### Step 3: try the cheap, non-destructive fix (live root password reset) ###"
	$(MAKE) --no-print-directory password-reset
	echo "Waiting 10s, then checking if that alone helped..."
	sleep 10
	if timeout 5 ssh -o BatchMode=yes -o ConnectTimeout=4 $(SERVER) 'true' 2>/dev/null; then
		echo "SSH recovered without a reboot."
		$(MAKE) --no-print-directory postmortem
		exit 0
	fi

	echo "### Step 4: soft ACPI reboot ###"
	$(MAKE) --no-print-directory soft-reboot
	if $(MAKE) --no-print-directory wait-ssh; then
		echo "SSH recovered after soft reboot."
		$(MAKE) --no-print-directory postmortem
		exit 0
	fi

	echo "### Step 5: soft reboot had no effect. Hard power-cycle. ###"
	$(MAKE) --no-print-directory hard-reset
	if $(MAKE) --no-print-directory wait-ssh; then
		echo "SSH recovered after hard reset."
		$(MAKE) --no-print-directory postmortem
		exit 0
	fi

	echo "Still down after every step. Time to check the Hetzner console/support directly."
	exit 1
