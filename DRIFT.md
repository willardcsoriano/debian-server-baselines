# AI Drift Mitigation

## Table of Contents

- [The Problem](#the-problem)
- [Symptoms](#symptoms)
- [Quick Checklist (the 80/20)](#quick-checklist-the-8020)
- [Strategies, in Order of Leverage](#strategies-in-order-of-leverage)
  - [1. Pin versions in AI instructions](#1-pin-versions-in-ai-instructions)
    - [The lockfile is the authoritative pin](#the-lockfile-is-the-authoritative-pin)
    - [Today's date belongs in the file](#todays-date-belongs-in-the-file)
  - [2. Document version-specific gotchas](#2-document-version-specific-gotchas)
  - [3. Vendor documentation as local git submodules](#3-vendor-documentation-as-local-git-submodules)
    - [Machine-readable signals are stronger than prose](#machine-readable-signals-are-stronger-than-prose)
  - [4. Install a documentation MCP server](#4-install-a-documentation-mcp-server)
  - [5. Canonical URLs as WebFetch fallback](#5-canonical-urls-as-webfetch-fallback)
  - [6. Verify before generating, scoped to high-risk surfaces](#6-verify-before-generating-scoped-to-high-risk-surfaces)
    - [Test-as-verification](#test-as-verification)
  - [7. Choose AI-fluent stacks where it matters](#7-choose-ai-fluent-stacks-where-it-matters)
    - [When AI is the primary author, this is load-bearing](#when-ai-is-the-primary-author-this-is-load-bearing)
  - [8. Enforce drift at the build, not only at the agent](#8-enforce-drift-at-the-build-not-only-at-the-agent)
  - [9. Treat the project itself as a moving target](#9-treat-the-project-itself-as-a-moving-target)
  - [10. Know what doesn't drift](#10-know-what-doesnt-drift)
  - [11. Infrastructure and configuration drift](#11-infrastructure-and-configuration-drift)
  - [12. Prune the instruction file — gotchas decay](#12-prune-the-instruction-file-gotchas-decay)
- [Universal `CLAUDE.md` template](#universal-claudemd-template)
- [Common AI Traps by Ecosystem](#common-ai-traps-by-ecosystem)
  - [JavaScript / TypeScript](#javascript-typescript)
  - [PHP](#php)
  - [Python](#python)
  - [Go](#go)
  - [Ruby](#ruby)
  - [Shell / Bash](#shell-bash)
  - [Infrastructure / IaC](#infrastructure-iac)
  - [Systems / Linux](#systems-linux)
  - [General](#general)
- [Tool-Specific Notes](#tool-specific-notes)
  - [Claude Code](#claude-code)
  - [Cursor](#cursor)
  - [Aider](#aider)
  - [GitHub Copilot / Copilot Chat](#github-copilot-copilot-chat)
  - [Cross-Tool Convention: `AGENTS.md`](#cross-tool-convention-agentsmd)
- [Maintenance Rhythm](#maintenance-rhythm)
- [When This Is Overkill](#when-this-is-overkill)
- [The Underlying Mindset](#the-underlying-mindset)

## The Problem

Large language models are trained against a snapshot of the world. By the time a model is in active use, the libraries and frameworks in a given project will almost certainly have moved beyond that snapshot. The model continues to confidently emit code that was correct at training time but is now incorrect: deleted files, renamed APIs, removed configuration keys, deprecated syntax, dead import paths.

This causes **silent regression** in AI-assisted work. The model has no awareness of its own staleness. It produces code that compiles in its mental model, references files that no longer exist, and uses APIs renamed two majors ago. Accepting such a suggestion without verification ships a defect.

The remedy is not to wait for newer models; new models continue to lag the bleeding edge by months. The remedy is **systems that keep the model honest** on every interaction with the code.

---

## Symptoms

The following behaviors are diagnostic of training-data lag rather than legitimate, deliberate choice by the agent:

- The agent edits or references a file that **does not exist** in the repository.
- The agent uses a method, property, or option that produces an "undefined" or "method does not exist" error.
- The agent suggests an import path that returns a 404 on the registry.
- The agent uses syntax that produces deprecation warnings or compilation errors.
- The agent asserts confidently that configuration belongs in file X, when the project's configuration in fact lives in file Y.
- The agent proposes installation of a library under a name that no longer exists (renamed or forked).
- The agent proposes installation of a library, a CLI flag, or a configuration key that **has never existed at all** — a confident hallucination as distinct from a stale reference. The remedy is the same (verify), but the failure mode is worth naming separately, because the agent's certainty is at its highest here.
- The agent references documentation URLs that redirect or return 404.
- The agent references **internal** files, symbols, or import paths that were renamed or removed within the project itself, not within an upstream library.

When such symptoms appear, one-off prompt corrections should **not** be used as the remedy. The system itself should be fixed so that drift does not recur in the next session.

---

## Quick Checklist (the 80/20)

For any project in which AI fluency is consequential:

- [ ] **Pin versions in `CLAUDE.md` or `AGENTS.md`** with exact framework and major library versions.
- [ ] **Treat the lockfile as the source of truth.** The pin in `CLAUDE.md` is the human-readable mirror; the agent should diff the two at session start and surface drift between them.
- [ ] **Record today's date in `CLAUDE.md`.** Naming the cutoff–now gap explicitly improves freshness behavior at low cost.
- [ ] **Enumerate version-specific gotchas** (the "do not generate X; the API moved to Y" rules).
- [ ] **Prefer machine-readable signals over prose** where available — type definitions (`.d.ts`, `.pyi`), generated stubs, and lockfiles reflect the installed code, while prose docs lag it.
- [ ] **Vendor documentation as git submodules** pinned to the matching version branch.
- [ ] **Install a documentation MCP server** (Context7 or equivalent) for fresh on-demand lookups.
- [ ] **Maintain a canonical URL list** so WebFetch operates as fallback rather than as guessing.
- [ ] **Document a `verify-before-generate` rule** for the agent to follow, scoped to high-risk surfaces (new files, public API signatures, config keys, install commands, framework-specific paths).
- [ ] **Enforce drift at the build, not only at the agent.** Deprecation linters, codemods, and CI checks catch what the agent forgets to verify.
- [ ] **Ripgrep before referencing internal symbols.** Project-internal drift (renamed files, moved helpers) is as common as library drift.
- [ ] **Provide a `scripts/update-docs.sh`** to refresh vendored documentation.
- [ ] **Periodically run `git submodule update --remote`** as part of project maintenance.
- [ ] **Know what doesn't drift.** POSIX shell syntax, TCP/IP, HTTP, SQL basics, and kernel sysctls are stable over decades. Applying verification overhead to stable surfaces adds friction without benefit. Scope verification to what actually moves.
- [ ] **Audit infrastructure and config as aggressively as code.** Terraform resource types, Ansible module names, Kubernetes API versions, Docker Compose syntax, and cloud provider CLI flags drift on the same timescale as libraries. They have no lockfile and no type system to catch the agent.
- [ ] **Prune gotchas, don't only add them.** A CLAUDE.md with 40 entries is worse than one with 10 load-bearing ones. Schedule periodic review: if a gotcha describes a bug that was fixed upstream, remove it.
- [ ] **Audit the instruction file itself.** CLAUDE.md ages. Canonical URLs move, workflows change, gotchas become stale, section references break. The file that guards against drift is not immune to drift.

---

## Strategies, in Order of Leverage

### 1. Pin versions in AI instructions

An AI agent reads one configuration file at session start. In Claude Code this is `CLAUDE.md`. In Cursor it is `.cursorrules` or `.cursor/rules/*.md`. In other tools the convention is increasingly `AGENTS.md`. That file should be the authoritative source of version information.

Representative snippet:

```markdown
## Stack (pinned)

- Laravel 13
- Livewire 4
- Filament 5
- Inertia 3
- Tailwind 4
- PHP 8.3+

## Rules for AI work

These libraries move quickly, and training data lags. Do not rely on
training data for any library listed above — verify against documentation
every session.
```

The mechanism is straightforward: the agent is required to acknowledge the version on every turn. It can no longer "default" to the version retained from training.

#### The lockfile is the authoritative pin

A version recorded in `CLAUDE.md` drifts from the project silently — a contributor bumps a minor, the documentation file does not get updated, and the agent now operates against a stated version that no longer matches the installed one. The remedy is to treat the **lockfile** (`package-lock.json`, `pnpm-lock.yaml`, `composer.lock`, `Pipfile.lock`, `go.sum`, `Cargo.lock`, `Gemfile.lock`) as the authoritative source. The pin in `CLAUDE.md` is the human-readable mirror; the agent should be instructed to diff the two at session start and surface any discrepancy before generating code.

Representative `CLAUDE.md` rule:

```markdown
At session start, read the lockfile entries for the libraries named
in "Stack (pinned)". If the lockfile version does not match the pin
in this file, report the discrepancy before proceeding. The lockfile
is authoritative; this file is a mirror that drifts.
```

#### Today's date belongs in the file

A single line — `Today is YYYY-MM-DD; your training cutoff is months earlier than this. Assume any library named below has moved.` — is a low-cost, high-leverage prime. Models behave noticeably differently when the cutoff–now gap is named in context than when it is not.

### 2. Document version-specific gotchas

Version pinning alone is insufficient. The agent has been *trained* on the wrong version and will revert to it under load — under long context, vague prompts, or complex tasks. Specific API changes must therefore be enumerated, so that the agent operates with explicit anti-patterns to avoid.

Template snippet:

```markdown
**Version gotchas — do not make these mistakes:**

- **Laravel 13:** middleware/exception/console config lives in
  `bootstrap/app.php`. Do NOT create `app/Http/Kernel.php` or
  `app/Console/Kernel.php` — those files were removed in v11.
- **Livewire 4:** v2 syntax like `wire:model.defer` is gone. Verify
  every attribute and lifecycle hook against the local docs.
- **Filament 5:** the Resource API has changed across every major
  (v2/v3/v4/v5). Read `docs/filament/docs/` before generating
  resource, schema, or panel code.
- **Vite only.** Never suggest Laravel Mix or `webpack.mix.js`.
- **Next.js App Router (v15+):** prefer Server Components by default.
  Do NOT use `getServerSideProps` / `getStaticProps` — those are
  Pages Router APIs.
```

Gotchas are discovered by:

1. **Running the install** and capturing the actual installed version from `composer show`, `npm list`, `pip show`, `cargo info`, or equivalent.
2. **Diffing against what the agent assumes** — the agent is queried for the version it expects, and the answer is compared.
3. **Skimming the official migration guide** for each major version jump.
4. **Adding the rule** to `CLAUDE.md` whenever the agent is caught drifting.

### 3. Vendor documentation as local git submodules

The official documentation repository for each library is submoduled at the version branch matching the local install. The agent then reads from `docs/<lib>/` rather than guessing from training.

Representative pattern:

```bash
# Each entry pins to its version branch
git submodule add -b 13.x https://github.com/laravel/docs.git docs/laravel
git submodule add -b main  https://github.com/livewire/livewire.git docs/livewire
git submodule add -b 5.x   https://github.com/filamentphp/filament.git docs/filament
git submodule add -b main  https://github.com/inertiajs/docs.git docs/inertia
```

For projects in which documentation is a subfolder of the main repository (Livewire, Filament), the entire repository is submoduled, with the agent instructed to read from `docs/<lib>/docs/`. Disk is inexpensive; the submodule abstraction is clean.

A refresh script (`scripts/update-docs.sh`):

```bash
#!/usr/bin/env bash
set -euo pipefail

git submodule update --remote --merge \
  docs/laravel docs/livewire docs/filament docs/inertia

echo "Docs updated. Review with git status, commit if changed."
```

The agent is instructed to consult these sources first via `CLAUDE.md`:

```markdown
**Reading priority (highest → lowest):**
1. Installed type definitions and generated stubs (see below).
2. Local docs submodules in `docs/`. Check these next.
3. Docs MCP server (Context7) for fresh lookups.
4. WebFetch the canonical URL as last resort.
```

#### Machine-readable signals are stronger than prose

Where a stack exposes them, **type definitions and generated stubs are more authoritative than prose documentation**, because they are generated from the very code the project is running. Prose docs lag the code; types cannot. Examples worth instructing the agent to consult before reading prose:

- TypeScript: `node_modules/<lib>/dist/*.d.ts` and `package.json` `types` entry.
- Python: `.pyi` stubs, `inspect.signature`, `help()` output, `pip show <lib>`.
- Go: `go doc <pkg>`, `go doc <pkg>.<Symbol>`.
- Rust: `cargo doc --open`, `rustdoc` JSON output.
- PHP / Java / C#: IDE-grade type information from the installed package.

A representative rule in `CLAUDE.md`:

```markdown
Before consulting prose docs, check the installed type information.
If the type signature already answers the question (does this method
exist, what arguments does it take), prose lookup is unnecessary.
The types are generated from the code that will actually run.
```

This is the cheapest, fastest, most reliable form of verification in any typed stack. It belongs at the top of the reading priority.

### 4. Install a documentation MCP server

[Context7](https://github.com/upstash/context7) is purpose-built for the problem — an MCP server that fetches current upstream documentation for any library on demand. It eliminates submodule maintenance and guarantees freshness.

```bash
# Claude Code
claude mcp add context7 -- npx -y @upstash/context7-mcp
```

The agent is then directed to it via `CLAUDE.md`:

```markdown
For libraries not in the local submodules — or when verifying a
just-released minor — use the Context7 MCP. It returns current docs
without WebFetch overhead.
```

**Note:** MCP tools are discovered at session start. The agent must be restarted after installation for the tools to appear.

### 5. Canonical URLs as WebFetch fallback

Even with submodules and an MCP server, edge cases will occur — a brand-new minor, a library not vendored, an archived issue thread. A one-stop URL list in `CLAUDE.md` ensures that the agent does not guess URLs (and that the user does not need to recall them):

```markdown
### Canonical URLs

**Core stack**
- Laravel 13 — https://laravel.com/docs/13.x — submodule: `docs/laravel/`
- Livewire 4 — https://livewire.laravel.com/docs — submodule: `docs/livewire/docs/`
- Filament 5 — https://filamentphp.com/docs/5.x — submodule: `docs/filament/docs/`

**UI / styling**
- Tailwind CSS — https://tailwindcss.com/docs
- Alpine.js — https://alpinejs.dev

**Animation**
- Motion — https://motion.dev
- GSAP — https://gsap.com/docs/v3/

**Tooling**
- Vite — https://vite.dev
- Pest — https://pestphp.com/docs
- Composer — https://getcomposer.org/doc/
```

### 6. Verify before generating, scoped to high-risk surfaces

The most difficult strategy — and one of the most important. An explicit rule requires the agent to verify before emitting code that uses a versioned API. The rule must be **scoped**, however: applied universally, it doubles turn count, bloats context, and is quietly ignored under load. A scoped rule that gets followed is worth far more than a maximal rule that does not.

The high-value verification surfaces — the ones where drift causes immediate, ship-blocking defects — are narrow:

- Creating a new file at a framework-specific path.
- Calling a public API of a pinned library (method name, argument order, return shape).
- Naming a configuration key, environment variable, or convention-bound path.
- Issuing an install command (`npm install`, `composer require`, `pip install`, `cargo add`).
- Importing a module or sub-package by name.

Internal helpers, business logic, and tests of stable behavior do not warrant the full verification cycle. The rule below reflects that scoping:

```markdown
## Rules for AI work

Before generating code that touches any of the following, you MUST verify:

1. **A new file at a framework-specific path** — confirm the path is
   correct for the pinned framework version (e.g. Laravel 11+ has no
   `app/Http/Kernel.php`).
2. **A public API of a pinned library** — read the type signature or
   doc to confirm the method exists and the arguments match.
3. **A configuration key, env var, or convention-bound path** — confirm
   it exists in the pinned version's schema.
4. **An install command or import path** — confirm the package exists
   on the registry (`npm view <pkg> version`, `pip show <pkg>`, etc.).
   This catches hallucinated package names as distinct from stale ones.

For internal helpers, business logic, and tests of stable behavior,
verification is not required. The rule exists to catch drift, not to
double the cost of every turn.

If a feature is requested that was added in a version later than the
installed one, say so. Do not silently use the newer API.

Do not rely on training data for these libraries.
```

The mechanism is that the rule forces a tool call (Read, MCP fetch, or registry query) before code generation on exactly the surfaces where drift bites. The cost is one additional read per high-risk call; the benefit is that the model cannot hallucinate against a stale prior on the surfaces that ship defects.

#### Test-as-verification

A frequently cheaper alternative to reading docs is to **write a failing test first**. If the test compiles, the agent has confirmed: the API exists, the import path resolves, the signature is close enough to be plausible, and the type system accepts the call. For statically typed projects this is faster than prose lookup and produces a regression guard as a side effect. Add to `CLAUDE.md`:

```markdown
When the surface is testable, prefer writing a small failing test
before generating the implementation. A test that compiles is a
stronger verification than any prose doc, and the artifact is useful.
```

### 7. Choose AI-fluent stacks where it matters

The least expensive form of cutoff-proofing is occasionally the selection of a stack the AI already knows fluently. The canonical example is the **Next.js Pages Router versus App Router**: both ship in current Next.js, but the Pages Router has approximately five additional years of training data behind it. For a small project in which AI throughput matters more than App Router-specific advantages, the Pages Router is the pragmatic selection.

This option is not always available. Where it is, the relevant questions are:

- How dense is the training data for stack A versus stack B?
- How recently did stack B introduce breaking changes?
- What proportion of the codebase will be AI-generated versus human-written?

When the project will be heavily AI-assisted and the stacks are otherwise equivalent, the more-trained stack wins.

#### When AI is the primary author, this is load-bearing

For projects in which the agent is not a productivity multiplier but the **primary author** — a solo or small-team build where most code originates from the model — stack selection moves from "pragmatic fallback" to "high-leverage strategy." Every layer chosen against AI fluency taxes every turn, every session, for the life of the project. Conversely, every layer chosen *with* AI fluency compounds: fewer hallucinations, fewer verification cycles, denser training data behind every suggestion.

The relevant heuristic in that regime:

- Backend: TypeScript (Node, Hono, Fastify, Next API routes) and Python (FastAPI, Django) are the strongest. Go is solid for basics but thins out for idiomatic concurrency and streaming code. Rust, Elixir, and newer typed-functional languages are real friction.
- Web frontend: React + Next.js + Tailwind + shadcn is the deepest training corpus available.
- Mobile: React Native / Expo and Flutter have far more training data than native Android (Kotlin + Compose) or native iOS (Swift + SwiftUI). When constraints permit cross-platform, AI velocity is dramatic. When constraints force native (background location, OEM-specific battery quirks, App Store review survival), the verification machinery in this document must do more work.
- Data: PostgreSQL with Drizzle or Prisma is well-trained. ClickHouse, DuckDB, and specialty stores are thinner.
- Infrastructure: Vercel, Railway, and Fly.io are well-trained. Raw AWS is workable but more error-prone.

Where the vision or product constraints **force** a less-trained layer (e.g., native mobile for a battery-critical app, ClickHouse for time-series at metro scale), the answer is not to override the constraint. It is to lean harder on every other strategy in this document — submodule the docs for that layer, add more gotchas, write more failing tests, accept that this layer will be the slowest part of the build. The strategies compound.

### 8. Enforce drift at the build, not only at the agent

Strategies 1 through 7 all depend on the agent following rules. Most failures will be partial compliance — the agent verifies on Monday and forgets on Friday, follows the rule on small files and skips it on large ones, follows it for the first three calls and not the fourth. The remedy is to install enforcement that **does not require the agent's cooperation** at all: linters, codemods, and CI checks that catch drift after the fact and fail the build.

Representative tooling, by ecosystem:

- **JavaScript / TypeScript:** ESLint with framework-specific deprecation plugins (`eslint-plugin-next`, `@typescript-eslint`), `knip` for unused and missing imports, `ts-prune` for dead exports, `depcheck` for orphaned dependencies, framework-native codemods (`npx @next/codemod`, `npx @react-router/upgrade`).
- **PHP:** Rector for automated upgrades and deprecation detection, PHPStan or Psalm at high strictness levels, Laravel Pint for style and convention.
- **Python:** Ruff with deprecation rule sets, mypy or pyright in strict mode, `pyupgrade` for syntax modernization, framework-specific upgrade tools (`django-upgrade`).
- **Go:** `go vet`, `staticcheck`, `golangci-lint` with deprecation linters enabled, `go mod tidy` as a drift signal.
- **Rust:** `cargo clippy` with deprecation lints, `cargo audit` for vulnerable pinned versions.

These tools share a property: they make drift **fail the build**. The agent does not need to remember to verify. The CI check fails, and the regression is caught before merge. A representative `CLAUDE.md` note:

```markdown
Drift is also caught by automated tooling: `npm run lint`, `npm run
typecheck`, and the codemod scripts under `scripts/codemods/`. Run
these before declaring work complete. A clean lint output is a
stronger signal than your own verification.
```

The leverage here is high because the strategy is **agent-independent**. It runs whether or not the agent followed Strategy 6, and it catches a meaningful subset of what Strategy 6 would have caught. Strategies 6 and 8 are complements, not substitutes — verification before generation, tooling enforcement after generation.

### 9. Treat the project itself as a moving target

Every strategy above is framed against **library** drift. The same failure mode applies to the project's own internal code: a file renamed three commits ago, a helper extracted to a new module, a config value moved from one section to another. The agent — having read the project tree at session start or earlier — continues to reference the old name. The defect is identical in shape to library drift; only the source is internal.

Representative symptoms:

- The agent imports `./utils/auth` after that module was renamed to `./lib/auth/session` two commits ago.
- The agent calls an internal function with a signature that was changed in a recent refactor.
- The agent edits a file that has been deleted and replaced by a directory.
- The agent references a config key (`config.auth.tokens`) that was relocated under a new namespace.

The mitigations are project-internal versions of the strategies already named:

```markdown
## Project-internal verification

Before referencing any internal symbol, file, or import path:

1. Confirm the file or directory exists in the current tree
   (ripgrep / Glob), do not rely on memory of an earlier session.
2. For non-trivial tasks, skim `git log --since="2 weeks ago"
   --name-status` for renames and deletions that affect your area.
3. When asked to edit a file that you do not see in the current tree,
   ask before creating it — the user may be referring to a file under
   a new name.
```

The principle is the same as for library drift: do not trust the prior, verify against the tree. The project is also moving.

### 10. Know what doesn't drift

The strategies above are load-bearing on fast-moving surfaces. Applying them universally — to surfaces that have not meaningfully changed in decades — adds friction without benefit, and a rule that is followed everywhere stops being followed anywhere.

Stable surfaces where training data is reliable:

- **POSIX shell syntax** — `if`, `for`, `while`, `case`, quoting rules, `$()`, pipes. These are specified by POSIX and have not changed in substance since the 1990s.
- **Kernel sysctls** — `net.ipv4.*`, `kernel.randomize_va_space`, `fs.protected_*`. The Linux kernel treats ABI stability as sacred. Sysctl parameter names are effectively permanent.
- **Core OpenSSH directives** — `PermitRootLogin`, `PasswordAuthentication`, `AllowUsers`, `MaxAuthTries`. Present and stable across every OpenSSH release for 20+ years.
- **TCP/IP and HTTP fundamentals** — port numbers, HTTP status codes, header names, TLS handshake structure. Protocol specifications don't change; only implementations do.
- **SQL basics** — `SELECT`, `INSERT`, `UPDATE`, `DELETE`, `JOIN`, `WHERE`. Standard SQL is stable. Dialect extensions (window functions, CTEs, JSON operators) are stable within a given database version.
- **Standard library primitives** — `printf`, `grep`, `awk`, `sed`, `find`. POSIX utilities with decades of stability. Verify only non-standard flags or GNU extensions.

The practical rule: if the surface is specified by an RFC, a POSIX standard, or a Linux kernel ABI commitment, trust training data. If it is specified by a vendor's changelog, verify.

### 11. Infrastructure and configuration drift

The strategies above focus on library and code drift. Infrastructure-as-code and system configuration drift on the same timescale — sometimes faster — and share none of the safety nets that code has (type systems, lockfiles, compilers). The failure mode is identical: the agent emits syntax or resource names that were correct at training time but are now wrong.

**Infrastructure as Code:**

- **Terraform:** provider resource types and attributes change across provider versions. `aws_s3_bucket` ACL attributes were restructured in AWS provider v4. `google_container_cluster` node pool management changed in GCP provider v5. The agent emits the old structure confidently. Mitigation: pin provider versions in `required_providers`, use `terraform validate`, and treat provider changelogs as a source of gotchas.
- **Ansible:** module names and namespaces changed with collections (`community.general.ufw` vs `ufw`). The `ansible.builtin.*` namespace is required in newer versions. Modules deprecated in 2.x were removed in later releases. The agent often emits the removed forms.
- **Kubernetes:** API versions are deprecated and removed on a fixed schedule. `extensions/v1beta1` is gone. `batch/v1beta1` is gone. The agent emits removed API versions for clusters that no longer accept them. Mitigation: `kubectl deprecations` and `pluto` for static analysis.
- **Docker Compose:** `docker-compose` (v1, Python) vs `docker compose` (v2, Go plugin) is a persistent trap. `version:` field at the top of `compose.yaml` is deprecated in v2. The agent emits v1 syntax targeting v2 environments.
- **Cloud CLI flags:** `gcloud`, `aws`, `az`, `hcloud` deprecate flags regularly. The agent emits `--zone` where `--zones` is now required, `--machine-type` formats that changed, deprecated authentication flows.

**System configuration:**

- **`sshd_config`:** directives added, renamed, and removed across OpenSSH versions. `UsePrivilegeSeparation` was removed in OpenSSH 7.5. `Protocol 2` is redundant since SSHv1 was removed. The agent may emit removed directives that cause `sshd -t` to fail.
- **systemd unit syntax:** options added and deprecated across systemd versions. `StandardOutput=syslog` deprecated in favor of `journal`. `PrivateDevices`, `ProtectSystem` semantics changed.
- **Package names across distros:** `ufw` is `ufw` on Debian/Ubuntu but not available on RHEL without EPEL. `fail2ban` configuration paths differ. The agent often emits Debian-specific paths on RHEL targets or vice versa.

**Mitigation for infrastructure drift:**

```markdown
## Infrastructure verification rules

Before generating any IaC or system config:
1. Terraform: confirm resource type exists in the pinned provider version
   (`terraform providers schema`).
2. Ansible: confirm module is in the correct collection for the installed
   ansible-core version (`ansible-doc <module>`).
3. Kubernetes: confirm API version is not deprecated for the target cluster
   version (`kubectl api-versions`).
4. sshd_config: always validate with `sshd -t` before reload.
5. Any cloud CLI command: confirm flags exist in the installed CLI version
   (`command --help`).
```

### 12. Prune the instruction file — gotchas decay

Every strategy above adds information to `CLAUDE.md`. Nothing removes it. This is a structural problem: the file grows monotonically, directives crowd each other out of the model's effective attention, and stale gotchas persist long after the underlying issue was fixed upstream.

**Why gotchas decay:**

A gotcha is added when the agent makes a mistake: "Do NOT use `wire:model.defer` — it was removed in Livewire v3." Six months later, the project upgrades to Livewire v4, and the mistake can no longer occur. The gotcha is now stale but still occupies attention and implicitly suggests the project is on a version where `wire:model.defer` was ever valid.

**The pruning rhythm:**

Add to the maintenance rhythm: at every major version bump, review the entire `CLAUDE.md` gotcha list. For each entry:

1. Is the described mistake still possible given the current version? If not, remove it.
2. Is it now caught by a linter or type error? If so, the build enforces it — remove the prose rule.
3. Is the anti-pattern so obvious from the current docs that no AI would make it? Remove it.

A gotcha that survives pruning is load-bearing. A gotcha that doesn't survive pruning was consuming attention for no reason.

**The 10-entry heuristic:**

If the gotcha list exceeds ten entries, something is wrong — either the project is on a genuinely complex stack that warrants the machinery, or gotchas are being added without being pruned. Ten well-chosen gotchas that the agent actually follows are worth more than forty that it scans past.

**The instruction file is not immune to drift:**

Beyond gotchas, the instruction file itself ages in other ways:
- Canonical URLs move — verify them at the same cadence as the drift check.
- Section references break when files are renamed or removed.
- Workflow descriptions become wrong when the project's structure changes.
- The "today's date" line, if maintained manually, will be stale by the next session.

Add a periodic self-audit of `CLAUDE.md` to the maintenance rhythm. The file that guards against drift must itself be kept honest.

---

## Universal `CLAUDE.md` template

The following is to be adapted to the relevant stack. **Keep it tight.** This file is in competition with the actual conversation for the model's attention; a 400-line `CLAUDE.md` is meaningfully worse than a 100-line one even when the extra content is correct, because the directives stop being load-bearing in the model's reading. Migration guides and API references belong in submodules and MCP, not here. This file is directives only.

```markdown
# CLAUDE.md

Guidance for Claude Code (and other AI agents) working in this repo.

> Verify, do not trust.

Today is {YYYY-MM-DD}. Your training cutoff is months earlier than this.
Assume any library named below has moved since you were trained.

## Stack (pinned)

- {Framework} {version}
- {Library A} {version}
- {Library B} {version}
- {Language} {version}

The **lockfile** ({package-lock.json / composer.lock / etc.}) is the
authoritative source of installed versions. At session start, read
the lockfile entries for the libraries above and surface any
discrepancy before generating code. This file is a human-readable
mirror that drifts.

## Rules for AI work

These libraries move fast and training data lags. Do NOT rely on
training data for any library above. Verify against the sources below
every session.

**Reading priority (highest → lowest):**
1. Installed type definitions / generated stubs ({path to .d.ts or
   equivalent}). Strongest signal — generated from the running code.
2. Local docs submodules in `docs/<lib>/`.
3. Context7 MCP for fresh lookups.
4. WebFetch the canonical URL (see "Canonical URLs" below).

**Version gotchas — do not make these mistakes:**
- [Specific anti-patterns the agent has been caught producing]
- [API renames or removals between training-data version and installed version]
- [Files the agent attempts to create that no longer exist]

**Before generating code that touches any of these surfaces, verify:**
1. A new file at a framework-specific path.
2. A public API of a pinned library (method, args, return shape).
3. A configuration key, env var, or convention-bound path.
4. An install command or import path (confirm the package exists).

For internal helpers, business logic, and tests of stable behavior,
verification is not required. Prefer writing a small failing test as
a cheaper form of verification when the surface is testable.

**Project-internal drift:** before referencing internal files, symbols,
or import paths, confirm they exist in the current tree (ripgrep, not
memory). The project moves too.

**Tooling enforcement:** drift is also caught by `{lint command}`,
`{typecheck command}`, and `{codemod scripts}`. Run these before
declaring work complete.

## Canonical URLs

[organized list of upstream doc URLs + matching submodule paths]

## Build & run

[setup, dev, test, build, lint, typecheck commands]
```

---

## Common AI Traps by Ecosystem

A non-exhaustive enumeration. Entries should be added as drift is observed in practice.

### JavaScript / TypeScript

- **Next.js:** Pages Router APIs (`getServerSideProps`) emitted into App Router code, or the inverse. `next/image` import paths changed. App Router server actions remain training-thin.
- **React:** hooks rules differ between React 18 and 19. Server Components nuances are training-thin. The `React.FC` style is outdated by current convention.
- **React Router:** v6 → v7 renamed packages (`react-router-dom` → `react-router`).
- **TanStack Query:** v4 → v5 renamed `useQuery` options (`cacheTime` → `gcTime`, etc.).
- **Vue:** Options API versus Composition API; Vue 2 versus 3 reactivity differences.
- **Tailwind:** v3 versus v4 configuration (v4 uses CSS-based configuration, with no `tailwind.config.js` by default).
- **ESM vs CommonJS:** `require` in a `"type": "module"` package.

### PHP

- **Laravel:** `Kernel.php` files removed in v11+; middleware now resides in `bootstrap/app.php`.
- **Livewire:** v2 `wire:model.defer` removed in v3+; v4 introduces further changes.
- **Filament:** Resource API changes across every major release, particularly in the schema, form, and table APIs.
- **Symfony:** bundle configuration; attribute routing versus annotation routing.
- **Composer:** PSR-4 autoload structure conventions.

### Python

- **Django:** 4.x → 5.x removed older middleware patterns. `from django.utils import timezone` style remains correct; older `datetime` patterns are not.
- **FastAPI:** lifespan handlers replaced `@app.on_event` in newer versions.
- **Pydantic:** v1 versus v2 — a completely different API (validators, configuration, `model_dump` versus `dict`).
- **SQLAlchemy:** 1.x versus 2.x — Session usage and `select()` API.
- **Packaging:** `setup.py` versus `pyproject.toml`; the latter is now canonical.

### Go

- **Modules:** pre-1.16 versus current behavior; `go work` workspaces.
- **Generics:** code written before 1.18 omits them.

### Ruby

- **Rails:** 7.x → 8.x changed Hotwire defaults, removed jbuilder default, etc.
- **Bundler:** Gemfile lock conventions.

### Shell / Bash

- **`set -o pipefail` behavior:** the interaction between `pipefail` and command substitutions (`var=$(cmd)`) has subtle version-dependent behavior. A pipeline that exits non-zero inside `$()` may or may not trigger `set -e` depending on bash version and context. The agent often emits code that assumes one behavior across all versions.
- **`[[ ]]` vs `[ ]`:** the agent mixes bash-specific `[[ ]]` with POSIX `[ ]` in the same script. In scripts that must run on `sh`, `[[ ]]` is unavailable.
- **`read` and `/dev/tty`:** `read -rp "prompt"` writes the prompt to stderr in bash. When stdin is redirected (e.g. `curl | bash`), `read` must use `</dev/tty` explicitly. The agent often omits this.
- **Here-doc quoting:** `<<'EOF'` (single-quoted) prevents variable expansion; `<<EOF` (unquoted) expands variables. The agent confuses the two, producing either literal `$VAR` strings or unintended expansions.
- **`grep` exit codes:** `grep` exits 1 when no match is found, not just on error. With `set -e`, a `grep` that finds nothing kills the script. The agent emits bare `grep` without `|| true` in pipelines.
- **`sed -i` portability:** `sed -i ''` is required on macOS; `sed -i` (no argument) on GNU/Linux. The agent emits one or the other without noting the incompatibility.

### Infrastructure / IaC

- **Terraform:** `terraform plan` output changed format across versions; scripts parsing it break silently. `count` vs `for_each` semantics differ. Provider-level resource attributes renamed between major provider versions (not Terraform core versions). The agent emits the old attribute name confidently.
- **Ansible:** `ansible` (2.x monolith) vs `ansible-core` + collections is a persistent confusion. The agent emits `apt` where `ansible.builtin.apt` is required. `become: yes` vs `become: true` (both valid but inconsistently used). `with_items` deprecated in favor of `loop`.
- **Docker / Docker Compose:** `docker-compose` (v1 Python binary) vs `docker compose` (v2 Go plugin) — different flag sets, different behavior. `version:` key in `compose.yaml` deprecated in Compose v2. `--no-cache` behavior differs. The agent targets v1 on v2 environments.
- **Kubernetes:** API version removal is on a hard schedule. The agent emits `extensions/v1beta1`, `networking.k8s.io/v1beta1`, `batch/v1beta1` — all removed. `kubectl apply` will fail silently on clusters that have already removed the API.
- **GitHub Actions:** `actions/checkout@v2`, `actions/setup-node@v2` — deprecated, behavior changed. `runs-on: ubuntu-latest` changes which Ubuntu version is underneath without warning. `set-output` command deprecated; `$GITHUB_OUTPUT` is now the mechanism.

### Systems / Linux

- **`sshd_config` directives:** `UsePrivilegeSeparation` removed in OpenSSH 7.5. `UseLogin` removed. `Protocol` directive obsolete since SSHv1 removal. The agent emits these in generated configs; `sshd -t` will reject them.
- **`systemctl` and service names:** service names differ across distros and versions. `networking.service` vs `NetworkManager.service`. `ssh.service` vs `sshd.service`. The agent picks one without checking the target distro.
- **`iptables` vs `nftables`:** Debian 10+ and most modern distros use `nftables` as the backend. `iptables` commands work via compatibility shims but produce unpredictable results when mixed with `nft` rules. The agent emits raw `iptables` commands on systems where `ufw` or `nft` manages the ruleset.
- **Package names across distros:** `ufw` (Debian/Ubuntu) does not exist on RHEL/CentOS without EPEL. `auditd` package is `audit` on RHEL. `rsyslog` config paths differ. The agent assumes Debian package names on all apt-based systems and vice versa.
- **`useradd` vs `adduser`:** `adduser` is a Debian-specific wrapper with sane defaults (home directory, shell, password). `useradd` is POSIX but requires explicit flags to match `adduser` behavior. The agent mixes them in Debian-targeted scripts.
- **`cron` vs `systemd` timers:** modern Debian prefers systemd timers. The agent often emits `crontab -e` entries or `/etc/cron.d/` files for tasks better expressed as timer units on systemd-managed hosts.
- **`/etc/network/interfaces` vs `NetworkManager`:** the network configuration mechanism differs between Debian server (interfaces file) and Debian desktop (NetworkManager). The agent emits one for environments that use the other.

### General

- **Authentication libraries:** NextAuth → Auth.js rename; Clerk's API rewrites; Lucia v3 versus v4.
- **AI SDKs:** OpenAI Python SDK 0.x versus 1.x is a complete rewrite. Anthropic SDK has undergone similar jumps. Vercel AI SDK v3 versus v4 versus v5.
- **CI/CD:** GitHub Actions deprecates action versions every few months; `actions/checkout@v3` → `@v4`.
- **Cloud CLIs:** `gcloud`, `aws`, `az`, `hcloud` deprecate flags and restructure subcommands regularly. The agent emits deprecated flag names and old subcommand structures. Always run `command --help` before trusting generated CLI invocations.

---

## Tool-Specific Notes

### Claude Code

- Reads `CLAUDE.md` automatically every session.
- Supports MCP servers (Context7 and others) via `claude mcp add`.
- Has `WebFetch` built in.
- Permissions are configured in `.claude/settings.json`.

### Cursor

- Reads `.cursorrules` (legacy) or `.cursor/rules/*.md` (current).
- Supports MCP servers (newer versions).
- The "Docs" feature indexes specified URLs.

### Aider

- Reads `CONVENTIONS.md` or any file passed via `--read`.
- Can be pointed at local documentation files explicitly.

### GitHub Copilot / Copilot Chat

- Reads `.github/copilot-instructions.md` (limited).
- No first-class documentation-fetching at this writing.

### Cross-Tool Convention: `AGENTS.md`

A growing number of agentic tools read a top-level `AGENTS.md` as a tool-agnostic instruction file. `CLAUDE.md` may be mirrored to `AGENTS.md` for portability, or one may be symlinked to the other.

---

## Maintenance Rhythm

Cutoff-proofing is not one-and-done. Vendored documentation is stale the moment a new minor ships.

**Every session start (cheap, automated where possible):**

- Diff the lockfile against the pinned versions in `CLAUDE.md`. Surface any mismatch before generating code.
- Confirm the date line in `CLAUDE.md` is today's date, not last month's.

**Weekly (or at the start of any new feature):**

- Run `./scripts/update-docs.sh` to pull latest from pinned branches.
- Skim the changelog for any pinned library that has moved.
- Run the project's lint and typecheck suites; new deprecation warnings often appear after upstream releases even without local code changes.

**Per major version bump:**

- Update the version pin in `CLAUDE.md` *and* confirm the lockfile reflects it.
- Update the submodule branch (`git config -f .gitmodules submodule.docs/<lib>.branch <new>`).
- Add new version gotchas to `CLAUDE.md` based on the migration guide.
- Review deprecation linter rule sets and enable new ones (e.g. `eslint-plugin-next` rules added in the new major).
- **Prune gotchas that no longer apply.** For each existing gotcha: is the mistake still possible on the new version? If not, remove it. Is it now caught by a linter? Remove the prose rule — the build enforces it. A gotcha that survives pruning is load-bearing; one that doesn't was consuming attention for nothing.

**Per AI mistake observed:**

- Add the specific anti-pattern to the "Version gotchas" list in `CLAUDE.md`.
- Where the same class of mistake can be caught by a linter or codemod, install the rule. Encoding the correction at the build level prevents the same mistake from recurring even if the gotcha entry is later trimmed.
- This is how the file (and the project) becomes sharper over time. The correction is not merely applied; it is encoded.

**Quarterly (CLAUDE.md self-audit):**

- Verify every canonical URL in the file still resolves and points to the right content.
- Check every section reference — files may have been renamed or removed.
- Review the gotcha list for entries describing problems fixed in the current version.
- Re-read the full file with fresh eyes: are the directives still load-bearing, or has the project moved past them?
- The instruction file is not immune to drift. Treat it as a first-class artifact that requires the same maintenance discipline as the code it governs.

---

## When This Is Overkill

Not every project requires this machinery. The heavy strategies may be skipped when:

- The project is throwaway or one-off.
- AI assistance is not in use.
- The stack is small and the agent gets it right by default (vanilla HTML/CSS, basic Python scripts, etc.).
- Everything can be verified manually within minutes.

The strategies should be applied when:

- The project is real and ongoing.
- The stack uses fast-moving libraries.
- The codebase will be maintained for months.
- AI throughput contributes meaningfully to velocity.

---

## The Underlying Mindset

The model is not lying when it generates stale code. It genuinely does not know. The objective is to make "not knowing" inexpensive to recover from — by routing the agent to authoriative sources before it commits to a guess.

> Verify, do not trust.

That phrase belongs at the top of every `CLAUDE.md`.
 