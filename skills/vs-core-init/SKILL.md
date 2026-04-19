---
name: vs-core-init
description: Create or extend a project-root CLAUDE.md. Two modes. INIT writes a new seed file after a short interview plus a silent probe; auto-selected when no CLAUDE.md exists. APPEND inserts a single learning (a gotcha, a command, a common flow, a knowledge-drift note) into the existing CLAUDE.md at the right section; auto-selected when CLAUDE.md exists and the user has a specific thing to add. Use when the user says "init this project", "generate a CLAUDE.md", "/vs-core-init", "add this to CLAUDE.md", or when a session surfaces a learning worth persisting.
disable-model-invocation: true
---

# Manage CLAUDE.md

This skill owns the full lifecycle of a project's root CLAUDE.md: creation AND accumulation. It runs in one of two modes depending on file state and user invocation.

`disable-model-invocation: true` is deliberate. The skill modifies files on disk and should only run when the user explicitly asks for it. Claude can and should suggest running this skill in text when a session surfaces something worth persisting (for example, "worth adding via `/vs-core-init`"). That keeps the skill suggestable without making it auto-invokable.

## Modes

| Mode | Selected when | Flow |
|---|---|---|
| **init** | No `./CLAUDE.md` exists, or user says "init"/"generate a CLAUDE.md" with no specific content to add | Silent probe, interview, generate seed, approve whole draft, write |
| **append** | `./CLAUDE.md` exists AND user's invocation contains a specific learning ("add this: X", "we just learned Y", "put this under gotchas") | Read existing file, classify the learning into a section, propose the insertion, approve, write |

If the state is ambiguous (CLAUDE.md exists but user invoked with no content), ask: "Init with fresh content, or append something specific?" Default is append; init would overwrite.

---

## Phase 0: Route

1. `Read ./CLAUDE.md`. Note whether it exists.
2. Check the user's invocation text for a specific learning to add (something that looks like a gotcha, command, flow, or fact the user wants to preserve).
3. Route to the corresponding phase below. If ambiguous, ask once.

---

## Phase 1 (init): Silent probe

Run in parallel. Under two seconds. Do not print verbose output.

| Signal | How |
|---|---|
| Canonical build/test commands | `Read` any of: `package.json`, `Cargo.toml`, `pyproject.toml`, `go.mod`, `Makefile`, `justfile`, `build.zig`, `CMakeLists.txt`. Extract common invocations. |
| Linter / formatter configs | `Glob` for `.rustfmt.toml`, `.clang-format`, `.pre-commit-config.yaml`, `.eslintrc*`, `.prettierrc*`, `ruff.toml`. Record paths only. CLAUDE.md will link them, not duplicate their rules. |
| CI commands (hint only, not authoritative) | `Glob .github/workflows/*.yml`. First file, first 40 lines. Surface as a hint during interview: "CI runs X; is that what you run locally?" Do not extract directly into the draft. |
| Monorepo signals | `Glob` for `pnpm-workspace.yaml`, `lerna.json`, `turbo.json`, `nx.json`, `go.work`. Also check `Cargo.toml` for `[workspace]` section and count `package.json` files. If 2+ monorepo signals, trigger monorepo prompt (see Phase 3). |
| Existing skills | `Glob .claude/{skills,commands,hooks,agents}/**/SKILL.md`. Record names and frontmatter `description` fields. |
| README first paragraph | `Read README.md` first 80 lines. Extract one-line purpose. |
| Git branch pattern | `Bash git branch -r --format='%(refname:short)' 2>/dev/null | head -20`. Look for `users/<name>/`, `feat/`, `fix/` style. |
| Project structure (for Project map section) | `Bash ls -d */ 2>/dev/null | head -30` for top-level dirs. Skip hidden, config, vendored (`node_modules`, `dist`, `target`, `.next`, `build`, `.venv`). Count source-y dirs. Decide shape: **directory map** if monorepo signals OR 4+ source dirs with distinct names; **task map** if single src/ with routed subdirs; **flow map** if README/interview mentions pipeline/dataflow; **skip** if the layout is trivially flat. |

Do not probe what does not exist. Do not read generated or vendored directories (`node_modules/`, `dist/`, `.next/`, `target/`).

### Inference probes (run in parallel with the main probe)

