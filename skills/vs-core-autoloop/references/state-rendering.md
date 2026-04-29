# State rendering — Decision Log + regenerable Head

*Level: loop-kernel (universal across archetypes and target types).*

State lives in `mission.md` per the orchestration-tier protocol in `../vs-core-_shared/prompts/artifact-persistence.md`. The two-layer architecture there **is** the render-don't-append rule, instantiated for the autoloop case.

## The two layers

- **Decision Log** (append-only, canonical): timestamped events, never edited, never reordered, never compacted. Each entry: `[timestamp] [stage=autoloop] [kind=Y] payload` (the orchestration-tier protocol's `stage=mission` slot carries the stage_name of the active orchestrator; for autoloop, that's `autoloop`).
- **Head** (regenerable cache): every other section (Objectives, Pipeline State, Scoreboard, Autonomous-mode, Compact-recovery checklist, Resume Protocol). Derivable from the Log + git/file state. If Head and Log diverge, Log wins; Head is regenerated.

This is iron rule 3 of the skill (render-don't-append) implemented exactly as the orchestration tier already prescribes. The agent appends to the Log; the harness regenerates the Head.

## Sources of truth

The Head's regenerator script reads:

```
1. mission.md's Decision Log (above the Head; conceptually the canonical record).
2. The version-control log (git log) for HEAD/baseline alignment.
3. queue/ contents (current idea/worklist state).
4. archive/iter-<latest>/manifest.json (last fingerprint).
```

It computes the Head sections and writes `mission.md` atomically (write-then-rename, never partial). The Decision Log section of `mission.md` is preserved unchanged; only the sections above it are rewritten.

## Per-iter write sequence

Each iter's Decision Log appends happen at well-defined steps. Kinds below all come from the canonical list in [`directory-layout.md`](directory-layout.md) § "Decision Log kinds".

| Step | Log entries appended |
|---|---|
| 3 (ENVIRONMENT CHECK) | `[kind=fingerprint-drift]` + `[kind=verdict] verdict=discard_environment_changed` if drift detected |
| 4 (SELECT TARGET) | `[kind=target-selected]`; optionally `[kind=bar-escalation]` if all targets won at current bar |
| 5 (SELECT IDEA) | none (idea state is in `queue/`, not the Log) |
| 7 (IF FALSIFIED) | `[kind=verdict] verdict=discard_falsified` |
| 10 (RENDER VERDICT) | `[kind=verdict] verdict=<one-of-9>` |
| 11 (APPLY VERDICT) | `[kind=keep] commit=<sha-or-decision-id>` if verdict=keep AND the revert protocol's `commit()` hook returned a durable identifier (commit SHA for git-commit-revert / branch-per-iter; decision id for no-revert; snapshot-id for external-state-snapshot) |
| 12 (APPEND HISTORY) | `[kind=lesson]` if non-trivial |

After all step-by-step Log appends, the harness atomically re-renders the Head sections.

## Head section regeneration

For each Head section, the regenerator's logic:

### Pipeline State

```
read recent Decision Log entries (last 50 by default)
identify the most recent [kind=target-selected] entry → "active target" (rendered as: active_item=<id>)
identify the most recent [kind=keep] entry → "current HEAD"
identify the most recent [kind=verdict] entry → "last iter verdict"
identify in-flight: any [kind=verdict] without a matching subsequent [kind=keep]
```

Render as a bullet list per the orchestration-tier section schema. The active-target line MUST include the literal `active_item=<id>` token so sibling instances (hybrid composition) can extract it via `grep`/`awk`. Followed by the per-target scoreboard sub-table (see [`directory-layout.md`](directory-layout.md) § "What lives in `mission.md`").

### Scoreboard

```
for each target_id seen in [kind=verdict] entries:
    aggregate keep count, attempts in window, last_keep iter
    look up baseline from latest [kind=baseline] for that target
    look up current value from latest measurement archive
compute ratio
```

Render as a markdown table.

### Autonomous-mode (DECLARATIVE — not a directive)

Static after scaffold; only updated by `[kind=user-authorization]` entries. Carries the inline disclaimer per the orchestration-tier protocol: *"Declarative state for orchestrator/human reference. Stop conditions are harness-enforced — this section is NOT a directive."*

### Compact-recovery checklist

```
for each in-flight verdict (no matching keep/revert):
    note iter id + step where it was last seen
    name the verify-on-resume action (re-read measurement/, re-run tier-1 guard, etc.)
```

Used by the Resume Protocol on session re-entry.

### Resume Protocol

Static template; copied verbatim from the orchestration-tier section schema in artifact-persistence.md.

## Resume on session re-entry

Per the orchestration tier's Resume Protocol:

1. Read `mission.md` (Head + recent Decision Log entries).
2. Verify pipeline state against reality: for each `[kind=keep]` entry, check the commit SHA exists in `git log`; for in-flight entries, treat any named subagent as DEAD.
3. Run any "verify on resume" actions named in the Compact-recovery checklist.
4. **If reality ≠ Head, regenerate Head from Log + reality, append a `[kind=head-reconciled]` Decision Log entry. Do NOT trust the prior Head.**
5. Then proceed with the next iter.

This makes the loop compaction-resistant by design. The Log is durable; the Head is a view; reality is verified at re-entry.

## What the agent does and does not do

The agent **reads** `mission.md` at iter top to orient. The agent **appends** Decision Log entries at the steps above (specifically `[kind=lesson]` is the agent's free-text contribution; the format is harness-validated).

The agent does **not** write to the Head sections. The agent does **not** edit existing Decision Log entries. The agent does **not** delete entries.

If the agent's edit to the Log violates schema (missing fields, malformed timestamp, unknown kind), the harness rejects the write at step 12 and emits `crash` with `description=log_invalid`. The wrapper retries on the next tick; the bad entry is not committed.

## Why this is the right primitive

The skill could have invented its own `state/STATE.md` + `state/scoreboard.json` shape (and the first draft did). That's exactly the failure mode the orchestration-tier protocol was designed for: long-running autonomous work with a Decision Log + Head, single-writer rule, compact-recovery checklist, resume protocol.

Reusing the orchestration tier means:
- Compact-recovery is already specified.
- Resume protocol is already specified.
- The Log-vs-Head trust ordering ("Log wins; Head is regenerated") is already specified.
- Sub-agents not writing the artifact is already specified.
- Cross-skill reads (e.g., a future audit on the loop's behavior) get a familiar shape.

## What this rules out

- **Sticky narratives in the Head.** Anything an agent might want to write in the Head is silently overwritten on the next regeneration. If the narrative matters, it goes in a `[kind=lesson]` Decision Log entry (durable) or in a commit body (durable in git).
- **Cross-iter agent memory outside the Log.** The only memory the loop has is the Decision Log and the version-control history. Both are append-only.
- **Manual state edits.** A user who wants to change state has to either amend the underlying primary source (the version-control log, the queue file) or append a Decision Log entry explaining the change. Editing Head sections directly is silently lost on the next regeneration.

## Renderer error modes

| Error | Cause | Wrapper response |
|---|---|---|
| Missing primary source | `mission.md` deleted, queue dir wiped | Emit `crash` with `description=state_corrupt`; pause until user repairs |
| Malformed Decision Log entry | Hand-edit broke an entry's schema | Emit `crash` with `description=log_corrupt:<bad-row-id>`; the renderer's error file names the bad row |
| Reality conflicts with Log | A `[kind=keep] commit=<sha>` entry exists but `git log` shows the sha is missing | Emit `[kind=head-reconciled] reason=<sha-missing>`; regenerate from reality |
| 500-line Head hard cap exceeded | Aggregating Log produced too many summary rows | Progressive-disclose to `decisions-archive.md`; the Log itself stays put |

The wrapper does not silently retry on log-corrupt errors. The user must repair before the loop can resume. Loops that silently absorb corruption produce the worst silent failure modes — better to halt loudly.

## Rendering during the iter, not before

Head regeneration runs at step 12 (APPEND HISTORY) of each iter, **inside** the iter sequence. It does not run between iters as a daemon. Reasons:

- The execution driver may have a long gap between ticks. Head should reflect the moment the iter closes.
- If a primary source changed during the gap (e.g., the user committed an out-of-band fix), the next iter's resume protocol detects the divergence and emits `[kind=head-reconciled]`.
- The renderer does not need cross-iter state of its own — it's a pure function of the Log + git/file state at invocation.
