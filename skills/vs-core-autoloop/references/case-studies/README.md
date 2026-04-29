# Case studies

This directory holds **examples** of autoloop instantiated on specific target types. Case studies are not part of the skill body — the skill body is the loop kernel + the two archetypes. Case studies show how to wire a real target type into the kernel.

## What a case study contains

Every case study is a single Markdown file documenting one target type. The shape:

```
# Case study: <target type>

## Target unit
What is one item being iterated on?

## Measurement primitive
What tool produces the verdict input? CLI invocation; output schema.

## Verdict shape
Headline objective + sacred axes (optimization) OR done-check (coverage).
Concrete thresholds; concrete sacred axes.

## Mechanism class taxonomy
The instance-specific list of mechanism classes for the falsifier registry.
One bullet per class with a one-line description.

## Worked falsifier examples
2-3 example falsifiers per mechanism class. Show the full schema:
mechanism_class, hypothesis, true_signal, false_signal, inconclusive_signal.

## Noise floor calibration
How dispersion is measured for this target type. Recommended K. Recommended
multiplier. What re-calibration triggers look like.

## Cross-target guard
The tier-1 set (if any). The tier-2 set. Thresholds.

## Revert protocol
Which of the four; rationale for the choice.

## Human-in-loop policy
Always-review / confidence-gated / sample-gated / none.
```

## Why these are reference, not skill body

The loop kernel is universal. The archetypes are universal. Everything below them — measurement primitives, mechanism class taxonomies, dispersion estimators, cross-target guard cells — is target-type-specific.

If a case study's content leaks into the skill body, the skill becomes prescriptive about a target type it should not be prescribing. The skill stays generic by keeping target-type material here.

## Available case studies

The two below are worked examples. They cover the optimization archetype with numeric measurement and the coverage archetype with boolean done-check. Other target types follow the same shape.

- [`perf-tuning.md`](perf-tuning.md) — optimization archetype; numeric headline; layout-sensitive measurements; bench-cell target.
- [`lint-burndown.md`](lint-burndown.md) — coverage archetype; boolean done; signature-bucketed worklist; file-based target.

To add a case study for a new target type:

1. Copy one of the existing case studies as a template.
2. Fill in the seven sections per the case-study contract.
3. Verify the case study aligns with the kernel and the archetype — do not invent kernel-level rules.
4. The case study should make the **target type** legible to a future user, not document the skill.

## Contract: what case studies must NOT do

- **Must not propose changes to the loop kernel** (the 13 steps in [`../loop-kernel.md`](../loop-kernel.md)). The kernel is fixed across target types.
- **Must not propose new verdict values.** The 8-value enum is frozen. Per-target nuance goes in the description field.
- **Must not redefine the harness/agent split.** Harness owns ground truth, agent owns hypothesis — universal.
- **Must not propose new revert protocols beyond the four named in [`../revert-protocol-variants.md`](../revert-protocol-variants.md).** If a target type doesn't fit one of the four, the case study should explain why and what's missing — but it should not invent a fifth in-place.

## Contract: what case studies SHOULD do

- Pin every prescription to the level it lives at: target type or instance, never kernel.
- Show the full falsifier schema for each mechanism class. Working examples are more useful than abstract descriptions.
- Document the noise-floor calibration choices specifically for this target type — what dispersion estimator, why, what K.
- Document the cross-target guard's tier-1 set explicitly. "Always re-measure these K targets" is more useful than "re-measure some targets."
- Reference any target-type-specific external tools (profilers, analyzers, runners) by name and minimal invocation. The user should be able to copy the invocation directly.
