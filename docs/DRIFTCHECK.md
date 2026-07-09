# DRIFTCHECK.md

## Overview

Project-specific drift runbook for `base-server`. Run this whenever you return to the repo after an absence, or when asked to touch any install section. It covers the components most likely to have changed: Docker (lives in **two** role scripts now — see Section 1), the Bitwarden Secrets Manager CLI (also two role scripts — see Section 2), Netdata, Lynis, and the Debian target version. For each one, fetch the canonical URL, compare against the current script, and report any discrepancies before making changes. General drift methodology lives in `DRIFT.md`; this file is the executable checklist for this repo specifically.

## Table of Contents

- [Overview](#overview)
- [How to invoke](#how-to-invoke)
- [1. Docker (prod-server.sh + dev-server.sh, both section 1) — High risk](#1-docker-prod-serversh-dev-serversh-both-section-1-high-risk)
- [2. Bitwarden Secrets Manager CLI (prod-server.sh section 2/2 + dev-server.sh section 7/8) — Medium risk](#2-bitwarden-secrets-manager-cli-prod-serversh-section-22-dev-serversh-section-78-medium-risk)
- [3. Netdata (base-server.sh, section 11) — Medium risk](#3-netdata-base-serversh-section-11-medium-risk)
- [4. Lynis (base-server.sh, section 18) — Medium risk](#4-lynis-base-serversh-section-18-medium-risk)
- [5. Debian target version — Medium risk](#5-debian-target-version-medium-risk)
- [6. Antigravity CLI (dev-server.sh, section 8) — High risk](#6-antigravity-cli-dev-serversh-section-8-high-risk)
- [7. Quick sanity checks (no fetch required)](#7-quick-sanity-checks-no-fetch-required)
- [Reporting format](#reporting-format)

## How to invoke

Tell the agent: `check @DRIFTCHECK.md` or `run the drift check`. The agent fetches each URL below, diffs the findings against the relevant script(s), and reports what has changed or needs updating. Do not skip a section because it "looks fine" — the point is to verify, not assume.

---

## 1. Docker (prod-server.sh + dev-server.sh, both section 1) — High risk

**Why:** Docker changes its apt repo format, package names, and rootless install procedure roughly annually. The rootless Docker install is **duplicated** between `prod-server.sh` (section 1/2) and `dev-server.sh` (section 1/8) — the repo's curl-per-script install model precludes a shared `lib/`. Both copies must be edited in lockstep.

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

## 2. Bitwarden Secrets Manager CLI (prod-server.sh section 2/2 + dev-server.sh section 7/8) — Medium risk

**Why:** `bws` ships as prebuilt zips on GitHub releases under `bitwarden/sdk-sm`, sha256-verified against a sibling checksums file. Tag format, asset naming, or checksum filename could shift. The install logic is **duplicated** between `prod-server.sh` (section 2/2) and `dev-server.sh` (section 7/8) — same curl-per-script constraint as Docker. The surrounding scaffolding differs (prod-server.sh sets up `~/.local/bin`/PATH and `unzip` inline since it lacks dev-server.sh's earlier sections that already do this), but the `# DRIFT:` comment and the `if command -v bws ... fi` install logic must stay identical.

**Fetch:**
- https://bitwarden.com/help/secrets-manager-cli/
- https://github.com/bitwarden/sdk-sm/releases

**Check against both `prod-server.sh` section 2/2 and `dev-server.sh` section 7/8:**
- Tag format (`bws-vX.Y.Z`) resolved via the GitHub releases API query
- Asset naming (`bws-<arch>-unknown-linux-gnu-<version>.zip`) and arch mapping (amd64 → `x86_64-unknown-linux-gnu`, arm64 → `aarch64-unknown-linux-gnu`)
- Checksum file naming (`bws-sha256-checksums-<version>.txt`) and that sha256 verification still gates the install before `unzip`
- Whether Bitwarden has published an official install script that would replace this manual zip/checksum dance
- Whether `bws run --project-id <id> -- <cmd>` (the no-disk secrets-injection pattern documented in README.md) is still current syntax
- **Drift in the DRIFT comment.** `diff <(sed -n '/^# DRIFT: bws is published/,/^# Last verified:/p' prod-server.sh) <(sed -n '/^# DRIFT: bws is published/,/^# Last verified:/p' dev-server.sh)` should be empty except the `NOTE:` line's cross-referenced section number (`2/2` vs `7/8` is expected, not drift).
- **Drift in the install logic.** `diff <(sed -n '/^if command -v bws/,/^fi$/p' prod-server.sh) <(sed -n '/^if command -v bws/,/^fi$/p' dev-server.sh)` should be byte-identical (empty diff). If it isn't, someone updated one copy's install logic and forgot the other.

**Report:** any tag/asset/checksum naming change, any new official install method, any `bws run` syntax change, or drift between the two copies. If a change is needed, propose it for **both** scripts in the same commit.

---

## 3. Netdata (base-server.sh, section 11) — Medium risk

**Why:** The kickstart script URL and its flags have changed before. `--dont-wait` and `--noupdate` were renamed; the current flags are `--non-interactive --no-updates --disable-telemetry`.

**Fetch:**
- https://learn.netdata.cloud/docs/netdata-agent/installation/linux

**Check against `base-server.sh` section 11:**
- Kickstart URL (`https://get.netdata.cloud/kickstart.sh` — note: NOT `my-netdata.io`, which 307-redirects)
- Current flag names for non-interactive, no-updates, disable-telemetry
- Whether the install path `/opt/netdata/bin/netdata` is still correct for skip-detection

**Report:** any flag renamed or removed, any URL changed, any new recommended install method.

---

## 4. Lynis (base-server.sh, section 18) — Medium risk

**Why:** CISOfy controls the apt repo; the GPG key URL and sources format could change.

**Fetch:**
- https://packages.cisofy.com/community/lynis/deb/

**Check against `base-server.sh` section 18:**
- GPG key URL (`https://packages.cisofy.com/keys/cisofy-software-public.key`)
- Sources list entry (`https://packages.cisofy.com/community/lynis/deb/ stable main`)
- Whether `lynis audit system --quiet --nocolors` flags are still current
- Hardening index log line regex: `Hardening index : \[\K\d+`

**Report:** any key URL changed, any repo URL changed, any flag renamed.

---

## 5. Debian target version — Medium risk

**Why:** The script enforces `VERSION_ID -ge 13`. When Debian 14 (Forky) ships as stable, the script needs a decision: support 14, support both, or stay 13-only.

**Fetch:**
- https://www.debian.org/releases/

**Check:**
- Is Debian 13 (Trixie) still current stable?
- If a newer stable exists, note it and flag for a version policy decision
- Check `VERSION_CODENAME` usage in the Docker sources block — `trixie` is hardcoded via `${VERSION_CODENAME}`; confirm the new release codename if applicable

**Report:** whether a new Debian stable has shipped and what the version policy decision should be.

---

## 6. Antigravity CLI (dev-server.sh, section 8) — High risk

**Why:** New, fast-moving Google product — it superseded Gemini CLI on 2026-06-18. The install pipes Google's hosted installer (`antigravity.google/cli/install.sh`) to `bash`; the installer URL, the binary name (`agy`), the install path (`~/.local/bin/agy`), and the SSH auth flow could all shift while the product stabilizes. A rename or a changed installer endpoint silently breaks the section.

**Fetch:**
- https://antigravity.google/docs/cli-install
- https://github.com/google-antigravity/antigravity-cli

**Check against `dev-server.sh` section 8:**
- Install command is still `curl -fsSL https://antigravity.google/cli/install.sh | bash` (endpoint unchanged, still SHA512-verifies the download against its manifest).
- Binary is still named `agy` and lands in `~/.local/bin` (the `command -v agy` idempotency guard and the summary line depend on it).
- Still a native, Node-independent binary — no reintroduced npm/Node dependency.
- Whether a version-pinning env var has appeared (the installer currently always fetches latest — worth pinning if it does).
- Whether Gemini CLI has been fully retired or the `agy plugin import gemini` migration path has changed.

**Report:** any installer-URL change, binary rename, install-path move, new Node dependency, or new pinning option. If anything changed, propose the fix to `dev-server.sh` section 8.

---

## 7. Quick sanity checks (no fetch required)

Run these locally — they catch internal drift without network calls:

```bash
# Syntax
bash -n base-server.sh prod-server.sh dev-server.sh syslog-baseline.sh wireguard-baseline.sh

# Static analysis
shellcheck base-server.sh prod-server.sh dev-server.sh syslog-baseline.sh wireguard-baseline.sh

# Base script section count (should still be 20)
grep -c 'section "' base-server.sh
grep -oP '\d+(?=/)' base-server.sh | sort -n | uniq | tail -1   # highest N in N/20

# prod-server section count (should still be 2)
grep -c 'section "' prod-server.sh
grep -oP '\d+(?=/2)' prod-server.sh | sort -n | uniq | tail -1             # highest N in N/2

# dev-server section count (should still be 8)
grep -c 'section "' dev-server.sh
grep -oP '\d+(?=/8)' dev-server.sh | sort -n | uniq | tail -1              # highest N in N/8

# Summary block matches section count
grep -c '✓\|✗\|–' base-server.sh | tail -1
```

---

## Reporting format

After running all checks, report:

```
DRIFTCHECK — <date>

Docker:  [OK | CHANGED — <what changed>]
bws:     [OK | CHANGED — <what changed>]
Netdata: [OK | CHANGED — <what changed>]
Lynis:   [OK | CHANGED — <what changed>]
Debian:  [OK | NEW STABLE: <version> — decision needed]
Local:   [OK | <shellcheck findings>]
```

If anything is CHANGED, propose the diff to the relevant script(s) before making it. Docker and bws changes must land in **both** `prod-server.sh` and `dev-server.sh` in the same commit.
