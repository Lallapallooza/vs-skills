# Loop kernel — the 13-step sequence

*Level: loop-kernel (universal across archetypes and target types).*

The same sequence runs both archetypes. Step ownership in brackets.

```
1.  ACQUIRE LOCK         [harness]
2.  RENDER STATE         [harness]
3.  ENVIRONMENT CHECK    [harness]
4.  SELECT TARGET        [harness]
5.  SELECT IDEA          [agent]
6.  RUN FALSIFIER        [harness]
7.  IF FALSIFIED         [harness]    → log, mark idea, goto 4
8.  APPLY CHANGE         [agent]
9.  MEASURE              [tool]
10. RENDER VERDICT       [harness]
11. APPLY VERDICT        [harness]
12. APPEND HISTORY       [harness]
13. RELEASE LOCK         [harness]
```

Two principles drive every step:

- **Each step's owner is the only one who writes** the artifact that step produces. The agent never writes harness artifacts. The harness never makes choices that require judgment.
- **Failures fall through cleanly.** If any step fails, control returns to step 4 (next iter) with a logged verdict. The loop never hangs on a single iter.

## Step contracts

### 1. ACQUIRE LOCK [harness]

Acquire an exclusive lock on the measurement primitive **before** any state rendering. Lock-then-render is the standard discipline: it prevents two concurrent `run` invocations from both rendering Heads against the same Decision Log and racing on write-then-rename. The lock acquisition is the evidence that this iter has exclusive write rights.

The lock primitive is `flock(2)` by default; alternatives are documented in [`lock-and-fingerprint-protocol.md`](lock-and-fingerprint-protocol.md).

Lock scope: per-measurement-primitive, not per-instance. Two instances that share the same measurement primitive share the same lock. Additionally, autoloop's `run` acquires a per-slug lock on `.spec/<slug>/mission.md` to prevent contention with vs-core-implement autonomous runs on the same slug.

**Failure mode:** if the lock is held by another process, fail fast with `crash` (`description=lock_held`). Do not wait. Do not poll. The execution driver retries on the next tick.

### 2. RENDER STATE [harness]

Re-render the Head sections of `mission.md` from the Decision Log + git/file state. The Decision Log is preserved unchanged; only the sections above it (Objectives, Pipeline State with embedded scoreboard sub-table, Autonomous-mode, Compact-recovery, Resume Protocol) are rewritten.

This implements the Resume Protocol from `../vs-core-_shared/prompts/artifact-persistence.md` orchestration tier: verify pipeline state against reality, append a `[kind=head-reconciled]` Decision Log entry if reality ≠ the prior Head, then proceed.

Primary sources:

