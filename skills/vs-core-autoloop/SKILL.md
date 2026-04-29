---
name: vs-core-autoloop
description: Scaffold and operate autonomous iteration loops on top of the orchestration tier (`mission.md`). Use when the user wants a long-running optimization or coverage loop driven by an agent without supervision, says "autoloop", "Karpathy-style autoresearch", "scaffold a loop", "run this overnight", "iterate forever on X", or describes any target with a measurable per-iter verdict (perf, eval, latency, lint, fuzz, ELO, cost, doc, dep, alert, security/PR triage, etc.).
---

## Artifact Profile

Read `../vs-core-_shared/prompts/artifact-persistence.md` for the full protocol — autoloop **operates on** the existing orchestration-tier artifact (`mission.md`) rather than owning a separate stage.

- **stage_name**: autoloop
- **artifact_filename**: mission.md (the orchestration-tier artifact; not a new file)
- **write_cardinality**: single
- **upstream_reads**: grill (when `scaffold` invokes `/vs-core-grill` to fill template slots; absent when run-only)
- **body_format**: the canonical orchestration-tier Head + Decision Log per `artifact-persistence.md` § "Section schema (canonical Head)" — autoloop adds no new top-level Head sections; the per-target scoreboard is a sub-table inside Pipeline State. Decision Log entries use the autoloop kind taxonomy enumerated in [`references/directory-layout.md`](references/directory-layout.md) § "Decision Log kinds". The Head is regenerable from Log + git/file state.

autoloop is the **active orchestrator** for the instance's session per the artifact-persistence § "Single-writer per artifact" carve-out: mission.md's writer is whichever skill is the active orchestrator, not strictly the holder of `stage_name: mission`. To prevent two orchestrators contending for the same mission.md, autoloop's `scaffold` and `run` acquire an exclusive lock on `.spec/<slug>/mission.md` for the duration of any write; if the lock is held by a vs-core-implement autonomous run on the same slug, autoloop fails fast and the user is asked to choose one orchestrator per slug. Different slugs are independent.

## Artifact Flow

1. **`scaffold` (first invocation per instance):** Run ARTIFACT_DISCOVERY (artifact-persistence.md). The instance slug becomes the feature slug. Invoke `/vs-core-grill` to fill open template slots (target unit, measurement primitive, sacred axes, mechanism class taxonomy, revert protocol, human-in-loop policy). The grill runs under the Nested Invocation Rule — its output feeds autoloop, no `grill.md` is written.
2. **After scaffold:** Run WRITE_ARTIFACT — write `mission.md` to `.spec/{slug}/` with the orchestration-tier section schema. Set `upstream: [grill]`. Initial Decision Log holds one `[kind=user-authorization]` entry capturing the scaffold's grill answers.
3. **`run` (per-iter invocation by execution driver):** Read `mission.md` per the Resume Protocol in artifact-persistence.md. Verify pipeline state against reality (HEAD sha, archive/, queue/). Run the loop kernel for one iter. Append per-iter Decision Log entries (one `[kind=verdict]` row, plus `[kind=lesson]` if non-trivial). Atomically re-render the Head sections from the updated Log + git/file state.

# Generic autonomous iteration loop

Scaffolds an `.spec/<instance>/` artifact tree for an iteration loop and emits a paste-ready prompt the user can feed to `/loop`, `/schedule`, or any other execution driver. Orthogonal to the runner — this skill writes templates and per-iter playbooks; it does not execute iterations itself.

The skill ships two archetypes that cover the iteration-loop space:

| | `optimization` | `coverage` |
|---|---|---|
| **Target unit** | A point in some space (slice, configuration, item under tuning) | An enumerable item (file, op, finding, ticket) |
| **Verdict** | Numeric objective + sacred axes | Boolean done + reason |
| **Termination** | Bar escalation; never self-stops | Worklist drained AND no new items in N iters |
| **Queue shape** | Quality-diversity grid + island reset | Tagged worklist with named lanes |
| **Failure mode it avoids** | Premature convergence to a local optimum | Re-proposing already-resolved items |

Hybrid loops compose by stacking — outer coverage walks a worklist, inner optimization runs per item. There is no single primitive that does both.

## When to use this skill

- The user wants an autonomous loop that grinds on a target for hours-to-days.
- The target has a **measurable verdict per iter** (a number, a boolean, a Pareto vector).
- The user is willing to define a noise floor and sacred axes once at scaffold time.
- The user has, or wants to set up, an execution driver (`/loop`, `/schedule`, cron) that will repeatedly invoke the loop.

## When NOT to use this skill

- The task is one-off (fix this one bug, write this one feature). Use the relevant per-task skill (`vs-core-debug`, `vs-core-implement`, etc).
- There is no measurable verdict — the loop has nothing to gate on.
- The work is fundamentally interactive and cannot be ratified by a renderer script.
- The user wants the agent to *decide* what to optimize (use `vs-core-grill` or `vs-core-research` first to scope a target).

