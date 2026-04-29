# CLI and execution model

*Level: loop-kernel (universal across archetypes and target types).*

The skill exposes two commands. Everything else is per-instance configuration.

```
/vs-core-autoloop scaffold --kind {optimization|coverage} --instance <slug>
/vs-core-autoloop run --instance <slug>
```

`scaffold` is run once per new loop. `run` is invoked by the execution driver each tick.

## `scaffold`

Procedure:

1. Validate `--kind` is one of the two archetypes.
2. Validate `--instance` is kebab-case. If `.spec/<slug>/` already exists:
   - If it contains a complete `mission.md` (Head + non-empty Decision Log with at least one `[kind=user-authorization]` entry): error with "instance already scaffolded; use `scaffold --migrate --instance <slug>` to re-render from updated bases, or pick a different instance name."
   - If it exists but `mission.md` is missing or its Decision Log has no `[kind=user-authorization]`: this is a partial scaffold from an interrupted prior run. Error with "partial scaffold detected at .spec/<slug>/. Either `rm -rf .spec/<slug>/` to retry from scratch, or pass `--resume` to attempt to complete the missing steps. The current scaffold protocol does not auto-resume."
3. Run the scaffold-time grill (`vs-core-grill` invocation).
4. Calibrate the noise floor (per [`noise-floor-calibration.md`](noise-floor-calibration.md)).
5. Emit the artifact tree under `.spec/<slug>/` in this order: `queue/` and `archive/` directories first; then `MANDATES.md`, `LOOP.md`, `falsifiers.md`, `PROMPT.md`; then **last**, `mission.md` with the initial `[kind=user-authorization]` Decision Log entry. The mission.md write is the commit point — its presence indicates the scaffold completed successfully.
6. Print the paste-ready /loop invocation.

### Scaffold-time grill topics

- Target unit (what is one item being iterated on?)
- Measurement primitive (which tool produces the verdict input?)
- Headline objective + sacred axes (optimization) OR worklist source-of-truth tool (coverage)
- Win condition (initial bar; escalation rule)
- Revert protocol (one of four)
- Whether human-in-loop lanes are needed (and the routing policy)
- Mechanism-class taxonomy (idea categories for the queue)
- Per-iter wall-clock cap (per-target hang protection; instance-specific)
- Cross-target guard's tier-1 set (if applicable)
- Fingerprint extension fields (instance-specific environment fields beyond the universal ones)

The grill's answers are recorded in `mission.md`'s initial `[kind=user-authorization]` Decision Log entry per [`directory-layout.md`](directory-layout.md) § "Decision Log kinds". Re-running scaffold (e.g., after a base-mandate update) reads that entry and re-renders MANDATES from base + overlay + grill answers without re-asking; the migration appends a `[kind=base-migrated]` entry recording the version delta.

### Output

After scaffold completes, the user gets a printed invocation:

```
Loop scaffolded at .spec/<slug>/

To run a 48h Karpathy-style session:
    /loop --budget 48h /vs-core-autoloop run --instance <slug>

To run on a cron schedule:
    /schedule '0 */6 * * *' /vs-core-autoloop run --instance <slug>

To run a single iter (debugging):
    /vs-core-autoloop run --instance <slug>
```

## `run`

Procedure (the loop kernel from [`loop-kernel.md`](loop-kernel.md)):

```
1.  RENDER STATE         [harness]
2.  ACQUIRE LOCK         [harness]
3.  ENVIRONMENT CHECK    [harness]
4.  SELECT TARGET        [harness]
5.  SELECT IDEA          [agent]
6.  RUN FALSIFIER        [harness]
7.  IF FALSIFIED         [harness] → log, mark idea, return (next tick)
8.  APPLY CHANGE         [agent]
9.  MEASURE              [tool]
10. RENDER VERDICT       [harness]
11. APPLY VERDICT        [harness]
12. APPEND HISTORY       [harness]
13. RELEASE LOCK         [harness]
```

Each invocation runs **one iter**. The execution driver invokes `run` repeatedly.

### Output per invocation

