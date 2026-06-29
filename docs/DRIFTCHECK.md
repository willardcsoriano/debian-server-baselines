# DRIFTCHECK.md

## Overview

Project-specific drift runbook for `debian-server-baseline`. Run this whenever you return to the repo after an absence, or when asked to touch any install section. It covers the four components most likely to have changed: Docker (lives in **two** role scripts now — see Section 1), Netdata, Lynis, and the Debian target version. For each one, fetch the canonical URL, compare against the current script, and report any discrepancies before making changes. General drift methodology lives in `DRIFT.md`; this file is the executable checklist for this repo specifically.

## Table of Contents

- [Overview](#overview)
- [How to invoke](#how-to-invoke)
- [1. Docker (prod-server.sh + dev-server.sh, both section 1) — High risk](#1-docker-prod-serversh-dev-serversh-both-section-1-high-risk)
- [2. Netdata (debian-server-baseline.sh, section 11) — Medium risk](#2-netdata-debian-server-baselinesh-section-11-medium-risk)
- [3. Lynis (debian-server-baseline.sh, section 18) — Medium risk](#3-lynis-debian-server-baselinesh-section-18-medium-risk)
- [4. Debian target version — Medium risk](#4-debian-target-version-medium-risk)
- [5. Gemini CLI (dev-server.sh, section 8) — Medium risk](#5-gemini-cli-dev-serversh-section-8-medium-risk)
- [6. Quick sanity checks (no fetch required)](#6-quick-sanity-checks-no-fetch-required)
- [Reporting format](#reporting-format)

## How to invoke

Tell the agent: `check @DRIFTCHECK.md` or `run the drift check`. The agent fetches each URL below, diffs the findings against the relevant script(s), and reports what has changed or needs updating. Do not skip a section because it "looks fine" — the point is to verify, not assume.

---

## 1. Docker (prod-server.sh + dev-server.sh, both section 1) — High risk

**Why:** Docker changes its apt repo format, package names, and rootless install procedure roughly annually. The rootless Docker install is **duplicated** between `prod-server.sh` (section 1/1) and `dev-server.sh` (section 1/5) — the repo's curl-per-script install model precludes a shared `lib/`. Both copies must be edited in lockstep.

**Fetch:**
- https://docs.docker.com/engine/install/debian/
- https://docs.docker.com/engine/security/rootless/

**Check against both `prod-server.sh` section 1 and `dev-server.sh` section 1:**
- GPG key URL (`curl -fsSL https://download.docker.com/linux/debian/gpg`)
- Sources file format and content (deb822 block: `Types`, `URIs`, `Suites`, `Components`, `Architectures`, `Signed-By`)
- Package list: `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras uidmap`
- Setup command: `dockerd-rootless-setuptool.sh install`
- Socket path: `unix:///run/user/$(id -u)/docker.sock`
- Whether `docker-ce-rootless-extras` is still the package providing the setup tool
- **Drift between the two copies.** `diff <(sed -n '/^# DRIFT:/,/^pass /p' prod-server.sh) <(sed -n '/^# DRIFT:/,/^pass /p' dev-server.sh)` should be empty modulo indentation. If it isn't, someone updated one and forgot the other.

**Report:** any package renamed, any URL changed, any flag removed or added, any new prerequisite. If a change is needed, propose it for **both** scripts in the same commit.

---

## 2. Netdata (debian-server-baseline.sh, section 11) — Medium risk

**Why:** The kickstart script URL and its flags have changed before. `--dont-wait` and `--noupdate` were renamed; the current flags are `--non-interactive --no-updates --disable-telemetry`.

**Fetch:**
- https://learn.netdata.cloud/docs/netdata-agent/installation/linux

**Check against `debian-server-baseline.sh` section 11:**
- Kickstart URL (`https://get.netdata.cloud/kickstart.sh` — note: NOT `my-netdata.io`, which 307-redirects)
- Current flag names for non-interactive, no-updates, disable-telemetry
- Whether the install path `/opt/netdata/bin/netdata` is still correct for skip-detection

**Report:** any flag renamed or removed, any URL changed, any new recommended install method.

---

## 3. Lynis (debian-server-baseline.sh, section 18) — Medium risk

**Why:** CISOfy controls the apt repo; the GPG key URL and sources format could change.

**Fetch:**
- https://packages.cisofy.com/community/lynis/deb/

**Check against `debian-server-baseline.sh` section 18:**
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

## 5. Gemini CLI (dev-server.sh, section 8) — Medium risk

**Why:** Google ships no native installer or standalone binary — the dev-server install depends on the GitHub release artifact `gemini-cli-bundle.zip` and its internal layout. Both the asset name and the bundle entrypoint (`bundle/gemini.js`) have changed shape before (single-file → code-split), and the Node floor can rise. Any of these silently breaks the launcher.

**Fetch:**
- https://github.com/google-gemini/gemini-cli
- https://github.com/google-gemini/gemini-cli/releases

**Check against `dev-server.sh` section 8:**
- Release still ships a single asset named `gemini-cli-bundle.zip` (the `grep -oP '…gemini-cli-bundle\.zip'` against `/releases/latest` must still match).
- Bundle's bin entry is still `gemini.js` (the `find -maxdepth 2 -name gemini.js` locator) — confirm via `package.json#bin` (`bundle/gemini.js`).
- `engines.node` floor (currently `>=20`) is still satisfied by the nvm Node LTS from section 2.
- Whether Google has started publishing a real native binary or a checksum file (would let us drop the node-launcher shim / add sha256 verification).

**Report:** any asset rename, entrypoint move, Node floor bump, or new native-install path. If the asset/entrypoint changed, propose the fix to `dev-server.sh` section 8.

---

## 6. Quick sanity checks (no fetch required)

Run these locally — they catch internal drift without network calls:

```bash
# Syntax
bash -n debian-server-baseline.sh prod-server.sh dev-server.sh syslog-baseline.sh wireguard-baseline.sh

# Static analysis
shellcheck debian-server-baseline.sh prod-server.sh dev-server.sh syslog-baseline.sh wireguard-baseline.sh

# Base script section count (should still be 20)
grep -c 'section "' debian-server-baseline.sh
grep -oP '\d+(?=/)' debian-server-baseline.sh | sort -n | uniq | tail -1   # highest N in N/20

# dev-server section count (should still be 8)
grep -c 'section "' dev-server.sh
grep -oP '\d+(?=/8)' dev-server.sh | sort -n | uniq | tail -1              # highest N in N/8

# Summary block matches section count
grep -c '✓\|✗\|–' debian-server-baseline.sh | tail -1
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

If anything is CHANGED, propose the diff to the relevant script(s) before making it. Docker changes must land in **both** `prod-server.sh` and `dev-server.sh` in the same commit.
