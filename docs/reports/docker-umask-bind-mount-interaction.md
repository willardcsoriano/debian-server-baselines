# Baseline hardening × Docker bind mounts: an unintended permission interaction

## Overview

A hardened host running `debian-server-baseline` exposes a latent permission bug in any Docker workflow that bind-mounts host source into a container and runs the container process as a non-root user with a UID different from the host owner. The hardening step at `debian-server-baseline.sh` line 485 sets `UMASK 027` in `/etc/login.defs`; Debian's default `USERGROUPS_ENAB yes` collapses that to an effective umask of `0007` for normal users. New files in the developer's home tree are created mode `660`, directories mode `770`, with no permissions for "other". Containers whose service user does not have a UID matching the host owner are "other" to the bind-mounted tree and receive `EACCES` on every read. The behavior is correct given the policy; it is the silent surprise that warrants documentation. This report describes the failure mode observed on `acme`, the workaround applied downstream, and what `debian-server-baseline` could add to flag the interaction for future users.

## Table of Contents

- [Overview](#overview)
- [Symptom](#symptom)
- [Root cause: a three-way collision](#root-cause-a-three-way-collision)
- [Why it surfaces specifically on a hardened box](#why-it-surfaces-specifically-on-a-hardened-box)
- [Workaround applied downstream](#workaround-applied-downstream)
- [What `debian-server-baseline` could add](#what-debian-server-baseline-could-add)
- [Appendix: reproducer](#appendix-reproducer)
- [References](#references)

## Symptom

A standard Laravel-in-Docker dev stack on a hardened VPS returned `404 Not Found` for every URL, including the static `/admin` and `/login` paths handled by the framework's front controller.

The `nginx` container's logs showed the cause:

```
[crit] stat() "/var/www/html/public/login" failed (13: Permission denied)
[crit] realpath() "/var/www/html/public" failed (13: Permission denied)
```

The PHP-FPM container at the same bind mount was unaffected. Only `nginx` could not traverse the document root.

## Root cause: a three-way collision

The bug requires three independent design choices to intersect. Two of them are part of the hardening baseline and the project's own Docker build; the third is the upstream `nginx:1.27-alpine` image used as-is.

| Piece | Stock Debian / stock setup | Hardened machine (cause of breakage) |
|---|---|---|
| Host umask | `0022` — new files `644`, new dirs `755`. "Other" can read everything. | `0007` — new files `660`, new dirs `770`. "Other" gets nothing. Produced by `debian-server-baseline.sh:485` (`UMASK 027` in `/etc/login.defs`) collapsed via Debian's `USERGROUPS_ENAB yes`. |
| PHP-FPM container UID | `www-data` is UID 33 — "other" to host files. | `www-data` is remapped to UID 1000 in the project's `Dockerfile` via `usermod -u 1000 www-data`. Matches host owner, so PHP-FPM is "owner" on every file. |
| Nginx container UID | `nginx` is UID 101 inside `nginx:1.27-alpine` — "other" to host files. | Same — the upstream image was pulled with no UID remap. Works fine on a stock-umask host (`644`/`755` is world-readable). Fails under `umask 0007` because "other" has no permissions. |

The diagonal in the pairwise matrix is the failure mode:

| Combination | Outcome |
|---|---|
| umask `022` + nginx UID 101 | Works — files world-readable. |
| umask `007` + nginx UID 1000 | Works — owner permissions. |
| **umask `007` + nginx UID 101** | **Breaks — `EACCES` on bind mount.** |
| umask `022` + nginx UID 1000 | Works. |

## Why it surfaces specifically on a hardened box

The hardening is not the bug. The hardening makes a pre-existing UID asymmetry visible. On a stock-umask Debian host, the same compose stack would have served traffic correctly because the source tree would have been world-readable. The `nginx` service was relying on that ambient world-readability without anyone having declared the dependency.

The interaction is not limited to nginx. Any container that:

- bind-mounts a host directory, and
- runs its service process as a non-root user, and
- has that user's UID mismatched with the host owner

will hit the same failure on a `debian-server-baseline` host. Common candidates include `node`, `python`, `ruby`, `golang`, `caddy`, `traefik`, and most database images when used with host-mounted data directories.

## Workaround applied downstream

The `acme` project resolved this by mirroring the UID-remap pattern its `app` Dockerfile already used for `www-data`. A small `docker/nginx/Dockerfile` was added:

```dockerfile
FROM nginx:1.27-alpine

ARG UID=1000
ARG GID=1000

RUN apk add --no-cache --virtual .uid-fix shadow \
 && groupmod -g "${GID}" nginx \
 && usermod -u "${UID}" -g "${GID}" nginx \
 && find / -xdev \( -uid 101 -o -gid 101 \) -exec chown -h "${UID}:${GID}" {} + 2>/dev/null || true \
 && apk del .uid-fix
```

`docker-compose.yml` was switched from `image: nginx:1.27-alpine` to a local `build:` referencing this Dockerfile, with `UID`/`GID` build args defaulted to `1000` and overridable from the host environment.

After rebuild, `curl -sI http://localhost:8080/` returned `200 OK`. The hardening (`umask 0007`) was kept untouched.

## What `debian-server-baseline` could add

The hardening choice is correct and should not be changed. The gap is documentation: a downstream user with a Docker workflow has no warning that this class of bug will appear, and the diagnostic path (nginx `EACCES`, no obvious connection to `login.defs`) is long.

Suggested additions, in increasing order of intervention:

1. **A note in `README.md` or `WALKTHROUGH.md`** under a "Known interactions" or "After install" section, calling out that `UMASK 027` + `USERGROUPS_ENAB yes` produces an effective `umask 0007` for normal users, and that this breaks any Docker bind-mount workflow where the container service user has a UID different from the host owner. One paragraph plus a one-line workaround pointer.

2. **A reference example** under a `docs/` or `examples/` path showing the minimal UID-remap pattern (the `apk add shadow && usermod + groupmod + chown` snippet above, plus the Debian-based equivalent). The two flavors of base image differ enough — alpine needs `shadow`, debian-based images already have `usermod` — that an example pays for itself.

3. **An optional `DRIFTCHECK.md` entry** that lints for `/etc/login.defs` `UMASK` value versus actual effective `umask` of the sudo user, flagging the `USERGROUPS_ENAB` collapse so operators understand what their users will actually see.

4. **A `debian-server-baseline.sh` summary line** in the post-install report noting the effective umask the sudo user will get, not just the policy value written. Right now the summary says "Password aging + umask 027 ..."; the value `027` is technically accurate but operationally misleading because the user's shells will report `0007`.

The first item is probably enough on its own. The remaining items are nice-to-have if the project wants to make the interaction explicit at every layer the operator might inspect.

## Appendix: reproducer

The interaction can be reproduced in any directory on a hardened host:

```bash
# As the sudo user on a baseline'd box:
umask                                              # prints 0007
mkdir /tmp/repro && touch /tmp/repro/file
stat -c '%a %U:%G %n' /tmp/repro /tmp/repro/file   # 770 / 660

# An "other" identity (any UID not the owner and not in the owner's group)
# cannot read the file. Containers using upstream images that ship a
# service user with UID 33 / 101 / etc. fall into that "other" bucket
# when the host owner is UID 1000.
```

## References

- `debian-server-baseline.sh:485` — `set_login_def UMASK 027`
- `/etc/login.defs` — `USERGROUPS_ENAB yes` (Debian default, unchanged by `debian-server-baseline.sh`)
- `login.defs(5)` — documents the `USERGROUPS_ENAB` collapse behavior
- Downstream project Dockerfile (`acme/Dockerfile`) — pre-existing `www-data` remap that demonstrates the correct pattern
- Downstream nginx Dockerfile (`acme/docker/nginx/Dockerfile`) — the new remap that closes the gap
