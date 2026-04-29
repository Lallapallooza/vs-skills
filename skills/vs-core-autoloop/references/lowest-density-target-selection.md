# Lowest-density target selection

*Level: loop-kernel (universal across archetypes and target types).*

The active target at the top of every iter is the one with the **fewest recent attempts**. Parameter-free; rotates naturally.

## Algorithm

```
def select_active_target(targets, recent_window=20):
    candidates = [t for t in targets if t.status != "in-flight" and t.status != "won"]
    if not candidates:
        if all_targets_at_current_bar(targets):
            escalate_bar()
            candidates = [t for t in targets if t.status != "in-flight"]
        else:
            return None  # nothing to do; pause until queue refilled

    # Lowest-density argmin
    return min(candidates, key=lambda t: (
        attempts_in_window(t, recent_window),     # primary key
        -t.priority_score,                          # tiebreak: highest priority
        t.last_activity_iter                        # tiebreak: oldest activity
    ))
```

`attempts_in_window` counts iters in the last N iters that had `t` as the active target, regardless of verdict.

## Why parameter-free

Fixed advancement caps ("rotate after K consecutive non-keeps") have a published failure mode: simulated-annealing-style premature convergence to local optima. The K is arbitrary and has no good prior — too small wastes iters on barely-explored cells; too large lets one cell dominate the budget.

Lowest-density argmin avoids this by selecting based on **what's been attempted**, not on **how the attempts went**. A cell that just had K rejects is no more or less likely to be picked than a cell that just had K keeps — they have the same recent-attempt count.

This naturally rotates without the agent or operator having to tune anything. Rotation cadence is emergent from the number of targets and the window size.

## Heterogeneous targets

When targets have different costs (one iter on target A is 1 minute; one iter on target B is 30 minutes), naive lowest-density argmin may unfairly burden the cheap targets.

Variant: **time-weighted density**.

```
attempts_in_window = sum(t.iter_wall_clock_seconds for iter in recent_window if iter.target == t)
```

Each iter contributes its wall-clock cost rather than a count of 1. Cheap targets get more iters; expensive targets get fewer; total time per target is roughly equalized.

Instances with heterogeneous costs should declare this at scaffold time and the harness uses time-weighted density.

## Targets at different bars

When some targets are won at 0.95 and others are still at 1.20, naive lowest-density picks both equally — which means the loop continues spending iters on already-won targets just because their attempt count is low.

Variant: **bar-conditional filtering**.

```
candidates = [t for t in targets if not t.is_won_at_current_bar]
# If empty, escalate the bar; new candidates appear automatically.
```

Won targets re-enter the candidate pool only after bar escalation re-opens them.

This is the default behavior; non-default behavior would be to keep already-won targets in the rotation to detect post-keep regressions, which is a separate concern handled by the cross-target guard, not by target selection.

## Recent-attempts window size

The window size N controls how quickly the rotation cycles. Recommendations:

- **Small N (5-10)**: aggressive rotation; the loop touches every target frequently. Good when iter cycles are cheap or when targets are relatively independent.
- **Medium N (20-50)**: balanced. Default.
- **Large N (100+)**: slow rotation; the loop may grind on a target for many iters before rotating. Good when iters are expensive and targets benefit from sustained focus.

The window size is set at scaffold time and can be overridden by the user. There is no automatic tuning.

## Interaction with island reset

In the optimization archetype, when a cell accumulates K rejects with no keep, the cell is marked `exhausted`. Exhausted cells are excluded from the candidate pool until reset.

The reset re-seeds the cell from an adjacent cell's best keep and resets the cell's `recent_attempts` count to zero. After reset, the cell has the **lowest possible density**, so it will be picked first on the next iter — giving the re-seeded hypothesis a fair chance.

## Interaction with the coverage archetype

Coverage-archetype loops apply the same algorithm to worklist items rather than to optimization cells:

```
candidates = [item for item in worklist if item.lane == "pending"]
if not candidates: terminate or pause (per the archetype's termination rule)
candidates.sort(key=lambda i: (i.attempts, -i.priority_score, i.discovered_at))
return candidates[0]
```

`item.attempts` plays the role of "recent attempts in window" (coverage items are usually attempted once or twice and then resolved, so a window-less count works).

`item.priority_score` is the per-instance priority (severity, reachability, age, fix availability, etc.).

`item.discovered_at` is the iter when the item was added to the worklist; older items get picked first within ties.

## Bar escalation

Triggered when:

```
all(t.is_won_at_current_bar for t in targets if t.status not in {"exhausted", "blocked"})
```

The bar escalation step:

1. Tightens the bar one notch (per the instance's declared sequence — e.g., 0.95 → 0.90 → 0.85).
2. Re-opens won targets (status → `open`).
3. Resets attempt counts.
4. Appends a `[kind=bar-escalation]` entry to `mission.md`'s Decision Log with the old/new bar values and a one-line rationale.
5. The next iter picks the lowest-density target under the new bar.

Bar escalation is **mechanical**, not agent-decided. The instance's `MANDATES.md` declares the escalation sequence; the harness applies it.

## When to terminate vs escalate

For optimization-archetype: bar escalation is the default. The loop never self-terminates on "all targets won" — it just tightens the bar.

For coverage-archetype: termination on "worklist empty AND no new items in N iters" is the default. There is no bar to escalate; coverage is binary done.

The instance can override either default if the user wants explicit termination on optimization-archetype completion (e.g., for time-bounded experiments).

## Agent rationalizations the algorithm rejects

- **"This target keeps producing keeps; I'll spend more iters here."** The argmin depends only on attempt counts, not on past verdicts. Preferring high-yield targets re-introduces the local-optimum lock-in the algorithm is designed to avoid. A target that has produced many keeps will be rotated out exactly because its attempt count is high.
- **"This target keeps rejecting; I'll skip it."** Same reason in reverse — skipping low-yield targets means they accumulate the lowest density and get picked anyway. If a target genuinely cannot be optimized further, mark it `won` (or `exhausted` per the optimization-archetype reset rule); do not skip in selection.