- The verdict (one of 8) printed to stdout.
- New Decision Log entries appended to `.spec/<slug>/mission.md` (`[kind=verdict]`, optional `[kind=keep]`, optional `[kind=lesson]`).
- Re-rendered Head sections in `.spec/<slug>/mission.md` (Pipeline State, Scoreboard, Compact-recovery checklist).
- New archive snapshot under `.spec/<slug>/archive/iter-<N>/` (manifest, measurement, change.diff).
- Possibly a new commit/branch/snapshot per the revert protocol.

### Idempotency

`run` is **not** idempotent — it makes the system advance one iter. The lock prevents concurrent invocations.

If `run` is invoked while another invocation holds the lock, it fails fast with `crash` (description=`lock_held`) and exits non-zero. The execution driver retries on the next tick.

## Execution drivers

The skill itself does not loop. A driver does.

### `/loop`

User-facing loop driver with a budget:

```
/loop --budget 48h /vs-core-autoloop run --instance <slug>
```

`--budget` is the session ceiling. `inf` is the default if omitted; user passes time-bounded values for Karpathy-style overnight runs. Common values: `1h`, `8h`, `48h`, `1week`.

`/loop` invokes `run` repeatedly until budget exhausts or the user interrupts. There is no per-iter cap at the loop level — hang protection lives inside the measurement adapter.

### `/schedule`

Cron-style driver:

```
/schedule '0 */6 * * *' /vs-core-autoloop run --instance <slug>
```

Useful for sustained workloads where one iter every six hours is enough (e.g., long-baseline measurements, expensive eval sets, daily cleanups).

### Manual `run`

For debugging:

```
/vs-core-autoloop run --instance <slug>
```

Single iter; user can inspect state and archive between invocations.

## Budget model

The budget is **always at the driver level**, never inside the autoloop skill. Reasons:

- Different drivers have different budget semantics (`/loop` is wall-clock; `/schedule` is iter-frequency).
- The skill's `run` is one iter; budget is a session concept.
- Mixing the two creates the failure mode where the agent inside `run` second-guesses the driver's budget.

Per-iter wall-clock caps (hang protection) **are** at the skill level — but they live inside the measurement adapter, target-type-specific, never user-facing.

## Per-target hang protection

Each measurement primitive declares a wall-clock cap when registered with the autoloop skill. Examples (cited as patterns, not as the skill's prescription):

- A perf-bench primitive might declare `max_wall_clock_seconds = 30` for a single measurement run.
- An eval-set primitive might declare `max_wall_clock_seconds = 600` for a full eval.
- An ELO match runner might declare `max_wall_clock_seconds = 7200` for a tournament round.

The wrapper enforces the cap with `timeout` (or equivalent). If the cap fires, the wrapper kills the process and emits `hang`.

The user does not configure these caps per-iter. They're target-type defaults. Instances can override at scaffold time.

## Composition with sibling skills

These are opt-in. The agent invokes them via the Skill tool **inside** an iter (typically at step 5 SELECT IDEA, when the queue is empty and inline refill is insufficient).

| Sibling | Typical invocation |
|---|---|
| `/vs-core-grill` | At scaffold; not during iters |
| `/vs-core-research` | At step 5, when queue is empty AND gap to win condition is wide |
| `/vs-core-audit` | After step 11, before lock release, on high-stakes keeps |
| `/vs-core-debug` | Out-of-band; pause the loop and debug |
| `/vs-core-profile-amd` (or other measurement-specific) | Inside the measurement primitive at step 9 |

The skill never *requires* sibling invocation. The loop kernel works with inline reasoning at every step.

## Multi-instance coordination

Multiple instances can share a host. Each has its own `.spec/<slug>/` directory.

Locks are per-measurement-primitive, not per-instance. Two instances sharing a primitive serialize on the same lock.

A hybrid loop is two instances:

- `<base>-outer` (coverage archetype, walks the worklist)
- `<base>-inner` (optimization archetype, runs per active item)

The driver invocation for hybrid loops:

```
/loop --budget 48h bash -c '
    /vs-core-autoloop run --instance <base>-outer
    # The Pipeline State section emits a literal `active_item=<id>` token per state-rendering.md.
    active_item=$(grep -oP 'active_item=\K\S+' .spec/<base>-outer/mission.md | head -1)
    /vs-core-autoloop run --instance <base>-inner --scope "$active_item"
'
```

(Conceptual; the actual integration depends on the driver's shell semantics. The principle: outer's active item scopes the inner's grid.)

