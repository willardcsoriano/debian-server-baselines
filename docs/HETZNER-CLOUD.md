# Hetzner Cloud

## Overview

This repo's OS-level hardening (`scripts/base.sh`'s UFW rules, fail2ban, SSH lockdown) has no visibility into or enforcement from Hetzner's own cloud layer — a hardened server could still be running with no matching Hetzner Cloud Firewall, meaning the host's own UFW rules were the only thing standing between the internet and everything not on 22/80/443. This doc covers two things that live above the OS layer this repo otherwise documents: the Hetzner Cloud Firewall that now mirrors each hardened server's UFW policy as a second, independent enforcement point, and the general procedure for migrating a server to a larger type or a different location via Hetzner snapshots — necessary because Hetzner doesn't support resizing into a server type that isn't available in the server's current datacenter. `dev`'s move from Nuremberg (`cx43`, 16GB) to Helsinki (`cx53`, 32GB) is documented here as the worked example.

## Table of Contents

- [Overview](#overview)
- [Hetzner Cloud Firewall](#hetzner-cloud-firewall)
  - [Why this exists](#why-this-exists)
  - [Current state](#current-state)
  - [Recreating it for another server](#recreating-it-for-another-server)
- [Server migration via snapshot](#server-migration-via-snapshot)
  - [Why snapshot-and-recreate, not resize](#why-snapshot-and-recreate-not-resize)
  - [General procedure](#general-procedure)
  - [Worked example: dev → Helsinki `cx53`](#worked-example-dev-helsinki-cx53)

## Hetzner Cloud Firewall

### Why this exists

The OS-level baseline configures UFW to allow only 22/80/443 inbound and deny everything else. That's solid, but until now it was the *only* layer — Hetzner's own network edge, before traffic ever reaches the VM's kernel, had no matching restriction. A Hetzner Cloud Firewall is a second, independent enforcement point: even if UFW were ever disabled, misconfigured, or reset (re-running installers, a bad `ufw reset`, human error mid-incident), the cloud-level firewall still blocks everything except 22/80/443 + ICMP before it reaches the box at all.

This is defense-in-depth, not a fix for an active leak. Before creating it, direct external reachability testing (`nc -zv` from an outside host, not just checking what's bound locally) confirmed that services like Netdata (19999) and Prometheus (9090) — bound to `0.0.0.0`, which looks alarming from `ss -tlnp` alone — were already correctly unreachable from the internet, because UFW was already blocking them. Verify before assuming exposure; a process bound to `0.0.0.0` is not the same thing as a port reachable from outside.

### Current state

`dev-baseline-match` (Hetzner Cloud Firewall, applied to `dev`):

- TCP 22 (SSH), 80 (HTTP), 443 (HTTPS) inbound, allowed from anywhere — mirrors UFW exactly
- ICMP inbound, allowed from anywhere — several incident runbooks in the `dotfiles` repo's `ssh-vm-banner-timeout/` use `ping` for out-of-band reachability testing when SSH itself is the thing failing; omitting this would silently break that diagnostic path
- Everything else inbound: denied (Hetzner Cloud Firewalls default-deny)
- Outbound: unrestricted, matching UFW's default-allow-outbound — a Cloud Firewall only restricts traffic you explicitly add a rule for

Verify: `hcloud firewall describe dev-baseline-match`

### Recreating it for another server

For any newly-hardened server (after running `scripts/base.sh`), attach the same policy:

```sh
hcloud firewall create --name <server>-baseline-match
hcloud firewall add-rule <server>-baseline-match --direction in --protocol tcp  --port 22  --source-ips 0.0.0.0/0 --source-ips ::/0 --description "SSH"
hcloud firewall add-rule <server>-baseline-match --direction in --protocol tcp  --port 80  --source-ips 0.0.0.0/0 --source-ips ::/0 --description "HTTP"
hcloud firewall add-rule <server>-baseline-match --direction in --protocol tcp  --port 443 --source-ips 0.0.0.0/0 --source-ips ::/0 --description "HTTPS"
hcloud firewall add-rule <server>-baseline-match --direction in --protocol icmp            --source-ips 0.0.0.0/0 --source-ips ::/0 --description "ping diagnostics"
hcloud firewall apply-to-resource <server>-baseline-match --type server --server <server>
```

If a server opens ports beyond the baseline's 22/80/443 (e.g. WireGuard, via `scripts/wireguard.sh`), add matching rules here too. **This firewall does not auto-track UFW's rule file** — the two are maintained independently and can drift. Re-verify with `nc -zv` from an outside host after any change, the same way this was verified when first created.

## Server migration via snapshot

### Why snapshot-and-recreate, not resize

Hetzner Cloud lets you resize a running server to a different type, but only among types available in that server's *current* datacenter — confirmed via `hcloud server-type describe <type> -o json`, which reports per-location `available: true/false`; a type unavailable at the server's current location isn't offered for an in-place resize. Hetzner also doesn't support changing an existing server's location directly. If the type/price you want only exists elsewhere, the workaround is a snapshot: it captures the entire disk independent of location, and can boot a new server of any type in any location.

### General procedure

1. **Snapshot the source server** (live, no downtime — for data-consistency-sensitive workloads like a database, briefly quiescing writes first gives a cleaner snapshot, though Hetzner snapshots are crash-consistent and most databases recover fine from that alone):
   ```sh
   hcloud server create-image <server> --type snapshot --description "<server> pre-migration $(date +%F)"
   ```
2. Note the resulting image ID: `hcloud image list -t snapshot`.
3. **Create the new server from that snapshot**, in the target location/type:
   ```sh
   hcloud server create --name <server>-new --image <snapshot-id> --type <new-type> --location <new-location> --ssh-key <your-key-name>
   ```
4. **Attach a matching Hetzner Cloud Firewall** (see above) — a server created from a snapshot does not inherit the source server's firewall attachment.
5. **Verify before cutting over:** SSH in on the new IP, confirm services/containers came back up (rootless Docker's `systemctl --user enable`'d units + `loginctl enable-linger` should survive and restart cleanly, but check), confirm UFW/fail2ban/auditd are still active. Don't assume the disk image carried everything correctly — verify each service directly rather than trusting the snapshot did the right thing.
6. **Cut over:** update whatever points at the old IP (SSH config, etc. — outside this repo's scope; see the consuming project's own docs).
7. **Only after cutover is confirmed working, delete the old server** (`hcloud server delete <server>`). Keep it running until you're actually confident — the point of snapshot-and-recreate over an in-place change is that the old server is a free rollback path until you delete it.

### Worked example: dev → Helsinki `cx53`

Context: `dev` (Hetzner `cx43`, 8 shared cores / 16GB, `nbg1`) hit sustained memory pressure (~99% of its `user-1000.slice` `MemoryHigh` ceiling) from legitimate multi-window VS Code Remote-SSH + Salesforce/Apex tooling usage — not a leak, just real workload outgrowing the box. `cx53` (16 cores / 32GB) is the best-value upgrade in Hetzner's entire catalog (€34.99/mo — actually *better* €/GB than `cx43`'s own €18.49/mo) but is only orderable in Helsinki (`hel1`), not `nbg1` where `dev` currently lives — confirmed via `hcloud server-type describe cx53 -o json`, which reports `available: false` for both `nbg1` and `fsn1`, and `available: true` + `recommended: true` only for `hel1`. Both datacenters share the `eu-central` network zone, so no meaningful latency change is expected.

Full inventory of what's on `dev` (confirmed by direct inspection, not assumed — `docker ps -a`, `docker volume ls`, and checking whether Ollama/Netdata are containers or native services): the `wfmctrading` rootless-Docker stack (nginx, Laravel app, Postgres — currently the only *running* containers), several already-stopped containers/stacks from other projects (`bodego-postgres`, `turtley-db-1`, an old unused `ollama` container, `mailpit`) with their own named volumes, Ollama and Netdata as **native systemd services** (not containers), and the full `scripts/base.sh` + `scripts/dev.sh` hardening/tooling layers. No separate Hetzner Volumes are attached — everything lives on local disk, so a plain snapshot captures all of it regardless of location or running state.

**Drift check before relying on this procedure (2026-08-21):** verified against Hetzner's own docs, not assumed from training data. Their [Backups/Snapshots FAQ](https://docs.hetzner.com/cloud/servers/backups-snapshots/faq/) states explicitly: *"No, they are not location bound. You can use a Backup/Snapshot to create a new server in any location"* — confirmed via a table covering all six Hetzner locations. A separate "same network zone" note on that page concerns only where the snapshot's *underlying data is stored* for redundancy (e.g. a Falkenstein server's snapshot bytes are replicated to Helsinki/Nuremberg) — it does not restrict which location you can deploy a new server to. Server-type-per-location availability (`cx53` being `hel1`-only) was confirmed separately via the live API (`hcloud server-type describe cx53 -o json`), not the prose docs, which don't address it. `hcloud` CLI flag syntax (`create-image`, `server create --image/--type/--location/--ssh-key`, `firewall add-rule`/`apply-to-resource`) was confirmed both via `--help` output and by actually running the firewall-creation commands successfully against the live account. This is a general reminder to re-verify anything version- or account-specific before relying on it, rather than trusting a doc to still match reality.

**Does dev work need to stop?** For this migration specifically: no, and it's now even simpler than the general case above, because the decision was made to stop `wfmctrading`'s three running containers *before* snapshotting rather than mid-migration:

```sh
docker stop wfmctrading-postgres-1 wfmctrading-app-1 wfmctrading-nginx-1
```

(`stop`, not `down` — halts them cleanly without removing/recreating, so no risk of not knowing the exact `docker compose -f ... -f ...` flags originally used to start them.) With Postgres cleanly stopped before the snapshot, its on-disk data is already consistent — no `pg_dumpall`/restore dance, no post-snapshot rsync-the-deltas step. The new server boots with an already-clean copy and `docker start` on it just works. Everything else on `dev` (Ollama, Netdata, general SSH/VS Code use) never needed to pause — those are native services or stateless, not implicated by the snapshot-consistency concern at all.

**Steps:**

1. ```sh
   ssh dev 'docker stop wfmctrading-postgres-1 wfmctrading-app-1 wfmctrading-nginx-1'
   ```
   Done — confirmed via `docker ps -a` showing all three `Exited (0)`.
2. ```sh
   hcloud server create-image dev --type snapshot --description "dev pre-hel1-migration $(date +%F)"
   ```
3. ```sh
   hcloud image list -t snapshot   # note the new image ID
   hcloud server create --name dev-hel1 --image <snapshot-id> --type cx53 --location hel1 --ssh-key willard-mba15
   ```
4. Attach the firewall:
   ```sh
   hcloud firewall create --name dev-hel1-baseline-match
   hcloud firewall add-rule dev-hel1-baseline-match --direction in --protocol tcp  --port 22  --source-ips 0.0.0.0/0 --source-ips ::/0 --description "SSH"
   hcloud firewall add-rule dev-hel1-baseline-match --direction in --protocol tcp  --port 80  --source-ips 0.0.0.0/0 --source-ips ::/0 --description "HTTP"
   hcloud firewall add-rule dev-hel1-baseline-match --direction in --protocol tcp  --port 443 --source-ips 0.0.0.0/0 --source-ips ::/0 --description "HTTPS"
   hcloud firewall add-rule dev-hel1-baseline-match --direction in --protocol icmp            --source-ips 0.0.0.0/0 --source-ips ::/0 --description "ping diagnostics"
   hcloud firewall apply-to-resource dev-hel1-baseline-match --type server --server dev-hel1
   ```
5. Get the new server's IP: `hcloud server ip dev-hel1`.
6. Verify against the new IP directly (not the `dev` alias yet): `ssh -o IdentityFile=~/.ssh/willard-mba15 willard@<new-ip>`. Confirm `docker ps -a` shows the three `wfmctrading` containers present, `docker start wfmctrading-postgres-1 wfmctrading-app-1 wfmctrading-nginx-1` brings them up healthy, and a VS Code Remote-SSH connection to the new IP works. Also spot-check UFW/fail2ban/auditd are still active on the new box — the disk image should carry them, but verify each directly rather than assuming the image was faithful.
7. Once verified: update `~/.ssh/config.local`'s `Host dev dev-*` `HostName` to the new IP. This file lives outside the `dotfiles` git repo — a private, untracked edit, nothing to commit.
8. Confirm `dotfiles`' own `check-dev`/`recon` tooling works against the `dev` alias now pointing at the new server (they key off the SSH alias, not the IP, so this should need no code changes — just confirm).
9. Only once confident: `hcloud server delete dev` (the old `nbg1` `cx43`) and, if desired, `hcloud firewall delete dev-baseline-match` (the old firewall, now unattached). Until this step, the old server — containers stopped but otherwise intact — is a free rollback path.

**Status: containers stopped, snapshot not yet taken.** Pending the go-ahead for step 2 onward. See the `dotfiles` repo's `ssh-vm-banner-timeout/` for `dev`'s incident history and existing recovery tooling.
