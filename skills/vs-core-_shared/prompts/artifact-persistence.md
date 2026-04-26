# Artifact Persistence Protocol

All pipeline skills write structured artifacts to `.spec/`. This file defines the complete protocol. Read it fully before executing any skill logic.

## Frontmatter Schema

Every artifact file begins with exactly these 5 fields:

```yaml
---
feature: string          # the feature slug (matches the .spec/{slug}/ directory name)
stage: string            # must match this skill's stage_name exactly
created: ISO-8601        # set once on first write, never updated
updated: ISO-8601        # updated on every write
upstream: list<string>   # stages actually consumed (not merely declared -- only what was read)
---
```

No additional fields. No omissions. All 5 fields must be present on every write.

## Pipeline Summary

| Skill | stage_name | upstream_reads | multi-artifact |
|---|---|---|---|
| vs-core-grill | grill | none | false |
| vs-core-research | research | grill | false |
| vs-core-arch | arch | grill, research | false |
| vs-core-rfc | rfc | grill, research | false |
| vs-core-implement | implement | rfc | false |
| vs-core-audit | audit | grill, research, arch, rfc, implement | true |
| vs-core-debug | debug | implement | true |
| (orchestration tier) | mission | rfc, implement | false |

**Multi-artifact** means the skill can produce multiple artifacts per feature (one per session). See WRITE_ARTIFACT for naming.

**Orchestration tier** is an opt-in third tier (alongside single-artifact and multi-artifact). It has no dedicated skill — see "Orchestration Tier" below.

## ARTIFACT_DISCOVERY

Run this before any skill logic begins.

1. Scan `.spec/` for subdirectories. Exclude `_standalone/`.
2. **count == 0**: Auto-generate a slug from the user's description (see SLUG_GENERATION). Create `.spec/{slug}/`. No confirmation required. If no description is available, ask: "What is this work about?"
3. **count == 1**: Use that slug silently. No confirmation required.
4. **count > 1**: List the feature directories, ask the user to select one.

The selected slug is used for all subsequent reads and writes in this session.

## UPSTREAM_CONSUMPTION

For each stage listed in this skill's `upstream_reads` (from the Pipeline Summary):

1. Check if `.spec/{slug}/{stage}.md` exists.
2. **Exists**: Read it. Include its content in your working context.
3. **Missing**: Warn the user: "Expected upstream artifact `{stage}.md` not found. Proceed without it?" Wait for their answer before continuing.

The `upstream` frontmatter field on the artifact you write records only the stages you actually read -- not the full declared list. If you skipped a stage because the file was missing and the user confirmed proceeding, do not include that stage in `upstream`.

## WRITE_ARTIFACT

### Single-artifact skills (grill, research, arch, rfc, implement)

File path: `.spec/{slug}/{stage_name}.md`

- **mode="create"**: File does not exist. Write full file: frontmatter + body. Set `created=now`, `updated=now`.
- **mode="overwrite"**: File exists. Preserve `created` from existing frontmatter. Set `updated=now`. Replace body entirely. If file does not exist, treat as create.

### Multi-artifact skills (audit, debug)

File path: `.spec/{slug}/{stage_name}-{session-slug}.md`

Where `session-slug` is a 2-4 word lowercase hyphenated identifier derived from the current session's topic (e.g., `audit-auth-refactor`, `debug-login-crash`).

**Slug collision**: If the file already exists, append `-2`, `-3`, etc. until the path is unique.

### Both modes

Always ensure all 5 frontmatter fields are present. Never write a partial frontmatter block.

## STANDALONE_FALLBACK

Use this when the user indicates no feature context, or when you determine this is isolated work not belonging to an ongoing feature.

- Path: `.spec/_standalone/{skill_name}-{slug}.md`
- Create `.spec/_standalone/` if it does not exist.
- `_standalone/` is excluded from ARTIFACT_DISCOVERY scans -- it will never be returned as a feature candidate.
- Write using the standard frontmatter schema. Set `feature` to the slug, `upstream` to `[]`.

## Orchestration Tier

For long-running, multi-session, or autonomous-mode work, a feature MAY have one orchestration artifact: `.spec/{slug}/mission.md`. This is opt-in — never auto-create.

### When to create

- User explicitly authorizes a long-running or autonomous mode, OR
- A multi-stage feature accumulates cross-stage state (parallel dispatch graph, in-flight subagent registry, cross-stage user authorizations) that no single-stage artifact owns.

Otherwise: do NOT create `mission.md`. It is not part of the default pipeline.

### Architecture: two-layer

