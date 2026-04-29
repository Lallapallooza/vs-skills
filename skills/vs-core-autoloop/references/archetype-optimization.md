# Archetype: optimization

*Level: archetype (rules apply to every optimization-archetype instance; orthogonal to target type).*

For loops where the target unit is a **point in some space** (a slice, a configuration, an item under tuning) and the verdict is a **numeric objective plus sacred axes**.

Examples (instantiated as case studies, not part of the skill body): perf cell tuning, eval-set accuracy tuning, ELO match-runner tuning, prompt-template optimization, kernel autotuning, cloud-spend reduction with SLO guard, alert-rule TPR/FPR Pareto.

## Verdict shape

A `keep` requires:

1. **Headline objective** improved by at least `k × noise_floor` (see [`noise-floor-calibration.md`](noise-floor-calibration.md)).
2. **Sacred axes** did not regress beyond their declared tolerances (the cross-target guard's tier-1 set; see [`verdict-rendering.md`](verdict-rendering.md)).
3. **Functional/correctness tests** pass.
4. **Falsifier** for the idea did not fire.

Any failure on any axis routes to a specific `discard_*` verdict.

## Termination

Optimization-archetype loops do **not** self-terminate. When all targets reach the current bar, the bar is escalated (one notch tighter; e.g., a 5% lead becomes a 10% lead, or a Pareto frontier moves outward). The loop resumes against the new bar.

The execution driver's `--budget` controls when the session stops — not the loop itself.

## Queue shape: quality-diversity grid

Adapted from MAP-Elites / FunSearch / AlphaEvolve: a multi-dimensional grid keyed by features of the program/configuration, retaining the highest-fitness point in each cell.

### Dimensions

Three dimensions are universal:

- **Target axis** — what is being tuned (the slice, the configuration item, the cell name).
- **Intervention class** — what kind of change the idea proposes (e.g., "schema change", "parameter tweak", "structural rewrite", "ordering change", "new component"). The instance defines the taxonomy at scaffold time.
- **Outcome class** — what kind of effect the idea expects (e.g., "reduce X", "shift X to Y", "Pareto-improve").

Optionally a fourth:

- **Cost class** — rough cost of the experiment (cheap / medium / expensive). Useful when iters have variable wall-clock cost.

### What each cell stores

```
cell_id: <target_axis>_<intervention_class>_<outcome_class>
status: open | in-flight | won | exhausted
recent_attempts: [iter_id_1, iter_id_2, ...]    # last N=5
best_keep: { iter_id, delta, hypothesis_text }  # the best result achieved here
last_reject: { iter_id, verdict, reason }
hypothesis_embedding: <vector>                  # for similarity-based dedup at write time
```

### Selection rule (lowest density)

At the top of each iter, the harness picks:

```
active_cell = argmin(len(cell.recent_attempts) for cell in grid if cell.status != "in-flight")
```

Ties broken by recency of last activity (oldest first). Parameter-free; rotates naturally.

See [`lowest-density-target-selection.md`](lowest-density-target-selection.md) for the full algorithm and the heterogeneous-target normalization rule.

### Idea proposal

The agent proposes ideas into the active cell at iter step 5. Each idea has frontmatter:

```yaml
cell: <cell_id>
mechanism_class: <one of the registered mechanism classes for this target type>
hypothesis: <one-sentence>
true_signal: <observable that, if seen, supports the mechanism>
false_signal: <cheapest experiment that disproves the mechanism>
inconclusive_signal: <observable that means investigate other mechanism>
priority: <low | medium | high>
```

Plus a free-text body describing the idea in detail.

The agent dedups against the cell's recent attempts at write time using the hypothesis embedding. If similarity exceeds a threshold to a recent reject, the agent must explicitly note what is structurally different in this attempt (the harness rejects writes without that note).

### Island reset

When a cell accumulates K rejects with no `keep` (default K=10), the cell is marked `exhausted`. The harness re-seeds it from the best-performing adjacent cell — copies the `best_keep` hypothesis text and resets `status` to `open`.

This is the explicit anti-stagnation mechanism. Without it, exhausted cells stay in the lowest-density argmin and the loop spins on dead branches.

## Bar escalation

When all cells with `status != exhausted` have reached the current bar (e.g., headline objective ≥ target):

1. The harness escalates the bar one notch (instance-defined: typical sequences are 5%/10%/20%/30% improvement-vs-best-competitor, or absolute targets like "50 ELO better than reference engine").
2. All cells re-open at `status: open`.
3. The loop resumes against the new bar.

This makes the loop genuinely infinite. Bar escalation is harness-mechanical, not agent-decided.

## Worked example: cell-dimension instantiation

A perf-tuning loop might use:
- **Target axis** = bench cell name
- **Intervention class** = `{layout, ordering, allocation, scheduling, cache, branch-prediction, sync-primitive}`
- **Outcome class** = `{reduce-latency, reduce-tail, shrink-bimodal, reduce-cycles}`

A prompt-eval loop might use:
- **Target axis** = eval slice name
- **Intervention class** = `{system-prompt, few-shot-example, instruction-format, tool-description, error-handling}`
- **Outcome class** = `{improve-accuracy, reduce-refusal, reduce-latency, reduce-cost}`

A chess-engine loop might use:
- **Target axis** = position-suite name (tactics, endgame, openings)
- **Intervention class** = `{eval-weight, search-depth, pruning-rule, transposition-table, move-ordering}`
- **Outcome class** = `{win-more, faster-solve, reduce-blunder}`

The skill body does not prescribe taxonomies — they're declared at scaffold time per instance. The cell-dimension recipe is universal.

## Pareto-archetype variant

Some optimization loops have a **Pareto-vector objective** rather than a single scalar (e.g., alert-noise reduction with TPR/FPR; cloud spend with SLO guard).

Variant rules:
- The grid's **outcome class** dimension is replaced by a Pareto-frontier-aware fitness.
- A `keep` requires the new point to be **non-dominated** by any prior best in the cell.
- Bar escalation tightens a Pareto target (e.g., "Pareto frontier must move outward by 5% on the worst axis").

The same selection (lowest density), reset (K-rejects), and falsifier rules apply.

## Hybrid composition

When optimization is the inner loop of a hybrid (outer coverage walks a worklist, inner optimization runs per item), the optimization grid's **target axis** is bound to the outer worklist's active item. As the outer rotates, the inner's grid is re-scoped to the new item's cells.

See [`archetype-coverage.md#hybrid-composition`](archetype-coverage.md#hybrid-composition).