These produce *candidate answers* to the interview questions. The skill surfaces candidates as "Observed from probe: ..." preambles in Phase 2. **Observations are not rules.** User confirms what becomes a documented rule. If a probe finds nothing relevant, skip the preamble for that question; do not invent content.

Cap: at most 15 source files read, at most 30 grep calls, under four seconds total.

**Cluster 1: Code-sample inference.**

Read 5-10 representative source files (stratified: public headers, implementation, tests, bindings if any).

- **Q6 Naming**: count method casing, field-prefix patterns (`m_`, `_`, none), type casing, enum casing. Report as ratios: "Methods: 47 camelCase of 50 sampled. Fields: 82% `m_` prefix. Types: PascalCase unanimous."
- **Q7 Invariants**: collect `static_assert(...)` messages, `concept` requirements, `assert(...)` contents, top-of-file doc-comments tagged "assumes", "invariant", "requires".
- **Q8 Error model**: count `throw`, `Result<`, `Option<`, explicit error-return types, `panic!`, `unwrap()`, `.expect(...)`, `assert!`. Strongest pattern wins.

**Cluster 2: Process-artefact inference.**

- **Q1 Gotchas**: grep README.md / CONTRIBUTING.md lines containing "WARNING", "NOTE:", "DO NOT", "NEVER", "IMPORTANT", "Be careful". Read `.pre-commit-config.yaml`: each non-trivial hook is an implicit rule (e.g., a hook rejecting em-dashes is a Gotcha candidate).
- **Q2 Build/test**: scan `.github/workflows/*.yml` for `timeout-minutes: > 10` -> SLOW candidates. Scan Makefile for targets that chain `rm -rf` or `git reset --hard` -> DO-NOT-RUN candidates. Scan test scripts for `export <VAR>=` -> REQUIRES candidates.
- **Q3 Common flows**: read CONTRIBUTING.md for headings matching "Adding a new", "How to add", "To add a" + the following bullet list.
- **Q4 Knowledge drift**: read CHANGELOG.md most-recent "Breaking Changes" section if any. Grep source for `// renamed from`, `// was:`, `// deprecated`, `// TODO remove`.
- **Q8 Commits**: read `cz.toml` / `commitizen.toml` / `.gitlint` / `.commitlintrc*` for enforced rules. Read the last 20 commit messages (`git log --oneline -20`) for body-length pattern.

**Cluster 3: Grep-count inference.**

Quick codebase-wide patterns that inform Q8 subsections:

- **Linter exemption**: counts of `NOLINT`, `eslint-disable`, `# noqa`, `# type: ignore`, `# pylint: disable`, `@ts-ignore`. High count with clustered usage implies "sprinkled disables"; low count with all entries having comments implies "global-with-rationale" policy.
- **Legacy fallback state**: counts of identifiers matching `_v1$`, `_v2$`, `legacy_`, `deprecated_`, `Old[A-Z]`. Presence indicates the project tolerates these; absence is evidence of the "no fallback" stance.
- **Architectural tells**: counts of singleton/factory/visitor patterns via class-name heuristics (only surface if clearly dominant).

All cluster output is structured as "Observed: <short statement>" fragments attached to the matching interview question.

---

## Phase 2 (init): Interview

One message to the user. Answers drive the sections that probe cannot fill. User can skip any question.

Each question optionally begins with an "Observed from probe: ..." block if inference probes (above) found candidates. These are observations, not rules. User confirms what becomes a documented rule, rejects misreadings, or adds more from their own knowledge.

```
I will generate a seed CLAUDE.md. Eight questions. Answer in any order,
skip any that does not apply. Tags in brackets help me classify; you
can use them or just describe in free prose.

For each question, if my probe found candidates, they appear under
"Observed from probe:". Those are observations about what the code
currently does, not claims about what the rule should be. Confirm,
reject, edit, or add your own.

1. Gotchas and anti-patterns: what do new engineers or Claude consistently
   get wrong in this repo? Use tags like:
     [NEVER] rule that must not be broken: <what + why>
     [GOTCHA] thing that looks right but goes wrong: <what>
   Observed from probe (if anything): <README/CONTRIBUTING callouts,
     pre-commit hook entries>.

2. Build and test specifics: which commands have timeouts, non-obvious
   invocations, or known traps? Use tags like:
     [SLOW] command + duration, any workaround
     [REQUIRES] command + env vars or setup needed before
     [DO-NOT-RUN] command + reason
     [FILTER] how to run a subset instead of the full suite
   Observed from probe (if anything): <CI timeouts, destructive Makefile
     targets, env vars referenced in test scripts>.

3. Common flows: what multi-step procedures does this repo have that
   always involve the same sequence? Example:
     Adding an operator: (1) TableGen def, (2) mandatory lit test,
     (3) mandatory Python functional test, (4) update docs.
   Observed from probe (if anything): <CONTRIBUTING "Adding a new X"
     sections>.

4. Knowledge drift: anything that contradicts Claude's training data?
   Renamed components, removed features still in old blog posts,
   inverted patterns.
   Observed from probe (if anything): <CHANGELOG breaking changes,
     `// renamed from` comments>.