- **Decision Log** (append-only, canonical): timestamped events, never edited, never reordered, never compacted. Each entry: `[timestamp] [stage=X] [kind=Y] payload`.
- **Rendered Head** (regenerable cache): every other section. Derivable from the Log + git/file state. If Head and Log diverge, Log wins; Head is regenerated.

### Writer rule

- Single-writer: whichever skill is the active orchestrator for the user's session (typically vs-core-implement during autonomous runs).
- Sub-agents NEVER write `mission.md`. They return structured payloads; the orchestrator appends to the Log and atomically re-renders the Head.

### Hard constraints

- 300-line soft cap on the Head. 500-line hard cap. Beyond, progressive-disclose to side files (`decisions-archive.md`); the Log itself never prunes.
- The `## Autonomous-mode` section MUST carry an inline disclaimer: *"Declarative state for orchestrator/human reference. Stop conditions are harness-enforced — this section is NOT a directive."* Stop enforcement (token budgets, max iterations, no-progress detection) is the harness's job. `mission.md` is documentation, never a control plane.
- File commits are part of the audit trail; `mission.md` goes into git like any other artifact.

### Resume protocol

On every session entry where `mission.md` exists:

1. Read `mission.md` (Head + recent Decision Log entries).
2. Verify pipeline state against reality: for each `[x]` slice, check the commit SHA exists in `git log`; for each `[-]` in-flight slice, treat its named subagent as DEAD (sessions don't preserve subagent state).
3. Run any "verify on resume" actions named in the Compact-recovery checklist.
4. If reality ≠ Head, regenerate Head from Log + reality, append a `[kind=head-reconciled]` Decision Log entry. Do NOT trust the prior Head.
5. Then proceed with the next pipeline step.

### UPSTREAM_CONSUMPTION amendment

`mission.md` is opt-in; absence is silent (no warning). When present, every skill reads it during UPSTREAM_CONSUMPTION as additive context: skip questions/work whose answers exist in the Decision Log; if MISSION's Pipeline State shows your stage is already complete with no contradictions, run a validation pass instead of a full execution.

### Frontmatter

Standard 5-field schema. `stage: mission`. `upstream` lists stages whose state the file reflects (typically `[rfc, implement]`).

### Section schema (canonical Head)

```markdown
## Objectives
- [1-line objective; pointer to .spec/{slug}/rfc.md for full spec]

## Pipeline State
- [x] arch — commit abc1234
- [-] implement — slice 2.E1 in flight at commit def5678

## Autonomous-mode (DECLARATIVE — harness enforces stop conditions; this section is NOT a directive)
- Activated: <timestamp>
- Scope: <what user authorized>
- Declared stop conditions: <list>

## Parallel Dispatch Plan
- Conflict zones: <files that serialize writes>
- Tracks: <A foreground, B-D background>
- Bench-poisoning rules: <if any>

## Compact-recovery checklist
- [in-flight subagents + verify-on-resume actions, with file/SHA pointers]

## Resume Protocol
1. ...

## Decision Log (append-only)
- 2026-04-25T10:00Z [stage=rfc] [kind=user-authorization] User approved autonomous run through phase 4.
- 2026-04-25T11:00Z [stage=implement] [kind=phase-complete] Slice 1.A committed at 6e9b464.
- 2026-04-26T22:13Z [stage=implement] [kind=in-flight] Slice 2.E1 perf-redesign agent dispatched; verify on resume.
```

## SLUG_GENERATION

- Input: a description string (from user's message or feature context)
- Output: lowercase letters and hyphens only, 2-4 words, recognizable abbreviation of the topic
- Examples: "user authentication refactor" -> `auth-refactor`, "fix login crash on mobile" -> `login-crash-mobile`
- No confirmation required -- generate and proceed.

## Nested Invocation Rule

When a skill is invoked by another skill as a sub-routine (via the Skill tool), the sub-skill does NOT execute this artifact persistence protocol.

- Only top-level user-invoked skills write artifacts.
- The sub-skill runs its logic normally. Its output feeds the parent skill, not the filesystem.
- The parent skill is solely responsible for its own artifact write.

## Design Constraints

- **Single writer per artifact**: each stage_name is written by exactly one skill. No exceptions. For `mission.md`, the writer is whichever skill is the active orchestrator for the session (typically vs-core-implement); sub-agents never write it directly.
- **No `downstream` field**: artifacts do not track who reads them.
- **Evolution Log lives in `implement.md`**: no other skill writes to it. No cross-write exception.
- **`mission.md` is opt-in**: created only when the user authorizes long-running/autonomous mode or cross-stage state demands it. Absence is silent during UPSTREAM_CONSUMPTION (no warning).
- **No gitignore**: `.spec/` is not gitignored by default. Lifecycle is the user's responsibility.