- The Decision Log section of `mission.md` (the canonical record).
- The version-control log (or the equivalent under the instance's revert protocol) for HEAD/baseline alignment.
- The current contents of `queue/`.
- The most recent `archive/iter-*/manifest.json`.

The renderer overwrites Head sections atomically (write-then-rename). The agent has not written to the Head between iters; if it had, those edits are lost.

**Failure mode:** if a primary source is missing or `mission.md` itself is corrupt, the renderer exits non-zero. The execution driver treats this as `crash` with `description=state_corrupt` and pauses until the user repairs.

### 3. ENVIRONMENT CHECK [harness]

Emit the environment fingerprint (per the schema in [`lock-and-fingerprint-protocol.md`](lock-and-fingerprint-protocol.md)). Compare to the fingerprint recorded at the most recent `keep`. If the fingerprint has drifted in any baseline-affecting field, emit `discard_environment_changed` and stop the iter without applying any change.

A fingerprint drift means the recorded baseline is stale; the next iter must re-baseline before any new comparison.

### 4. SELECT TARGET [harness]

Apply lowest-density argmin over the recent-attempts window. See [`lowest-density-target-selection.md`](lowest-density-target-selection.md).

If all targets are at or beyond the current bar, escalate the bar (optimization archetype) or terminate the loop (coverage archetype, if no new items have been discovered in the last N iters).

### 5. SELECT IDEA [agent]

Pick the highest-priority `pending` idea for the active target. If the queue is empty:

- **Inline refill (preferred):** combine two near-misses from recent `[kind=lesson]` entries in the Decision Log; read the runners-up in the Scoreboard section for the target's neighbors; consult any reference docs the user pointed to at scaffold time.
- **Sub-skill refill:** invoke `/vs-core-research` if the gap to the win condition is wide and the inline options have been exhausted.

The agent writes the new ideas to `queue/ideas/` (optimization) or `queue/worklist.tsv` (coverage). The agent does not write directly to `mission.md`'s Head sections — its only `mission.md` writes are appending Decision Log entries at the steps below.

If the idea has no `false_signal` field, the agent fills one in before proceeding. An idea without a falsifier is rejected at step 6.

### 6. RUN FALSIFIER [harness]

Execute the `false_signal` experiment per the idea's frontmatter. The experiment is by construction the cheapest available — it should run in seconds, not minutes.

If the experiment's output matches the `false_signal` predicate, the hypothesis is dead. Goto step 7.

### 7. IF FALSIFIED [harness]

Mark the idea `discard_falsified` in the queue. Append a results row with `verdict = discard_falsified` and the `false_signal` output as the description. Goto step 4 — pick a new target/idea pair on the next iter.

The change is **not applied**. The lock is **not released yet**; the loop reuses it for the next iter's measurement primitive.

### 8. APPLY CHANGE [agent]

Make the smallest possible change that tests the hypothesis. Do not refactor adjacent code. Do not bundle two ideas into one commit.

The change must:
- Compile, lint, parse, or otherwise pass the immediate sanity check the target type prescribes.
- Not weaken any assertion that exists in the test suite.
- Honor the instance's hard prohibitions (declared at scaffold time in `MANDATES.md`).

### 9. MEASURE [tool]

Invoke the measurement primitive. The primitive is target-type-specific; it could be a perf benchmark, an eval-set runner, a lint-pass count, an ELO match runner, etc.

The measurement primitive must:
- Be a single tool invocation, not an agent-orchestrated sequence.
- Emit machine-readable output to a known path under `archive/iter-<N>/measurement/`.
- Honor the per-iter wall-clock cap declared in the measurement adapter's config. If it exceeds the cap, the wrapper kills it with SIGKILL and returns `hang`.

### 10. RENDER VERDICT [harness]

The verdict-renderer script reads:
- `archive/iter-<N>/measurement/` (the new measurement)
- `archive/iter-<N-1>/measurement/` or the recent rolling window (the baseline)
- The calibrated dispersion (latest `[kind=baseline]` / `[kind=noise-recalibration]` entry in the Decision Log)
- The cross-target guard's tier-1 results (re-measured this iter on a small set of high-leverage targets)
- The functional/correctness test result

It emits one of the 8 frozen verdict values into `the latest [kind=verdict] entry in mission.md's Decision Log`. See [`verdict-rendering.md`](verdict-rendering.md).

The agent does not run the renderer. The agent does not see the renderer's logic. The agent reads the verdict.

### 11. APPLY VERDICT [harness]

Per the instance's revert protocol (one of four; see [`revert-protocol-variants.md`](revert-protocol-variants.md)):

- If `keep`: commit the change (or the revert protocol's equivalent of "make this durable"). Update the scoreboard. The change becomes the new baseline.
- If any `discard_*`: revert the change (or the protocol's equivalent of "abandon this attempt"). The baseline is unchanged.
- If `crash` or `hang`: revert; do not retry the same change.

If the verdict is `keep` and a tier-2 cross-target guard re-measurement is required for this instance, run it now. If tier-2 trips a regression, downgrade the verdict to `discard_guard` and revert.

### 12. APPEND HISTORY [harness]

Append per-iter Decision Log entries to `mission.md` (per [`state-rendering.md`](state-rendering.md)):
- `[kind=verdict]` with iter id, target, verdict, and measurement deltas.
- `[kind=keep] commit=<sha>` if verdict was `keep` and the revert protocol committed.
- `[kind=lesson]` if the iter is non-trivially informative (always for `keep`; conditionally for `discard_falsified` and `discard_objective`).
- `[kind=bar-escalation]` if all targets were won at the current bar and the bar advanced.

Then atomically re-render the Head sections (Pipeline State, Scoreboard, Compact-recovery checklist) from the updated Log + git/file state.

Per-iter measurement payloads (perf traces, eval outputs, change.diff, manifest.json) are written under `archive/iter-<N>/`. The Decision Log entries reference them by relative path; the archive holds large/binary content out of line from `mission.md`.

The lesson body is the agent's contribution; the Log row format is harness-enforced.

### 13. RELEASE LOCK [harness]

Release the lock. The execution driver invokes the next tick on its own schedule.

## Per-step ownership audit

| Step | Reads | Writes | Owner |
|---|---|---|---|
| 1 | none | (lock file) | harness |
| 2 | Decision Log + git + queue + last manifest | `mission.md` Head sections | harness |
| 3 | environment + last manifest | `archive/iter-N/manifest.json`; `[kind=fingerprint-drift]` Log entry if drifted | harness |
| 4 | Scoreboard (Head) + queue | (active target stored in Pipeline State on next render) | harness |
| 5 | queue + Log lessons + references | `queue/ideas/` or `queue/worklist.tsv` | **agent** |
| 6 | idea frontmatter | (false_signal output to stdout) | harness |
| 7 | false_signal output | `[kind=verdict] verdict=discard_falsified` Log entry; idea status in queue | harness |
| 8 | working tree | working tree | **agent** |
| 9 | working tree | `archive/iter-N/measurement/` | tool |
| 10 | measurement + noise floor (Log) + tier-1 + tests | `[kind=verdict]` Log entry | harness |
| 11 | latest `[kind=verdict]` | working tree (revert/commit); `[kind=keep] commit=<sha>` Log entry if applicable | harness |
| 12 | Log + measurement | `archive/iter-N/`; `[kind=lesson]` Log entry; re-render Head | harness |
| 13 | (lock file) | (lock file) | harness |

The agent's writes are confined to two places: the queue (step 5) and the working tree (step 8). Every other write is harness-mechanical.

## Failure modes per step

| Step | Failure | Recovery |
|---|---|---|
| 1 | Lock held | Emit `crash` (description=`lock_held`); driver retries next tick |
| 2 | Primary source corrupt | Emit `crash` (description=`state_corrupt`); re-invoke driver after backoff |
| 3 | Fingerprint drift | Emit `discard_environment_changed`; append `[kind=fingerprint-drift]`; pause until re-baseline |
| 4 | All targets won at all bars | Optimization: escalate the bar; coverage: terminate |
| 5 | No ideas, refill exhausted | Emit `crash` (description=`no_ideas`); pause until queue refilled by user |
| 6 | False-signal experiment crashed | Emit `crash` (description=`falsifier_crashed`); mark idea `crash`; goto 4 |
| 7 | (mechanical) | (no failure mode) |
| 8 | Change doesn't compile/parse/lint | Revert; emit `discard_test`; mark idea `discard_test`; goto 4 |
| 9 | Measurement primitive crashed | Revert; emit `crash` (description=`measurement_crashed`); goto 4 |
| 9 | Measurement exceeded wall-clock cap | Revert; emit `hang`; goto 4 |
| 10 | Renderer found a contradicting input (e.g. tier-1 regressed but headline improved) | Emit `discard_guard`; revert |
| 11 | Revert protocol's commit/revert hook failed | Emit `crash` (description=`revert_failed`); pause |
| 12 | (mechanical) | (no failure mode) |
| 13 | (mechanical) | (no failure mode) |

The loop never hangs. Every failure routes to a verdict that allows the next tick to proceed.