5. (Only shown if probe warranted a Project map)
   I detected this structure -- fill in one-line purposes for each,
   or say "guess from README/code" and I will infer, or "skip" to omit:

     <scaffold rendered here, e.g.:
       packages/api        : <one-line purpose>
       packages/web        : <one-line purpose>
       packages/shared     : <one-line purpose>
      OR:
       src/cli/            : <one-line purpose>
       src/runtime/        : <one-line purpose>
       src/ext/            : <one-line purpose>
      OR:
       request -> <handler> -> <service> -> <store>   (edit the flow)>

6. Naming and code-style conventions: any house rules that the linter
   does NOT enforce? Common cases:
     - method casing beyond what the formatter does (camelCase in a
       language whose ecosystem defaults to snake_case, or vice versa)
     - field-prefix conventions (m_, _, k for constants)
     - enum naming (kPascalCase, SCREAMING_SNAKE)
     - file hygiene (`#pragma once` vs header guards)
     - include/import order beyond formatter regrouping
   Answer in free prose or as (Kind | Convention | Examples) triples.
   Skip if the linter enforces everything.
   Observed from probe (if anything): <ratios from sampled files, e.g.
     "Methods: 47 camelCase of 50 sampled; Fields: 82% `m_` prefix;
     Types: PascalCase unanimous">. Confirm these as the intended rules,
     or tell me the pattern is accidental and the rule should be different.

7. Architecture invariants: what does the code rely on being true that
   is NOT obvious from types, signatures, or a quick read? These are
   POSITIVE statements ("X holds; trust it"), not anti-patterns. Examples:
     - "X is always set before Y runs; downstream assumes this."
     - "Allocator is stateless; is_always_equal = true_type."
     - "Function A is called from exactly one place; refactoring is safe."
     - "Core type Foo is the single substrate; no parallel View/Borrowed types."
   Observed from probe (if anything): <`static_assert` messages, `concept`
     requirements, doc-comments tagged "assumes"/"invariant"/"requires">.

8. Project-wide policies: any one-shot declarations the project makes
   about how code is structured? Any of these with a specific stance:
     - Error model: exceptions, error codes, Result/Option, panic
     - Dependency philosophy: vendored vs system, lockfile discipline,
       what's allowed in new deps
     - Commit-body rules beyond Conventional Commits (length cap, what
       NOT to include in the body)
     - Linter exemption policy: how to disable a check when needed
       (global rationale vs scattered NOLINT/eslint-disable comments)
     - Backwards-compat: do you ban `_v1/_v2` shims, deprecation layers,
       feature flags gating old-vs-new paths?
   Observed from probe (if anything):
     - Error model: <counts of throw vs Result vs panic vs unwrap>
     - Linter exemption: <NOLINT/eslint-disable/noqa counts and usage pattern>
     - Legacy fallback: <presence/absence of `_v1`/`legacy_`/`deprecated_` identifiers>
     - Commits: <rules from commitizen/gitlint, last-20-commits body-length pattern>
