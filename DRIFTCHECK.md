# DRIFTCHECK.md

## Overview

Project-specific drift runbook for `debian-baseline`. Run this whenever you return to the repo after an absence, or when asked to touch any install section. It covers the four components most likely to have changed: Docker, Netdata, Lynis, and the Debian target version. For each one, fetch the canonical URL, compare against the current script, and report any discrepancies before making changes. General drift methodology lives in `DRIFT.md`; this file is the executable checklist for this repo specifically.

## Table of Contents

- [Overview](#overview)
- [How to invoke](#how-to-invoke)
- [1. Docker (section 20) — High risk](#1-docker-section-20-high-risk)
- [2. Netdata (section 11) — Medium risk](#2-netdata-section-11-medium-risk)
- [3. Lynis (section 18) — Medium risk](#3-lynis-section-18-medium-risk)
- [4. Debian target version — Medium risk](#4-debian-target-version-medium-risk)
- [5. Quick sanity checks (no fetch required)](#5-quick-sanity-checks-no-fetch-required)
- [Reporting format](#reporting-format)

## How to invoke

Tell the agent: `check @DRIFTCHECK.md` or `run the drift check`. The agent fetches each URL below, diffs the findings against `baseline.sh`, and reports what has changed or needs updating. Do not skip a section because it "looks fine" — the point is to verify, not assume.

---

## 1. Docker (section 20) — High risk

**Why:** Docker changes its apt repo format, package names, and rootless install procedure roughly annually.

**Fetch:**
- https://docs.docker.com/engine/install/debian/
- https://docs.docker.com/engine/security/rootless/

**Check against `baseline.sh` section 20:**
- GPG key URL (`curl -fsSL https://download.docker.com/linux/debian/gpg`)
- Sources file format and content (deb822 block: `Types`, `URIs`, `Suites`, `Components`, `Architectures`, `Signed-By`)
- Package list: `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras uidmap`
- Setup command: `dockerd-rootless-setuptool.sh install`
- Socket path: `unix:///run/user/$(id -u)/docker.sock`
- Whether `docker-ce-rootless-extras` is still the package providing the setup tool

**Report:** any package renamed, any URL changed, any flag removed or added, any new prerequisite.

---

## 2. Netdata (section 11) — Medium risk

**Why:** The kickstart script URL and its flags have changed before. `--dont-wait` and `--noupdate` were renamed; the current flags are `--non-interactive --no-updates --disable-telemetry`.

**Fetch:**
- https://learn.netdata.cloud/docs/netdata-agent/installation/linux

**Check against `baseline.sh` section 11:**
- Kickstart URL (`https://get.netdata.cloud/kickstart.sh` — note: NOT `my-netdata.io`, which 307-redirects)
- Current flag names for non-interactive, no-updates, disable-telemetry
- Whether the install path `/opt/netdata/bin/netdata` is still correct for skip-detection

**Report:** any flag renamed or removed, any URL changed, any new recommended install method.

---

## 3. Lynis (section 18) — Medium risk

**Why:** CISOfy controls the apt repo; the GPG key URL and sources format could change.

**Fetch:**
- https://packages.cisofy.com/community/lynis/deb/

**Check against `baseline.sh` section 18:**
- GPG key URL (`https://packages.cisofy.com/keys/cisofy-software-public.key`)
- Sources list entry (`https://packages.cisofy.com/community/lynis/deb/ stable main`)
- Whether `lynis audit system --quiet --nocolors` flags are still current
- Hardening index log line regex: `Hardening index : \[\K\d+`

**Report:** any key URL changed, any repo URL changed, any flag renamed.

---

## 4. Debian target version — Medium risk

**Why:** The script enforces `VERSION_ID -ge 13`. When Debian 14 (Forky) ships as stable, the script needs a decision: support 14, support both, or stay 13-only.

**Fetch:**
- https://www.debian.org/releases/

**Check:**
- Is Debian 13 (Trixie) still current stable?
- If a newer stable exists, note it and flag for a version policy decision
- Check `VERSION_CODENAME` usage in the Docker sources block — `trixie` is hardcoded via `${VERSION_CODENAME}`; confirm the new release codename if applicable

**Report:** whether a new Debian stable has shipped and what the version policy decision should be.

---

## 5. Quick sanity checks (no fetch required)

Run these locally — they catch internal drift without network calls:

```bash
# Syntax
bash -n baseline.sh

# Static analysis
shellcheck baseline.sh

# Section count matches headers
grep -c 'section "' baseline.sh
grep -oP '\d+(?=/)' baseline.sh | sort -n | uniq | tail -1   # highest N in N/20

# Summary block matches section count
grep -c '✓\|✗\|–' baseline.sh | tail -1
```

---

## Reporting format

After running all checks, report:

```
DRIFTCHECK — <date>

Docker:  [OK | CHANGED — <what changed>]
Netdata: [OK | CHANGED — <what changed>]
Lynis:   [OK | CHANGED — <what changed>]
Debian:  [OK | NEW STABLE: <version> — decision needed]
Local:   [OK | <shellcheck findings>]
```

If anything is CHANGED, propose the diff to `baseline.sh` before making it.
