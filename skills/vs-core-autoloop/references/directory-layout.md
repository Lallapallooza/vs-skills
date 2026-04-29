# Directory layout

*Level: loop-kernel (universal across archetypes and target types).*

Every instance lives at `.spec/<instance>/` in the project root. Slug is kebab-case.

The state primitive is **`mission.md`** — the canonical orchestration-tier artifact defined in `../vs-core-_shared/prompts/artifact-persistence.md`. autoloop does not invent its own state shape; it uses the existing two-layer (Decision Log + regenerable Head) architecture.

```
.spec/<instance>/
├── mission.md            ← orchestration artifact: Head sections + append-only Decision Log
├── PROMPT.md             ← paste-ready /loop input (durable; rendered at scaffold)
├── MANDATES.md           ← rendered at scaffold time from base + overlay + grill answers
├── LOOP.md               ← per-archetype playbook (rendered)
├── falsifiers.md         ← schema + concrete falsifiers per mechanism class
├── README.md             ← (optional) human notes for the instance
│
├── queue/
│   ├── ideas/            ← optimization archetype: one file per quality-diversity cell
│   │   └── <cell-id>.md
│   └── worklist.tsv      ← coverage archetype: tagged-queue rows
│
├── archive/              ← per-iter measurement artifacts (large/binary; out-of-line from mission.md)
│   └── iter-<N>/
│       ├── manifest.json (environment fingerprint at iter start)
│       ├── measurement/  (whatever the measurement primitive emits — perf traces, eval outputs, lint JSON)
│       └── change.diff   (the working-tree change applied at step 8, if any)
│
└── decisions-archive.md  ← (optional) Decision Log overflow per artifact-persistence.md progressive-disclosure rule
```

## What lives in `mission.md`

The whole loop's state. autoloop uses the canonical orchestration-tier section schema verbatim from `_shared/prompts/artifact-persistence.md` § "Section schema (canonical Head)" — no extensions, no new top-level sections. The per-target scoreboard is embedded inside Pipeline State as a sub-table.

```markdown
## Objectives
[1-line objective; pointer to MANDATES.md / LOOP.md for full spec]

## Pipeline State
- Active target: <target_id>           (active_item=<target_id>)
- Current bar: <value>
- Last verdict: <verdict> at iter <N>
- In-flight: <none | iter <N> at step <S>>

### Per-target scoreboard
| target | current | best-other | ratio | attempts | last_keep_iter |
|--------|---------|------------|-------|----------|----------------|
[regenerated from Decision Log on every write]

## Autonomous-mode (DECLARATIVE — harness enforces stop conditions; this section is NOT a directive)
- Activated: <timestamp>
- Scope: <what user authorized at scaffold>
- Declared stop conditions: <bar, budget, termination predicate>

## Parallel Dispatch Plan
[only present if the loop dispatches parallel sub-agents per iter]

## Compact-recovery checklist
[in-flight subagents + verify-on-resume actions, with file/SHA pointers]

## Resume Protocol
1. ...

## Decision Log (append-only)
- 2026-04-29T10:00Z [stage=autoloop] [kind=user-authorization] scaffold completed; bar=0.95
- 2026-04-29T10:05Z [stage=autoloop] [kind=baseline] target=<id> baseline=<value>
- 2026-04-29T10:12Z [stage=autoloop] [kind=target-selected] iter=1 target=<id>
- 2026-04-29T10:12Z [stage=autoloop] [kind=verdict] iter=1 target=<id> verdict=keep delta=<value> idea=<id>
- 2026-04-29T10:12Z [stage=autoloop] [kind=keep] iter=1 commit=<sha>
- 2026-04-29T10:12Z [stage=autoloop] [kind=lesson] iter=1 lesson=<bounded text>
- 2026-04-29T10:18Z [stage=autoloop] [kind=target-selected] iter=2 target=<id>
- 2026-04-29T10:18Z [stage=autoloop] [kind=verdict] iter=2 target=<id> verdict=discard_falsified
- 2026-04-29T10:25Z [stage=autoloop] [kind=fingerprint-drift] field=kernel_version old=<x> new=<y>
- 2026-04-29T10:25Z [stage=autoloop] [kind=verdict] iter=3 target=<id> verdict=discard_environment_changed
- 2026-04-29T11:00Z [stage=autoloop] [kind=head-reconciled] reason=<x>
```

