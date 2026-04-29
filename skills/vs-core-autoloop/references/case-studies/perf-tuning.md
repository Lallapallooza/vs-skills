# Case study: perf tuning

Optimization archetype. Numeric headline (e.g., wall-clock per operation). Layout-sensitive measurements. Bench-cell target unit.

This is one example of how to wire the autoloop kernel to a target type. It is **not** the skill body; it is illustrative.

## Target unit

A **bench cell** — a named workload in a microbenchmark suite, parameterized by inputs that fix the work shape. Each cell measures the same operation under fixed conditions.

Examples of cells: `dispatch_j2_body0` (dispatch latency at parallelism=2 with empty body), `matmul_j16_n2048` (matmul at 16-way parallelism with N=2048).

## Measurement primitive

The bench binary invoked with a per-cell filter. Stdout is the measurement output:

```
<bench-binary> --filter <cell-name>
```

Output schema (one row per competitor; the autoloop's row is `our::Pool` or equivalent):

```
<headline-ns/op>  <error-pct>  <competitor-name>
...
```

The headline statistic is whatever the bench harness reports — typically a robust percentile (e.g., p25) with an error band (MAD over a centered window).

## Verdict shape

Headline objective: minimize the bench cell's headline ns/op.

Sacred axes (declared in `MANDATES.md`):

- **Stability axis**: variance / MAD / p95 ratio of the cell's distribution. A change that improves median but inflates the tail is `discard_secondary`.
- **Cross-target guard**: a small set of cells whose performance must not regress. Tier-1 (5-8 high-leverage cells, re-measured every iter). Tier-2 (full win list, re-measured before commit becomes durable).
- **Functional tests**: the project's full test suite must pass. The race-detector / sanitizer build's tests must also pass.

A `keep` requires:

- Headline improved by ≥ `2 × noise_floor` (the multiplier is configurable per instance; 2 is the default).
- Stability axis did not regress beyond tolerance (e.g., MAD did not grow by >10%).
- Tier-1 guard cells did not regress.
- Functional tests pass.
- Sanitizer build's tests pass.
- Falsifier did not fire.

## Mechanism class taxonomy

The instance declares classes at scaffold time. Common starting taxonomy for perf tuning:

- `layout` — instruction or data layout changes (cacheline alignment, hot-symbol ordering, struct reordering).
- `synchronization` — locking, atomic operations, memory ordering.
- `scheduling` — dispatch, work-stealing, thread placement.
- `cache` — prefetching, eviction policy, hot-line management.
- `branch-prediction` — likely/unlikely hints, branch-free code.
- `allocation` — alloc/free patterns, arena sizing.
- `topology` — CPU pinning, NUMA placement, CCD/CCX-aware mapping.
- `compile-time` — template parameter threading, attribute-driven inlining, codegen hints.

Each class has a corresponding falsifier menu in `falsifiers.md`.

## Worked falsifier examples

### Class: `synchronization`

```yaml
mechanism_class: synchronization
hypothesis: workers are parking and futex_wake costs ~1us per dispatch
true_signal: futex_wake count > 1000 in a 5s sample (per the syscall-tracing tool)
false_signal: set the spin-budget cap to effectively-infinite; if the headline
              stays unchanged, parking is not the cause
inconclusive_signal: futex count is non-trivial but headline doesn't move when
                     spin is bumped — investigate other mechanisms
```

### Class: `layout`

```yaml
mechanism_class: layout
hypothesis: hot-symbol cache-line alignment is shifting between iters,
            causing measurement bimodality
true_signal: the iter-cycle's perf counters show frontend_bound shift > 5%
             between A and B at constant instructions retired
false_signal: re-link the binary 5x with random section ordering and bench
              each. If the headline is stable across re-links, layout is
              not the cause
inconclusive_signal: shuffles produce wildly different headlines —
                     the noise floor itself is layout-bound; recalibrate
                     before iterating further
```

### Class: `topology`

```yaml
mechanism_class: topology
hypothesis: a worker is migrating between CCDs mid-iter, paying cross-CCD
            cache-coherence latency
true_signal: per-thread CPU-migration count > N in a sample (perf stat
             -e cpu-migrations,context-switches)
false_signal: pin all threads to one CCD with cgroup cpuset; if the headline
              improves by < 5%, cross-CCD is not the dominant cost
inconclusive_signal: per-thread migration count is low but headline still
                     varies — investigate other topology factors
```

## Noise-floor calibration

Calibration protocol:

```
K = 8 runs of the bench binary with --filter <cell-name>, no changes between runs.
Dispersion estimator = MAD of the K headline values.
noise_floor = 2 × MAD.
```

Per-cell. Each cell has its own noise floor; cells with vastly different runtimes have vastly different floors.

Re-calibration triggers (in addition to the universal fingerprint-drift trigger):

- Compiler version changed.
- Linker version changed.
- Kernel version changed.
- The instance's bench binary was rebuilt with different flags.
- Five consecutive `discard_objective` verdicts with `description=below_floor` on the same cell — the cell may have moved into a sub-noise plateau.

## Cross-target guard

**Tier-1 (every iter)**: 5-8 high-leverage cells the user picks at scaffold time. Typically the cells where the project has its strongest competitive position (where regressions hurt most).

```
tier_1_cells = ["<cell-1>", "<cell-2>", ...]
```

Each tier-1 cell is re-measured every iter under the same protocol (single bench invocation; filter to the cell). Threshold: > 5 ns p25 (sub-microsecond cells) OR > 5% (multi-microsecond cells).

**Tier-2 (before commit becomes durable)**: the full list of cells the project leads in. Same protocol, run only before a `keep` is committed. Trip → revert + downgrade verdict to `discard_guard`.

## Revert protocol

`git-commit-revert`. Default for code-modifying perf loops.

Each iter is one commit with prefix `autoloop:` (or `perf:` if the project's commit-message style requires Conventional Commits). The version-control log is the durable record.

## Human-in-loop policy

None. Perf tuning is fully autonomous; the renderer's verdict is the final word.

If the user wants to gate certain classes of changes (e.g., changes to a "sacred" file) through human review, they declare those files in `MANDATES.md`'s `sacred-files` list. The harness routes any change touching sacred files to `needs-human-review` regardless of the headline outcome.

## Composition with measurement-specific skills

When the target hardware has microarch-specific profiling tools, the measurement primitive can compose with a skill like `/vs-core-profile-amd` (for AMD CPUs) or its equivalent. The composition happens **inside the measurement primitive**, not as a sibling-skill invocation:

- The measurement adapter calls the profiling skill's recipe at step 9 to gather counters alongside the headline.
- The renderer uses both the headline and the counters at step 10 to compute the verdict.

This keeps the agent out of the measurement loop and lets the harness gather richer counter evidence per iter.

## Layout sensitivity warning

Perf-tuning loops on layout-sensitive code (heavy template inlining, hot-path-dominated workloads) routinely show a "removals tolerate, additions regress" pattern. The published microbenchmark literature suggests this pattern is, in many cases, a measurement artifact rather than an algorithmic property.

Mitigation:

- The noise-floor calibration (above) at K=8 captures dispersion under no-change conditions.
- The `layout` mechanism class includes a falsifier (random section ordering re-links) that detects when layout effects exceed the noise floor.
- The renderer's `discard_objective` verdict with `description=below_floor` catches sub-noise deltas before they accumulate.

If after calibration the noise floor is large enough to swallow plausible candidate effects, every iter will return `discard_objective` with `description=below_floor` indefinitely. The remedy is to address noise sources (host isolation, SMT control, governor settings) before more iters, not to lower the threshold. The instance can pause itself by detecting K consecutive `below_floor` verdicts in the Decision Log and exiting cleanly, but the verdict itself remains one of the canonical 9.