## The two commands

```
/vs-core-autoloop scaffold --kind {optimization|coverage} --instance <slug>
/vs-core-autoloop run --instance <slug>
```

`scaffold` runs once per new loop; it sets up the artifact tree and emits the paste-ready prompt. `run` is what the execution driver invokes each tick; it re-renders state and prints the per-iter playbook.

If invoked with no subcommand, ask the user which one they want and confirm `--kind` + `--instance`.

## The four iron rules

These hold for every instance, both archetypes, every iter. They are the only line of defense against the failure modes that took down prior autonomous-loop projects (gaming, hallucinated tool results, stale-state confirmation loops, runaway cost).

1. **Harness owns ground truth; agent owns hypothesis.** Locks, fingerprints, measurement output, verdicts, scoreboards — all written by harness scripts. Hypothesis text, mechanism notes, commit messages — written by the agent. No artifact is co-authored. See [`references/harness-agent-split.md`](references/harness-agent-split.md).

2. **Variance characterization before optimization.** Every measurement primitive has a noise floor. Calibrate it at scaffold time by running the primitive K times under no-change conditions and recording the dispersion. Any iter delta below `k × noise_floor` is rejected as `discard_objective` with `description=below_floor`. See [`references/noise-floor-calibration.md`](references/noise-floor-calibration.md).

3. **Render-don't-append for STATE.** STATE is regenerated each iter from primary sources, never written to by the agent. If STATE disagrees with reality, the renderer reconciles on the next iter; the agent never edits STATE to "correct" it. See [`references/state-rendering.md`](references/state-rendering.md).

4. **Falsifier before iteration.** Every idea ships a `false_signal` field — the cheapest experiment that disproves the mechanism. The harness runs `false_signal` first; if it fires, the idea is rejected as `discard_falsified` without applying the change. See [`references/falsifier-registry-schema.md`](references/falsifier-registry-schema.md).

## The loop kernel (13-step sequence)

The same sequence runs both archetypes. Step ownership in brackets.

```
1.  ACQUIRE LOCK         [harness]   flock or equivalent on the measurement primitive
2.  RENDER STATE         [harness]   re-derive Head from Decision Log + git/file state
3.  ENVIRONMENT CHECK    [harness]   emit fingerprint; abort if changed since last keep
4.  SELECT TARGET        [harness]   lowest-density argmin over recent attempts
5.  SELECT IDEA          [agent]     pick from queue; refill if empty
6.  RUN FALSIFIER        [harness]   execute the idea's false_signal experiment first
7.  IF FALSIFIED         [harness]   log discard_falsified, mark idea, goto 4
8.  APPLY CHANGE         [agent]     smallest possible change matching the hypothesis
9.  MEASURE              [tool]      the target type's measurement primitive
10. RENDER VERDICT       [harness]   compute verdict from measurement + thresholds
11. APPLY VERDICT        [harness]   commit/revert per the instance's revert protocol
12. APPEND HISTORY       [harness]   archive iter snapshot, append Log entries, re-render Head
13. RELEASE LOCK         [harness]
```

Steps 5 and 8 are the only places the agent operates. Everything else is mechanical. See [`references/loop-kernel.md`](references/loop-kernel.md).

## What `scaffold` does

When invoked, perform these steps in order. If anything is unclear, invoke `/vs-core-grill` to interview the user; do not guess.

1. **Confirm `--kind` and `--instance`.** Validate slug is kebab-case and `.spec/<instance>/` does not already exist.
2. **Run the scaffold-time grill.** Topics to resolve before writing files:
   - The target unit (what is one item being iterated on?)
   - The measurement primitive (what tool produces the verdict input?)
   - The headline objective + sacred axes (optimization) OR the worklist source (coverage)
   - The win condition (bar at scaffold time; escalation rule)
   - The revert protocol (one of four — see [`references/revert-protocol-variants.md`](references/revert-protocol-variants.md))
   - Whether human-in-loop lanes are needed
   - The mechanism-class taxonomy (idea categories for the queue)
3. **Calibrate the noise floor.** Run the measurement primitive K times under no-change conditions; record dispersion as the discard threshold for that target type. K defaults to 8; user can override.
4. **Write the artifact tree** (full layout in [`references/directory-layout.md`](references/directory-layout.md)).
5. **Render `MANDATES.md`** from the base mandates + the archetype overlay + grill answers.
6. **Render `LOOP.md`** as the per-archetype 13-step playbook with concrete step contracts for this instance.
7. **Initialize `falsifiers.md`** with the schema + the mechanism classes from the grill, each with a worked example falsifier.
8. **Render `PROMPT.md`** as the paste-ready /loop input. The PROMPT instructs the agent to invoke `/vs-core-autoloop run --instance <slug>` each tick.
9. **Print** the paste-ready invocation to the user, e.g.:
   ```
   /loop --budget 48h /vs-core-autoloop run --instance <slug>
   ```