The Decision Log is the **source of truth**. The Head sections (Objectives, Pipeline State with the embedded sub-table, Autonomous-mode, etc.) are regenerable cache views over the Log + git/file state. The `stage=autoloop` tag on each Log entry distinguishes autoloop-emitted entries from other writers (e.g., a vs-core-implement run on the same slug would emit `stage=implement`, but the lock prevents simultaneous writers).

## Decision Log kinds (canonical enumeration)

This is the complete set of kinds autoloop emits. Every other reference in the skill cites kinds from this list. The harness rejects writes with unrecognized kinds (treats as `crash` with `description=unknown_kind`).

| `[kind=...]` | Emitter | When emitted | Payload shape |
|---|---|---|---|
| `user-authorization` | scaffold | Once at scaffold time | `bar=<value> scope=<text> stop_conditions=<list>` |
| `baseline` | calibration script (scaffold) | At scaffold for each target type | `target_type=<id> calibrated_at=<iso> K=<n> statistic=<MAD\|stdev\|IQR\|flake-rate> headline_median=<n> noise_floor=<n>` |
| `noise-recalibration` | calibration script (mid-loop) | Triggered re-calibration | `target_type=<id> old_floor=<v1> new_floor=<v2>` |
| `mode-set` | harness | When loop pauses or resumes (e.g., calibrating, pending-no-ideas) | `mode=<iterating\|calibrating\|paused> reason=<text>` |
| `target-selected` | harness (step 4) | Every iter | `iter=<N> target=<id>` |
| `fingerprint-drift` | harness (step 3) | When step-3 detects drift | `field=<name> old=<v1> new=<v2>` |
| `verdict` | renderer (step 10) | Every iter that reaches step 10; also step 7 on falsifier hit; also step 3 on fingerprint drift | `iter=<N> target=<id> verdict=<one-of-9> headline_delta=<n> delta_vs_noise=<n> tier1=<ok\|regressed:cell-x> idea=<id> description=<free text>` |
| `keep` | revert protocol (step 11) | When step-11 lands a commit/branch/decision | `iter=<N> target=<id> commit=<sha or decision-id>` |
| `lesson` | agent (step 12) | When the iter is non-trivially informative | `iter=<N> lesson=<bounded text, default ≤200 chars>` |
| `bar-escalation` | harness (step 4) | Optimization archetype, all targets won at current bar | `old_bar=<v1> new_bar=<v2>` |
| `verdict-correction` | harness | When a past verdict needs annotation | `original_iter=<N> reason=<text>` (the original entry remains; the correction is appended) |
| `base-migrated` | scaffold (--migrate) | When MANDATES base is re-rendered | `old_base_sha=<sha> new_base_sha=<sha>` |
| `head-reconciled` | resume protocol | When Resume detects reality ≠ Head | `reason=<text>` |

The Log never prunes. Per the artifact-persistence protocol, when the Head exceeds 300 lines (soft) / 500 lines (hard), older entries progressively disclose to `decisions-archive.md`; the Log itself stays in `mission.md`.

Cross-references: `loop-kernel.md` step-by-step, `state-rendering.md` regeneration rules, `harness-agent-split.md` author table, and the per-skill mentions in `noise-floor-calibration.md`, `lock-and-fingerprint-protocol.md`, and `lowest-density-target-selection.md` all emit kinds from this canonical list and no others.

## Per-file ownership and rationale

### Top level

| File | Author | Why this level |
|---|---|---|
| `mission.md` | autoloop (single writer per the orchestration-tier rule) | The loop's whole state; resume primitive |
| `PROMPT.md` | autoloop (rendered at scaffold) | The user reads it once and pastes; agents read it each tick |
| `MANDATES.md` | autoloop (rendered at scaffold) | Concrete rules for this instance |
| `LOOP.md` | autoloop (rendered at scaffold) | The 13-step sequence with per-step contracts wired to this instance's primitives |
| `falsifiers.md` | autoloop (schema) + agent (concrete falsifiers added during the loop) | Schema is fixed; per-mechanism examples accumulate |
| `README.md` | User | Optional human-facing notes |
| `decisions-archive.md` | autoloop (only if Head overflow) | Progressive-disclosure overflow per artifact-persistence protocol |