```

If the user replies with no content beyond "nothing", proceed with mechanical sections only. A thin honest file beats a padded one.

If Q5's project map is rendered but the user answers "guess", the skill attempts inference: read each detected directory's README, top-level module docstring, or one key source file, and generate one-line purposes. Output is treated like any other section -- shown in the full-draft review, editable by the user.

---

## Phase 2 (append): Classify and propose

The user provided a specific thing to add. The skill routes it into the right section.

1. Read existing CLAUDE.md. Build a map: which taxonomy sections exist, which are sparse.
2. Classify the user's input:
   - Command with a timeout/gotcha -> `## Build and test`
   - Multi-step procedure -> `## Common flows`
   - Single-rule anti-pattern (negative, "never do X") -> `## Gotchas`
   - Positive "this holds" statement -> `## Architecture invariants`
   - Naming or code-style rule the linter does NOT enforce -> `## Code style and conventions`
   - Policy statement (error model, deps, commits, linter exemption, legacy-fallback) -> `## Project-wide policies`
   - Fact contradicting training data -> `## Knowledge reminders`
   - Structure observation (a directory's purpose, a new package, a flow relationship) -> `## Project map`
   - One-off imperative rule that doesn't fit above -> `## Notes`
3. Propose the insertion:

```
Classified as: <section>
Existing section in file: <yes with N bullets / no, will add new section>
Proposed addition:

  <the formatted bullet or table row>

Approve / edit / put under different section / cancel?
```

4. On approve, write. On edit, apply user's change, re-propose. On different section, re-classify into user's chosen section. On cancel, stop.

If the existing CLAUDE.md has a custom section name matching the user's intent (e.g., the user calls their gotchas section "Footguns"), use the existing name. Do not rename user sections.

---

## Phase 3 (init only): Monorepo check

If the probe detected 2+ monorepo signals, before generating ask:

```
This looks like a monorepo. Where should CLAUDE.md go?

  1. Repo root -- applies to everything
  2. A specific package: <detected list>
  3. Both -- sparse root + per-package stubs
  4. Cancel

Default: 1 (repo root).
```

On choice 2 or 3, adjust the write target path. On 3, write a minimal root CLAUDE.md with a link to each per-package file.

---

## Phase 4 (init): Generate, self-critique, show

### 4a. Assemble

Build the draft from probe + interview. Section inclusion is conditional: a section is written only if it has real content. Empty sections are not written, with one exception: the Durability, Notes, and Maintenance-contract sections are always written.

### 4b. Self-critique pass (mandatory before showing the user)

This catches the too-thin first-pass output we observed in practice: the first draft often leaves Code-style, Architecture-invariants, or Common-flows empty when the codebase actually demonstrates content for them. Before showing the user, scan the assembled draft against the probe data and the repo one more time.

For each conditional section that is empty OR has fewer than two concrete entries, ask: does the codebase demonstrate content I missed?

- **Code style and conventions empty or 1-row**: re-read the code-sample inference output. Did I count casing patterns and skip producing a table? Produce the table now with the observed ratios. Also scan `.clang-format`, `.clang-tidy`, `ruff.toml`, `tsconfig.json` for `HeaderFilterRegex`, disabled checks, strict flags, format options that are house-rules in disguise.
- **Architecture invariants empty or 1-row**: grep the code tree for `static_assert(`, `concept [A-Z]`, `requires (` and report every hit as a candidate invariant (after deduplication). Grep test names for `ThrowsOn`, `DeathOn`, `Rejects`, `Requires` patterns - each is an invariant in disguise. If user answered Q7 with "nothing", still include the codebase-proved entries but tag them as `[observed]` so the user can confirm or strip on review.
- **Common flows empty**: grep `CONTRIBUTING.md` for "Adding", "To add", "How to". Grep test file names for patterns implying a flow (`*_dispatch_test`, `*_integration_test`, `*_death_test` family). If a test family exists, there is almost certainly a multi-step "adding a new X" flow worth documenting.
- **Gotchas empty or 1-row**: re-read the process-artefact inference output. Each pre-commit hook is implicitly a NEVER rule. CI timeout-minutes > 10 is implicitly a SLOW. Any `.git/hooks/*.legacy` files are implicitly project-specific rules worth surfacing.
- **Knowledge reminders empty**: check the CHANGELOG for the last "Breaking Changes" section. Check README claims against actual code (e.g., README advertises feature X, but grep shows feature X is behind a gate that never fires - exactly the AutoSeeder pattern). At least one knowledge reminder per project is usually findable.
- **Project map missing when repo has 4+ source dirs**: regenerate. If the main probe skipped the Project map because it decided the layout was "trivially flat", verify by reading `ls -d */` output.
- **Build and test missing SLOW/DO-NOT-RUN annotations**: cross-check the CI workflow timeout-minutes values against the commands documented. Every command that CI runs with `timeout-minutes: > 10` is a SLOW candidate.

Rules:

- Observations added during self-critique are tagged `[observed]` so the user can distinguish them from their own interview answers in the review step. They are not speculative; they are codebase-derived.
- If no gap exists for a section, leave it as-is. Do not pad.
- Do no more than one self-critique pass. If a section still has no content after this pass, it genuinely does not belong in this project's CLAUDE.md.

### 4c. Show

Show the complete draft in one fenced markdown block. Then:

```
Approve / edit / cancel?

- "approve" writes to <path>
- describe any edit in free prose; I will re-show after applying
- "cancel" stops without writing
```

Accept edits in sequence. Re-show after each. No arbitrary cycle cap.

---

## Phase 5: Write and verify

On approval:

1. **Init mode**: write `<path>/CLAUDE.md`. Overwrite only if the user explicitly acknowledged an existing file at Phase 0.
2. **Append mode**: read existing CLAUDE.md, insert the approved addition at the correct location (see insertion algorithm below), write back.
3. Run `bash ~/.claude/skills/vs-core-tropes/check-unicode.sh <path>`. If issues, run `fix-unicode.sh` and re-verify.
4. **Structural spot checks** on the written file:
   - No duplicate H2 headings.
   - No empty sections (Notes excepted).
   - Line count sanity. If init produced under 25 lines, warn the user that the file is unusually thin; their interview answers may have been sparse.
5. **Claim verification** (new, non-fatal; warnings only). Extract every testable claim from the file and verify:
   - **Commands in Build-and-test**: for every command line in the `## Build and test` section, take the first token and run `command -v <token>` via Bash. If it returns non-zero, the binary is not on PATH in this environment - flag as a warning.
   - **File paths in Project map and elsewhere**: every backtick-quoted path that looks like a repo-relative file or directory (matches `<name>(/<name>)*` with optional trailing `/`) gets a `Glob` check. If the path does not exist, flag.
   - **Flags in build commands**: for every `-D<NAME>=<value>` CMake flag, `--<name>` argument, or `-D<NAME>` define mentioned, `Grep` the codebase for its definition. Flag any that have no hit.
   - **Named files in Common flows**: if a flow step names a specific file (`kmeans_seeder_test.cpp`, `auto_seeder.h`), `Glob` to confirm it exists. Flag if missing.
   - **Named binaries in Project map and Build-and-test**: e.g., `clustering_demo`, `kdtree_benchmark`. `Grep` the build configuration (`CMakeLists.txt`, `Makefile`, `package.json:scripts`) for the target name. Flag if no definition found.
6. **Verification report**. If any claim failed, emit a single block:
   ```
   Verification warnings (file still written):
   - command `foo` not found on PATH
   - path `include/old/dir/` does not exist in repo
   - flag `-DUNUSED_FLAG=ON` has no definition in the build config
   ```
   These are warnings, not errors. The file is already written. The user decides whether to edit. Skip the report entirely when every claim verified clean.
7. Report on one line: `Wrote CLAUDE.md (<N> lines)` or `Updated CLAUDE.md (+<M> lines, now <N>)`. Follow with the verification report from step 6 if non-empty. No prose summary.

Why non-fatal: the file is already valuable even with stale claims; blocking on verification would lose the rest of the content. Warnings let the user see drift at the moment it is introduced rather than three weeks later.

### Insertion algorithm (append mode)

Section match by H2 heading literal (case-insensitive). If the target section exists:
- For list-shaped sections (Gotchas, Notes, Knowledge reminders, Common flows): append the new bullet at the end of the existing list.
- For table-shaped sections (Project map in task-table or component-table form, Skills and commands): append a new row.
- For Project map in directory-list form: append a new bullet with the dir -> purpose line.
- For Project map in flow-graph form: extend the flow graph if the new entry fits the same pipeline; otherwise propose switching to a list shape.
- For prose sections: insert a new paragraph at the end of the section.

If the target section does not exist:
- Insert a new section immediately before `## Notes` if Notes exists.
- Otherwise append at the end of the file.

Never reorder or rewrite sections the user did not explicitly ask to modify. Never touch custom sections outside the taxonomy.

---

## Section taxonomy (shared by both modes)

| Section | When | Shape |
|---|---|---|
| Overview | Always in init | One sentence from README first paragraph |
| Build and test | Always in init | Commands list + SLOW/REQUIRES/DO-NOT-RUN annotations |
| Project map | Only if probe warranted a map OR interview filled one | One of three shapes: directory map (dir -> purpose list), task map (task -> path table), or flow map (ASCII flow graph). Skill picks shape from structure signals; user can override. |
| Code style and conventions | Only if interview Q6 produced content | `Kind | Convention | Examples` table |
| Gotchas and anti-patterns | Only if interview Q1 produced content | Bullets with NEVER/GOTCHA tags inline; negative rules only |
| Architecture invariants | Only if interview Q7 produced content | Bullets of positive "this holds" statements |
| Common flows | Only if interview Q3 produced content | Numbered steps per named flow |
| Knowledge reminders | Only if interview Q4 produced content | 1-5 bullets |
| Project-wide policies | Only if interview Q8 produced content | Short subsections: Errors, Dependencies, Commits, Linter, Legacy |
| Durability contract | Always | Process-artefact prohibition + no-legacy-residue rule. Universal Claude-specific protection. |
| Skills and commands | Only if `.claude/` entries exist | Entry list with one-line descriptions |
| Notes + maintenance contract | Always | Empty bullet list + instructive comment + maintenance contract |

---

## Generated CLAUDE.md template

The assembled draft follows this shape. Sections without content are omitted (except Notes).

```markdown
# <project name>

<one-sentence purpose>.

> **Living document.** When a session surfaces a finding worth preserving (a non-obvious command, a pitfall, a multi-step flow, knowledge drift, a codebase invariant), propose adding it via `/vs-core-init <the thing>`. See the Maintenance contract at the end of this file for what merits adding and what does not. Do not silently edit this file.

## Build and test

- Build: `<command>`
- Test: `<command>`. Filter individual tests with `<filter syntax>`.
- Lint: `<command>`
- Format: `<command>`

<!-- Conditional entries from interview Q2: -->
- **SLOW**: `<command>` takes <duration>. Do not set a Bash timeout.
- **DO-NOT-RUN**: `<command>`. <reason>.
- **REQUIRES**: `export <VAR>=<value>` before `<command>`. <reason>.

## Project map

<!-- Choose ONE shape that fits the project. Skill proposes based on probe;
     user can override. Examples of each shape: -->

<!-- Shape A: directory map (monorepos, or repos with named top-level dirs) -->

- `packages/api/` : HTTP server, route handlers, schema validation.
- `packages/web/` : Next.js app, SSR, client hydration.
- `packages/shared/` : cross-package types and utilities.
- `packages/codegen/` : build-time code generators; nothing runtime depends on this.

<!-- Shape B: task map (web/framework style with clear entry-point routing) -->

| Task | Location |
|---|---|
| Add/modify a CLI command | `packages/wrangler/src/` |
| API mocks for tests | `packages/wrangler/src/__tests__/helpers/msw/` |

<!-- Shape C: flow map (pipelines / client-server-worker architectures) -->

```
request -> router -> middleware -> handler -> service -> store
                                      |
                                      +-> cache -> store
```

## Code style and conventions

<!-- House rules the linter does NOT enforce. Table format preferred. -->

| Kind | Convention | Examples |
|---|---|---|
| Methods | `camelCase` | `flatIndex`, `isAligned`, `extractPoint` |
| Private fields | `m_camelCase` | `m_shape`, `m_data` |
| Types | `PascalCase` | `NDArray`, `KDTree` |
| Enum constants | `kPascalCase` | `KDTreeDistanceType::kEucledian` |
| Namespaces | lowercase | `clustering`, `clustering::detail` |

## Gotchas and anti-patterns

- **NEVER**: <rule>. <reason>.
- **GOTCHA**: <what looks right but breaks>. <explanation>.

## Architecture invariants

<!-- Positive "this holds" facts the codebase relies on; NOT obvious from types. -->

- `NDArray<T, N>` is the single math substrate; no separate `View<T>` class.
- `AlignedAllocator<T, 32>` is stateless; `is_always_equal = true_type`.
- `KDTree` does not own point data; caller keeps the array alive.

## Common flows

### <flow name>

1. <step>
2. <step>
3. <step>

## Knowledge reminders

Training data may be wrong about this codebase. In particular:

- <fact>
- <fact>

## Project-wide policies

<!-- One-shot declarations. Include only the subsections with actual content. -->

### Errors
<error-model statement>

### Dependencies
<dependency philosophy>

### Commits
Default to no body. Hard cap 3 lines if present. No spec/RFC/slice references. Match prior commit style for the scope.

### Linter exemption
Disable a check globally with a one-line rationale. Do not sprinkle per-line disable comments.

### Legacy fallback
No `_v1/_v2` variants, no deprecation layers, no feature flags gating old-vs-new paths. Refactors update all callers in the same commit.

## Durability contract

Source files, tests, and commit messages are durable artefacts. They outlive the process that produced them. Do not include:

- **Process-artefact identifiers**: no `slice1_`, `rfc_`, `audit_`, `a1_`, `a3_confirmed_`, `phase2_`, `decision7_` prefixes or suffixes on files, namespaces, classes, functions, variables, test cases, or CMake/build targets. An observer reading the code cold should not be able to tell which slice introduced it or which acceptance criterion motivated it.
- **Process references in comments**: no "per RFC Decision N", "Slice 2 will add strides", "satisfies AC#3", "pulled out of X", "previously did Y". Comments live with the code for years; the process around them ages in weeks.
- **Temporal markers**: "TODO remove after Slice N", "will be replaced in phase 3", "legacy path, delete post-migration". If it is meant to be temporary, do not land it.
- **Same rule for commit bodies**: no ticket IDs, RFC numbers, slice identifiers, AC references. The body documents the change itself, not the process that produced it.

## Project skills and commands

- `/<name>`: <one-line description>
- `$<skill-name>`: <one-line description>

## Notes

<!-- Accumulate hard-won rules here as they surface in actual work.
     Terse imperative bullets, one per line. Examples:
     - Never run `make ci` locally; destructive CI-only target.
     - `fetch_sources.py` resets submodules; commit first.
     - Prefer `rg` over `grep -r`; 50x faster on this tree.
-->

## Maintenance contract (for future sessions)

When you learn something during a session that would have saved time if it had been in this file, propose an addition via `/vs-core-init <the thing>`. Do not edit silently; do not add based on a one-off observation.

Add when:

- **Commands** have non-obvious invocations, timeouts, or traps (SLOW, REQUIRES, DO-NOT-RUN).
- **Pitfalls** have cost real time and the diagnosis was non-obvious.
- **Common flows** always involve multiple steps (example: "adding an operator requires TableGen def, lit test, and Python functional test").
- **Knowledge drift** makes training data wrong (renamed concepts, removed features).
- **Invariants** the codebase relies on but does not document elsewhere.

Do not add:

- Language style a linter already enforces.
- Generic best practices available in any style guide.
- One-off observations that have not cost anyone time yet. Let it happen twice before codifying.
```

---

## What this skill does NOT write

Explicit exclusions, to prevent drift back into the bad draft:

- **Generic language discipline blocks** ("Python: fail-fast, pathlib, no `Any`"). Duplicates linter configs. Every developer in that language already knows it.
- **Interaction style blocks** ("be direct, no sycophancy"). Lives in the user's global `~/.claude/CLAUDE.md` or `/vs-core-interactive`, not per-project.
- **Karpathy behavioral guidelines**. Lives in `/vs-core-interactive`.
- **Generic git safety rules** that are already in Claude Code's base instructions.
- **AI-attribution prescriptions** (Co-Authored-By footers, AI-disclosure rules). Values choice with no default-right answer; the project owner can add to Notes if they have a preference.
- **Hook scripts**. Separate concern. Offer them only if the interview surfaces a specific pain point they would address.

---

## Length and shape

No hard line or word limit. The generated seed is typically short (30 to 150 lines in init mode; +1 to +10 in append mode). If the interview produces unusually rich content and the draft crosses roughly 5,000 words, propose splitting: pull a subsystem-scoped section into `docs/AGENTS.md` or a per-directory CLAUDE.md and reference it from the root file with a plain markdown link. Use plain markdown links, not `@import` syntax. Zero gallery files use `@import`; plain links are portable across Claude Code, Cursor, Codex, and plain GitHub browsing.

## Posture

The skill produces a seed and owns its lifecycle. Init is one-shot; append is the mode invoked dozens of times per project over months. The Notes section plus maintenance contract in the generated file tell future sessions how and when to propose additions. Those additions come back through this skill in append mode.

The skill does not:

- Write `.spec/` artifacts. The CLAUDE.md is the output.
- Silently overwrite an existing CLAUDE.md.
- Touch user-authored custom sections outside the taxonomy.
- Install hooks by default.