## What `run` does each tick

When invoked by the execution driver:

1. Re-render STATE (rule 3 above; see [`references/state-rendering.md`](references/state-rendering.md)).
2. Acquire the lock (see [`references/lock-and-fingerprint-protocol.md`](references/lock-and-fingerprint-protocol.md)).
3. Check the environment fingerprint; if it has changed without a re-baseline, emit `discard_environment_changed` and stop the iter.
4. Select target via lowest-density argmin (see [`references/lowest-density-target-selection.md`](references/lowest-density-target-selection.md)).
5. Select idea: if the queue has at least one `pending` idea for the target, pick the highest-priority one. If empty, refill — either inline (read existing references; combine two near-misses; look at the runners-up in the scoreboard) or by invoking `/vs-core-research` if the gap is wide.
6. Run the falsifier; emit `discard_falsified` if it fires.
7. Apply the smallest change matching the hypothesis. Do not refactor adjacent code.
8. Measure (call the target type's measurement primitive).
9. Render verdict (see [`references/verdict-rendering.md`](references/verdict-rendering.md)).
10. Apply verdict via the instance's revert protocol.
11. Append history (results row, archive snapshot, lesson if non-trivial).
12. Release lock.
13. Return — the execution driver will invoke again on the next tick.

The agent never decides the verdict; the renderer script does. The agent reads the latest `[kind=verdict]` entry in `mission.md`'s Decision Log at step 11 and acts accordingly.

## Composition with sibling skills

These are **opt-in**. Use them when they save time; iterate inline when dispatching is slower than doing the work directly.

| Sibling | When to invoke | Where in the loop |
|---|---|---|
| `vs-core-grill` | At scaffold time, to resolve open template slots | `scaffold` step 2 |
| `vs-core-research` | When the idea queue is empty and the gap to the win condition is wide | `run` step 5 |
| `vs-core-audit` | When stakes warrant adversarial review (a high-leverage `keep`, a sacred-axes-boundary change, a verdict that doesn't smell right) | After step 11, before lock release |
| `vs-core-debug` | When a `crash` or `hang` verdict recurs and the cause is unclear | Out-of-band; pause the loop |
| `/vs-core-profile-amd` (or other measurement-specific skill) | When the target type involves AMD CPU profiling | Inside the measurement primitive at step 9 |

The skill never *requires* sibling invocation. The loop kernel works with inline reasoning at every step.

## Per-archetype recipes

- [Optimization archetype recipe](references/archetype-optimization.md) — quality-diversity grid, double selection, island reset, bar escalation.
- [Coverage archetype recipe](references/archetype-coverage.md) — signature-bucketed worklist, named lanes, dedup-then-pick selection.
- [Hybrid composition](references/archetype-coverage.md#hybrid-composition) — outer coverage + inner optimization stacking.

## All references

- [`loop-kernel.md`](references/loop-kernel.md) — 13-step sequence; per-step contracts.
- [`harness-agent-split.md`](references/harness-agent-split.md) — author per artifact; rationale.
- [`archetype-optimization.md`](references/archetype-optimization.md) — quality-diversity grid recipe.
- [`archetype-coverage.md`](references/archetype-coverage.md) — bucketed worklist + lanes recipe.
- [`directory-layout.md`](references/directory-layout.md) — `.spec/<instance>/` skeleton + git-tracking rule.
- [`verdict-rendering.md`](references/verdict-rendering.md) — 8-value enum + renderer-script contract.
- [`falsifier-registry-schema.md`](references/falsifier-registry-schema.md) — three-criteria template; YAML frontmatter.
- [`lock-and-fingerprint-protocol.md`](references/lock-and-fingerprint-protocol.md) — locking primitive + environment-fingerprint schema.
- [`noise-floor-calibration.md`](references/noise-floor-calibration.md) — calibration protocol; per-primitive examples.
- [`lowest-density-target-selection.md`](references/lowest-density-target-selection.md) — argmin algorithm + bar escalation.
- [`state-rendering.md`](references/state-rendering.md) — render-don't-append rule + renderer skeleton.
- [`revert-protocol-variants.md`](references/revert-protocol-variants.md) — four protocols; hook signatures.
- [`human-in-loop-lanes.md`](references/human-in-loop-lanes.md) — queue-lane pattern; defer-vs-skip.
- [`cli-and-execution.md`](references/cli-and-execution.md) — `scaffold` and `run` command details; budget; `/loop` integration.
- [`case-studies/`](references/case-studies/) — worked examples per target type (read for instantiation patterns; not part of the skill body).