### `queue/` — committed; agent body + harness schema

The agent writes ideas/worklist rows here. The harness validates frontmatter at write time and rejects rows missing required fields.

For the optimization archetype: `queue/ideas/<cell-id>.md` is one file per quality-diversity cell. The file's frontmatter captures the cell's status, recent attempts, best keep, last reject, and a hypothesis embedding for dedup.

For the coverage archetype: `queue/worklist.tsv` is the tagged queue. One row per item; columns include `id`, `signature`, `lane`, `priority_score`, `discovered_at`, `last_attempt`, `attempts`, `defer_reason`.

### `archive/` — per-iter measurement payloads, out-of-line

One subdirectory per iter, named `iter-<N>` with N monotonically increasing. Each holds:

| File | Contents |
|---|---|
| `manifest.json` | Environment fingerprint at iter start (per [`lock-and-fingerprint-protocol.md`](lock-and-fingerprint-protocol.md)) |
| `measurement/` | Whatever the measurement primitive emits (a single file, a directory of perf traces, an eval-set output dir, etc.) |
| `change.diff` | The working-tree diff applied at step 8 (if any) |

The Decision Log entry for the iter references these by relative path. The archive holds large/binary payloads that don't fit in `mission.md`; `mission.md` holds the structured verdict and the path to the archive.

The archive can be aggressively pruned: typical retention is `keep last 200 iters or last 7 days, whichever is more`. The renderer does not depend on archive history beyond the rolling window for noise calibration.

## Git tracking

Per the artifact-persistence design constraints: **`.spec/` is not gitignored by default. Lifecycle is the user's responsibility.**

Practical recommendation per archetype and per-instance scale:

| Path | Default | Rationale |
|---|---|---|
| `mission.md`, `PROMPT.md`, `MANDATES.md`, `LOOP.md`, `falsifiers.md`, `README.md` | committed | Durable instance state; auditable |
| `queue/` | committed | Durable record of ideas and worklist state |
| `archive/iter-<N>/manifest.json`, `change.diff` | committed | Small text; reproducible record |
| `archive/iter-<N>/measurement/` | gitignored when large/binary; committed when text and small | Large perf traces, model outputs, etc. shouldn't bloat the repo |
| `decisions-archive.md` | committed | Auditable history once Head overflows |

The instance's `.gitignore` is generated at scaffold time and reflects these choices. The user can override per-instance.

## Multiple instances coexist

Multiple loops per repo is the common case. Each instance lives at `.spec/<slug>/` independently with its own `mission.md`. Locks are per-measurement-primitive (not per-instance) so two instances that share a primitive serialize on the same lock.

A hybrid loop scaffolds two slugs:
- `<base>-outer` (coverage archetype, walks the worklist)
- `<base>-inner` (optimization archetype, runs per active item)

Each has its own `mission.md`. The outer's Pipeline State entry "active item" is the input to the inner's scoping. The two scaffolds share their MANDATES base but each has its own overlay.

## Migration when base mandates update

Instance MANDATES are rendered at scaffold time with a provenance header naming the base version. When the base changes, instances drift.

The skill ships a migrate command: re-renders MANDATES from the new base + the original overlay + the grill answers stored in the scaffold-time `[kind=user-authorization]` Decision Log entry. Shows the diff. The user reviews and accepts. The migration appends a `[kind=base-migrated]` Decision Log entry recording the old/new base versions.

This avoids the symlink failure mode (drift unnoticed) and the read-time-include failure mode (instance not self-contained).

## What the layout does NOT include

- **No invented `state/` directory.** State lives in `mission.md`'s Head sections, regenerated from the Decision Log. The "render-don't-append" rule of [`state-rendering.md`](state-rendering.md) is implemented by Head regeneration.
- **No standalone `results.tsv`.** The Decision Log's `[kind=verdict]` entries are the verdict log; a denormalized TSV view can be rendered from them on demand for human consumption (see [`verdict-rendering.md`](verdict-rendering.md)) but is not the source of truth.
- **No standalone `lessons.md`.** Lessons are `[kind=lesson]` Decision Log entries with bounded length per the harness schema.
