# Verdict rendering

*Level: loop-kernel (universal across archetypes and target types).*

Verdict is rendered by a script. The agent does not decide the verdict.

The renderer is a function:

```
render_verdict(measurement, baseline, noise_floor, tier1_guard, test_result, falsifier_result) → verdict ∈ enum
```

Pure function. Given the same inputs, it always returns the same output. The agent's narrative does not enter the function.

## The 9-value frozen enum

```
keep
discard_objective
discard_secondary
discard_test
discard_guard
discard_falsified
discard_environment_changed
crash
hang
```

These are the only verdict differentiators. Any nuance — what specifically regressed, which test failed, which falsifier fired, which crash subkind, what host field drifted — goes in the free-text `description` field of the `[kind=verdict]` Decision Log entry. The verdict itself is one of 9. Subkinds are description-field text, not enum values.

### `keep`

All gates passed:

- Headline objective improved by at least `k × noise_floor` (or, for coverage archetype, the item's done-check returned true).
- Sacred axes / tier-1 guard cells did not regress beyond their declared tolerances.
- Functional/correctness tests pass.
- Falsifier did not fire.

The change becomes durable per the instance's revert protocol. The new measurement becomes the baseline.

### `discard_objective`

Headline objective regressed (or stayed within noise but the iter was an "additions regress" pattern). The instance's `MANDATES.md` declares the threshold: e.g., "regression by more than `noise_floor × k_strict`" or "any regression at all on the headline."

For coverage archetype: the item's done-check returned false after the attempt — i.e., the change did not actually fix the item.

### `discard_secondary`

A sacred axis regressed. Sacred axes are declared at scaffold time per instance; common examples (cited as patterns, not as the skill's prescription):

- A stability axis (variance, p95, slow-mode fraction) regressed even though the headline improved.
- A secondary metric the user cares about regressed beyond tolerance.
- A declared invariant (memory ceiling, latency cap, cost cap) was violated.

### `discard_test`

Functional or correctness tests broke. This is the "did the change introduce a bug?" gate. Specific test runners are instance-defined; the verdict only says "the test runner reported failure."

### `discard_guard`

The cross-target guard tripped. A target other than the active one regressed beyond its declared tolerance. The active iter "won" its own target but at the cost of another target.

The harness handles this in two tiers:

- **Tier 1**: small set of high-leverage targets re-measured **on every iter**, low-cost. Trip → instant `discard_guard`.
- **Tier 2**: full target list re-measured **before commit becomes durable**, higher cost. Trip → revert + downgrade verdict.

The instance declares the tier-1 set and the tier-2 cadence at scaffold time.

### `discard_falsified`

The idea's `false_signal` experiment fired at iter step 6. The mechanism the idea proposed is dead; the change is **not applied**. This is the cheapest discard — it costs only the falsifier experiment, not a full measurement cycle.

### `crash`

A non-recoverable error during the iter:

- Build failed.
- Measurement primitive crashed.
- Test runner crashed.
- A harness script returned non-zero.

The change is reverted. The agent does not retry the same change; the next iter picks a new target/idea.

### `hang`

The iter exceeded its wall-clock cap (the per-target measurement adapter's timeout). The wrapper killed the offending process with SIGKILL.

Treated like `crash`: revert, do not retry, pick new.

### `discard_environment_changed`

The host fingerprint at iter step 3 differs from the most recent `keep`'s fingerprint in a baseline-affecting field (kernel version, CPU model, governor, SMT state, compiler version, instance-declared dependency). The recorded baseline is stale; the iter stops before applying any change. The next iter must re-baseline before any new comparison.

The change is **not applied** (step 3 is before step 8). This is the cheapest discard alongside `discard_falsified`. The Decision Log entry is paired with a `[kind=fingerprint-drift]` entry naming the drifted field.

## The renderer script's contract

The renderer is one of the harness scripts (see [`harness-agent-split.md`](harness-agent-split.md)). It:

1. Reads `archive/iter-<N>/measurement/` (this iter's measurement).
2. Reads `archive/iter-<N-1>/measurement/` or the rolling-window baseline.
3. Reads the most recent `[kind=baseline]` and `[kind=noise-recalibration]` entries from `mission.md`'s Decision Log to obtain the calibrated noise floor.
4. Reads `archive/iter-<N>/tier1_results.json` (the tier-1 guard's output).
5. Reads the test runner's exit code from `archive/iter-<N>/test_result.txt`.
6. Reads the falsifier's output from `archive/iter-<N>/falsifier_result.txt`.
7. Computes the verdict per the rules above.
8. Appends a `[kind=verdict]` entry to `mission.md`'s Decision Log:

```
2026-04-29T10:12Z [stage=autoloop] [kind=verdict] iter=N target=<id> verdict=<one-of-9> headline_delta=<n> delta_vs_noise=<n> tier1=<ok|regressed:cell-x> description=<free text>
```

The Log entry is the canonical record. Per the orchestration-tier protocol, the Head's Scoreboard section is regenerated from the Log entries at step 12.

9. Returns 0 on success, non-zero if the renderer itself failed (treated as `crash` by the wrapper).

## Per-archetype precedence

When multiple gates fail simultaneously, the renderer applies them in this fixed order — the first matching verdict wins:

```
discard_environment_changed (step 3 detected fingerprint drift; short-circuits the iter)
hang        (wall-clock cap exceeded)
crash       (any harness script returned non-zero)
discard_test (test runner failed)
discard_falsified (false_signal fired — mutually exclusive with the others if step 6 ran first)
discard_guard (tier-1 regressed)
discard_secondary (sacred axis regressed)
discard_objective (headline regressed or below noise floor)
keep        (everything passed)
```

This precedence is fixed across instances. It cannot be overridden by `MANDATES.md`.

## Why a frozen enum

Free-form verdict strings drift. After a few hundred iters, multiple synonymous discards accumulate (each instance's history shows this empirically). Querying "how many iters discarded for X" requires fuzzy matching, and aggregate metrics become unreliable.

Nine values is enough range. Each value is unambiguous. Free-text `description` carries the nuance — including which crash subkind, which test failed, which fingerprint field drifted, whether the regression was below or above the noise floor.

## Why the renderer, not the agent

The agent has incentives to round its own verdicts in its favor. Documented across multiple autonomous-loop projects: agents narrate borderline measurements as "directionally favorable", selectively quote tier-1 results, rationalize past flaky tests.

The renderer is a deterministic function of inputs. It is auditable. Any disputed verdict can be re-derived from the archive.

## Manual override

There is no manual override of the renderer in the per-iter playbook. If the user disagrees with a verdict, the path is:

1. Pause the loop.
2. Inspect the measurement, the noise floor, and the renderer's logic.
3. If the renderer is wrong, fix the renderer (it's a script in the harness; this is intentional).
4. Re-render the affected iters.
5. Resume the loop.

This is intentionally heavy. Manual overrides during the loop are exactly the mechanism that breaks down at scale.
