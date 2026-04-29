# Falsifier registry schema

*Level: loop-kernel (universal idea schema; archetype-level extensions are documented inline).*

Every idea ships a falsifier. The harness runs the falsifier first, before applying any change; if the falsifier fires, the idea is `discard_falsified` and the iter ends without measurement.

The protocol forces the agent to articulate, *before iterating*, what evidence would prove its mechanism wrong. This is the only mechanism in the loop that catches "the idea was directionally plausible but actually targets a non-cause" cheaply.

## Why this exists

Without a falsifier, an iter that fails goes to `discard_objective` — meaning the renderer can tell you the change didn't help, but it can't tell you whether the **mechanism the agent had in mind** was the actual cause.

Over hundreds of iters, this distinction matters: ideas that target a non-cause keep being re-proposed in slightly different forms. The falsifier kills the underlying class of ideas, not just the specific attempt.

## Universal idea schema

Every idea — regardless of archetype — carries the following frontmatter. The harness validates these fields at queue write time. Archetypes add fields on top; archetype-specific extensions are documented in [`archetype-optimization.md`](archetype-optimization.md) and [`archetype-coverage.md`](archetype-coverage.md).

```yaml
mechanism_class: <one of the registered classes for this target type>
hypothesis: <one-sentence>
true_signal: <observable that, if seen, supports the mechanism>
false_signal: <cheapest experiment that disproves the mechanism>
inconclusive_signal: <observable that means investigate other mechanism>
priority: <low | medium | high>
```

The shape of `true_signal`, `false_signal`, `inconclusive_signal` is the **three-criteria template** from pre-registration in empirical research. It is the only formalization of "what would falsify this hypothesis" that has working precedent.

### Archetype extensions

| Archetype | Adds | Where |
|---|---|---|
| optimization | `cell` (the quality-diversity grid cell), `recent_attempts`, `best_keep`, `last_reject`, `hypothesis_embedding` | [`archetype-optimization.md`](archetype-optimization.md) |
| coverage | `id`, `signature`, `lane`, `priority_score` (numeric, replaces the bare-enum `priority`), `discovered_at`, `last_attempt`, `attempts`, `defer_reason` (when in needs-human-review/blocked lane) | [`archetype-coverage.md`](archetype-coverage.md) |

Coverage archetype: the universal `priority` field is **not** present on coverage worklist rows; it's superseded by the numeric `priority_score`. The harness validator allows this archetype-specific override.

Coverage archetype: each worklist row's frontmatter carries the falsifier fields (`mechanism_class`, `true_signal`, `false_signal`, `inconclusive_signal`) when an attempt is in flight against the item; rows in `pending` lane that have not yet been attempted may have these fields empty until the agent populates them at iter step 5.

### `true_signal`

What you would expect to see if the mechanism is real. Not the headline metric improvement — that's the verdict's job. The `true_signal` is an observable that **specifically supports the proposed cause**, distinct from "the change happened to help."

Example shape (target-type-neutral): "tool X reports counter Y above threshold Z when the mechanism is active."

### `false_signal`

The cheapest experiment that, if performed, **disproves the mechanism without applying the change**. This is the falsifier the harness runs at iter step 6.

Properties of a good `false_signal`:

- **Cheap.** Runs in seconds, not minutes. Falsifiers that take longer than the measurement primitive are useless.
- **Decisive.** The result either fires (mechanism dead) or doesn't (proceed to apply change). No "maybe."
- **Independent of the change itself.** The falsifier must run **without** applying the proposed change. If it requires the change, it's not a falsifier — it's just a measurement.

The classic shape: "set parameter P to a value that disables the mechanism; if the symptom persists, the mechanism is not the cause."

### `inconclusive_signal`

What you would observe if neither `true_signal` nor `false_signal` definitively fires. Defaults to "noise; investigate other mechanism" for most ideas.

This field is the agent's reminder that not all falsifier outcomes are decisive. An inconclusive falsifier sends the agent to step 5 to pick a different idea, not to apply the current one.

## Per-target-type mechanism class taxonomy

The `mechanism_class` field is target-type-specific. The instance declares the taxonomy at scaffold time and stores it in `falsifiers.md`. Every idea must match one registered class.

Why this matters: the queue's diversity rule (in optimization archetype) and the dedup signature (in coverage archetype) both reference `mechanism_class`. If the agent invents a new class on the fly, the rules degrade.

The agent can propose adding a new class — but adds it via an explicit edit to `falsifiers.md`'s class list, not by writing an idea with an unrecognized class. The harness rejects ideas with unregistered classes.

## `falsifiers.md` structure

Top of file: the instance's mechanism-class taxonomy.

```yaml
mechanism_classes:
  - <class-1>: <one-line description>
  - <class-2>: ...
```

Then one section per class with worked examples. Each example shows a `hypothesis`, a `true_signal`, a `false_signal`, an `inconclusive_signal`, and the verdict the example resolved to.

Examples accumulate over the life of the loop. The agent appends new examples on `discard_falsified` and `keep` outcomes — these are the most informative.

## Falsifier execution at iter step 6

```
falsifier_result = run_experiment(idea.false_signal)
match falsifier_result:
  fires      → emit discard_falsified; mark idea exhausted; goto step 4
  inconclusive → emit discard_falsified with reason=inconclusive; mark idea pending again; goto step 4
  doesn't fire → proceed to step 7 (apply change)
```

The harness writes the experiment's raw output to `archive/iter-<N>/falsifier_result.txt` regardless of outcome.

## Falsifier without a measurement primitive

Some target types don't have a "run experiment" that's cheaper than the full measurement. In those cases, the falsifier is a **logical check** rather than an experimental one — e.g., "the proposed annotation matches the existing usage" or "the patched build does not reintroduce the original symptom."

For those, the false_signal is a tool invocation (linter check, test re-run, static-analysis pass) that returns boolean.

What is **not** acceptable as a false_signal: agent-narrated reasoning. "I don't think the parking hypothesis applies because…" is not a falsifier; it's the agent's prior. The falsifier must be a tool invocation with a tool-produced result.

## Common rationalizations the registry rejects

| Agent rationalization | Why it's rejected |
|---|---|
| "The falsifier costs more than the measurement; let me skip it." | Falsifiers are cheap **by construction**. If the falsifier you wrote isn't cheap, write a different one. |
| "The previous falsifier didn't fire, so I'll apply the same idea again." | The previous attempt with the same hypothesis got `discard_objective` after the falsifier didn't fire. Re-proposing the same hypothesis without evidence of structural difference is rejected at queue dedup. |
| "I know the mechanism is real because I read the source code." | Source-code reasoning is not a falsifier. Reading is an input to forming the hypothesis; the falsifier tests it against tool output. |
| "The falsifier is hard to write for this case; let me just run the measurement." | An idea without a writable falsifier means the agent does not have a precise mechanism in mind. Refine the hypothesis until a falsifier becomes writable. |

## Falsifier-derived idea retirement

After a `discard_falsified` outcome, the harness marks the idea exhausted **and** marks the underlying mechanism class as having one fewer plausible mechanism. If the same mechanism class accumulates K falsifications across different ideas (default K=3), the harness deprioritizes proposals in that class for the next M iters (cooldown).

This is how the registry feeds back into the queue's diversity. Mechanisms that consistently fail to survive their falsifiers get deprioritized; the lowest-density argmin then prefers cells in other classes.
