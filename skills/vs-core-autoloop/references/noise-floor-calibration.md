# Noise-floor calibration

*Level: loop-kernel (universal protocol; per-target-type instantiation lives in case studies).*

Every measurement primitive has a noise floor. Optimizing against deltas below the floor is the most common silent failure of long-running loops — every iter either rejects real wins as "below threshold" or accepts noise as wins, depending on which way the threshold is wrong.

The calibration runs **before any iter**. Its result (a `[kind=baseline]` or `[kind=noise-recalibration]` entry in `mission.md`'s Decision Log) is the discard threshold for that target type until re-calibrated.

## Universal calibration protocol

```
1. Hold the working tree fixed (no changes between runs).
2. Run the measurement primitive K times, back-to-back, under no-change conditions.
3. Record the dispersion (statistic chosen per the decision tree below).
4. Compute noise_floor = dispersion × multiplier (default multiplier=2).
5. Append a `[kind=baseline]` (or `[kind=noise-recalibration]` for re-runs) Decision Log entry to `mission.md`.
```

K defaults to 8. Higher K gives a tighter floor estimate at the cost of calibration wall-clock time. Instance can override.

The "multiplier" is the safety factor. A delta of `≥ multiplier × dispersion` is unlikely to be noise. Default 2; instance can tighten or loosen.

## Decision tree: which dispersion statistic

Use this tree at scaffold time to pick the dispersion statistic for each target type. The choice is recorded in `[kind=baseline]` and applied at every verdict gate.

```
Is the measurement output a single number per run?
├── Yes
│   Is the distribution roughly Gaussian (no heavy tails, no bimodality)?
│   ├── Yes  → stdev with K=5
│   └── No
│       Is the distribution bimodal or multi-modal (e.g., perf with cache regimes)?
│       ├── Yes  → IQR with K=12, multiplier=3
│       └── No (heavy-tailed but unimodal) → MAD with K=8 (default)
├── No (boolean per run, e.g., test passed/failed)
│   → flake-rate with K=5; noise_floor = flake_rate × multiplier
└── No (Pareto vector per run, e.g., (TPR, FPR))
    → per-axis MAD with K=8; verdict requires headline-axis improvement >
      noise_floor[headline_axis]; secondary axes checked independently
```

Heuristics for "is it Gaussian":
- Run K=20 of the primitive; if min/max are within 3× the IQR around the median, treat as Gaussian.
- Most non-toy measurement primitives are *not* Gaussian — heavy tails are the default. MAD is the safe choice when in doubt.

## What `dispersion` means per-archetype

For numeric measurements (perf benchmarks, ELO, accuracy, latency, cost):

- **MAD (median absolute deviation)** is the recommended dispersion statistic. Robust to bimodal distributions; doesn't blow up on outliers.
- **Standard deviation** is acceptable when distributions are approximately Gaussian.
- **IQR (interquartile range)** is acceptable for highly-skewed distributions.

The renderer uses whichever the instance declares. Default: MAD.

For boolean measurements (lint pass/fail, test result):

- The "noise floor" concept does not apply directly. Instead, the calibration runs the test K times and records the **flake rate**: the fraction of runs that disagree on the boolean outcome.
- A target with non-zero flake rate is treated as having a non-zero discard threshold: if a `keep` candidate's improvement is below `flake_rate` (i.e., possibly explained by flakiness alone), the verdict is `discard_objective` with `description=below_floor`.

For multi-axis measurements (Pareto vectors):

- Per-axis dispersion. The verdict gate requires improvement on the headline axis to exceed that axis's noise floor; secondary axes are checked for regressions independently.

## When to re-calibrate

Re-calibration triggers:

1. **Environment fingerprint drift in a baseline-affecting field** (see [`lock-and-fingerprint-protocol.md`](lock-and-fingerprint-protocol.md)). The host changed; the noise floor likely changed too.
2. **After a string of `discard_objective` verdicts with `description=below_floor`.** If many iters in a row improve the headline but fall below the floor, the noise floor may have grown (or the iter-cycle deltas have shrunk because the loop is near a real plateau). Re-calibration distinguishes the two.
3. **On user request.** Some instances may want to re-calibrate after major dependency updates or workload changes.

The harness writes each calibration as a timestamped Decision Log entry. Older calibrations remain in the Log (it never prunes) and are visible via `grep '[kind=baseline]\|[kind=noise-recalibration]' mission.md`.

## Why this is the first defense, not the last

The published microbenchmark literature (broad consensus across decades of work) shows that **environment perturbations routinely shift measured performance by 10-300% with no algorithmic cause**. The same pattern applies to non-numeric measurements: test flake rates fluctuate with system load; eval-set accuracy drifts with model temperature; ELO scores vary with opponent pool composition.

If the loop's discard threshold is below the actual noise floor, every iter is either accepting noise as wins or rejecting real wins as noise. Both failure modes are silent — the verdict log accumulates plausibly-shaped rows that mean nothing.

This is **why §5 of the dossier ranks this finding above every other**: noise-floor calibration is a precondition, not a "nice to have."

## What the calibration script does

A short script (~50 lines) that:

1. Records the current commit / state.
2. Runs the measurement primitive K times, recording each output.
3. Computes the dispersion statistic.
4. Appends a Decision Log entry to `mission.md`:

```
2026-04-29T10:00Z [stage=autoloop] [kind=baseline] target_type=<id> calibrated_at=<ISO-8601> fingerprint_hash=<sha256> K=8 statistic=MAD headline_median=<n> headline_dispersion=<n> headline_noise_floor=<n> secondary={<axis>:<floor>,...}
```

(Or `[kind=noise-recalibration]` if this is a re-calibration after fingerprint drift or a string of below-floor verdicts.)

5. Returns 0 on success, non-zero on failure (treated as `crash` with `description=calibration_failed` by the wrapper).

The agent does not run the calibration. The harness does, at scaffold time and on re-calibration triggers.

## Calibration during scaffold

At scaffold time, the script runs once for each target type the instance declares. Results populate the initial `[kind=baseline]` Decision Log entries in `mission.md`.

If a target type has wildly different scales (e.g., one cell measured in nanoseconds, another in milliseconds), the script captures noise floor per target, not per target-type. The renderer reads per-target.

## Calibration during the loop

A re-calibration during the loop pauses idea iteration:

1. The harness appends a `[kind=mode-set] mode=calibrating` Decision Log entry to `mission.md`. The Pipeline State section (regenerated) reflects `mode: calibrating` so the agent knows not to propose ideas.
2. The script runs.
3. The new noise floor is written.
4. The renderer picks up the new floor on the next iter.
5. The loop resumes.

Calibration is not itself an iter. It does not produce a `keep` or `discard_*` verdict. It produces only a new noise floor.

## Agent rationalizations the calibration rejects

- **"I'll tune the noise floor down because this iter's improvement is so close to the threshold."** The noise floor is fixed between calibrations and is not agent-adjustable. If sub-noise deltas keep accumulating, trigger a re-calibration; do not lower the threshold per iter.

## Per-target-type implementation hints

The skill body does not prescribe specific dispersion estimators or K values. Per-target-type guidance lives in case studies (`references/case-studies/`):

- A perf-benchmark target type might use MAD over [p20, p30] of K=8 runs.
- An eval-set target type might use stdev over K=5 runs at temperature=0.
- A lint-burndown target type might compare the count delta to historical commit-to-commit variance.
- An ELO target type might use the elo-rating system's own variance estimate (already a published quantity).

These are implementation choices per instance, not skill prescriptions.
