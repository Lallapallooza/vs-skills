---
name: vs-core-autoloop
description: Generate a single generic pasteable autonomous iteration loop prompt/runbook. Use when the user wants a long-running optimization, coverage, evaluation, research, cleanup, triage, game-tuning, parity, performance, latency, fuzzing, cost, documentation, dependency, alert, or security loop that can keep working without repeated human babysitting while each iteration has an explicit verdict.
---

# Generic Autonomous Iteration Loop

This skill produces **one** pasteable loop prompt/runbook. It does not require a special command, split the output into variants, or prescribe delegation.

The output is a single markdown block the user can paste into a coding assistant session. If the user explicitly asks to save it, write one file only:

`autoloop.md`

Do not write any additional artifacts unless the user explicitly asks.

## Goal

Convert the user's goal into a generic autonomous loop with:

- a clear objective;
- the editable surface;
- the protected surface;
- setup/context reads;
- the baseline or discovery step;
- the per-iteration command/check;
- result parsing;
- keep/discard/crash handling;
- ledger format;
- timeout policy;
- resume rules;
- anti-cheat rules;
- pause gates.

The loop may run for hours or days, but each iteration must be bounded and checkable.

## Core Output Shape

Return exactly one artifact:

```markdown
# autoloop

[single pasteable autonomous loop prompt/runbook]
```

The artifact must be usable as a prompt by itself. It should not depend on hidden skill state, this conversation, or a special runtime.

## Grill Only For Missing Material Slots

If a required slot is missing and cannot be safely inferred, ask one concise question before generating the loop.

Required slots:

- **Goal:** what is being improved, reduced, covered, fixed, or triaged.
- **Editable surface:** files, directories, configs, docs, tests, data, or external systems the loop may change.
- **Protected surface:** files, commands, datasets, evaluators, benchmarks, fixtures, credentials, external systems, production resources, or generated artifacts the loop must not alter.
- **Verdict source:** command, metric, done-check, human-review lane, or other rule that decides keep/discard.
- **Rollback/keep policy:** how to keep successful work and abandon failed work.

Infer conservative defaults for non-dangerous slots and show them in the output. Never infer permission to push, merge, deploy, spend money, use credentials, mutate production/external state, delete data, or edit evaluators.

## Loop Contract

Every generated loop must include these sections in this order:

1. **Goal**
2. **Scope**
3. **Protected Surface**
4. **Setup**
5. **Baseline**
6. **Ledger**
7. **Iteration**
8. **Verdict**
9. **Keep / Discard / Crash**
10. **Idea Refill**
11. **Pause Gates**
12. **Resume**
13. **Anti-Cheat**

Use the exact section names above.

## Section Requirements

### Goal

State the target in one or two sentences. Include the metric, done condition, or desired state if known.

Good:

```markdown
Improve `[primary_metric]` while editing only `[allowed_surface]`.
```

```markdown
Burn down findings emitted by `[source_of_truth_command]` without changing the command or its config.
```

Bad:

```markdown
Make this better.
```

### Scope

List what may be changed. If unknown, require the loop to discover the smallest safe editable surface during setup and record it before the first iteration.

### Protected Surface

List what must not be changed. Always include evaluator, benchmark, parser, fixture, and data sources when present.

Default protected-surface rule:

```markdown
Do not edit the command/check that decides the verdict unless the explicit goal is to fix that command/check.
```

### Setup

List files and commands the session must read before the first iteration. Keep this minimal and task-specific.

Examples:

- read `README.md`, the editable files, and the verdict command;
- inspect existing result logs or previous failed attempts;
- check git branch and working tree state;
- verify required data or build artifacts exist.

### Baseline

Define how to establish the starting state before changing anything.

For numeric tasks, run the metric/check first and record the number.

For coverage/worklist tasks, run the discovery command and record the pending items.

For qualitative tasks, define the scenario checklist, smoke test, telemetry, or human-review rule that will decide whether a change is keepable.

### Ledger

Define a simple append-only log. Use a table unless the task already has a better local format.

Default columns:

```text
iteration	target	change	verdict	result	status	notes
```

For git-backed code loops, include the commit hash for kept work.

For crashes, record `result=0` or `result=crash` and include the short failure reason.

### Iteration

Each iteration must:

1. Check the current branch and working tree state.
2. Pick exactly one target.
3. Pick exactly one idea.
4. Apply the smallest change that tests the idea.
5. Run the verdict command/check with output redirected to a log file when noisy.
6. Parse the result with the declared parser/rule.
7. Keep, discard, or mark crash according to the verdict section.
8. Append the ledger.
9. Continue to the next iteration unless a pause gate fires.

Do not bundle unrelated ideas into one iteration.

### Verdict

Define the exact keep/discard rule.

Numeric examples:

```markdown
Keep only if the primary metric improves by more than the declared noise floor and protected checks do not regress.
```

```markdown
Discard if the result is equal, worse, below the noise floor, or if any protected check fails.
```

Coverage examples:

```markdown
Keep if the active item is no longer emitted by the source-of-truth command and tests pass.
```

```markdown
Discard if the active item remains, a different item regresses, or the source-of-truth command cannot run.
```

Qualitative examples:

```markdown
Keep only if the scenario checklist passes and any required human-review lane is satisfied.
```

The model may summarize evidence, but it must not self-certify success when a command, parser, done-check, or human-review lane is the authority.

### Keep / Discard / Crash

Define the local lifecycle before the loop starts.

Default git-backed policy:

- Start each iteration from a clean working tree.
- If the change is kept, commit only the intended files with a short message.
- If the change is discarded or crashes before commit, restore only the attempted change.
- Never use destructive git commands that can remove unrelated user work.
- Never push, merge, deploy, or rewrite history.

If the repo already has uncommitted user changes, the loop must avoid touching them unless they are in the declared editable surface and required for the goal.

### Idea Refill

When out of ideas, refill from local evidence first:

- previous rejects and near-misses;
- profiler or test output;
- failing item clusters;
- source code patterns;
- official docs or papers explicitly relevant to the target;
- simple combinations of prior useful changes.

The loop may use additional research only when local evidence is insufficient. Research output must become concrete queued ideas with a target, expected signal, verification check, and discard condition. Do not make research a mandatory per-iteration step.

### Pause Gates

The loop must pause, not improvise, when:

- the verdict command/check is missing or unreliable;
- the protected surface must be edited to proceed;
- the next step would push, merge, deploy, spend money, use credentials, delete data, or mutate external/production state;
- repeated crashes show the current strategy is broken;
- the baseline changes for environmental reasons;
- the working tree contains unrelated user edits that block a safe discard;
- the task becomes ambiguous enough that a wrong decision could waste many iterations.

Do not ask the human after every iteration. Ask only when a pause gate fires or a required material slot is missing.

### Resume

Define how a fresh session resumes:

1. Read this loop prompt/runbook.
2. Read the ledger.
3. Check git status and current branch.
4. Re-run or verify the current baseline if needed.
5. Continue from the next unblocked target.

Chat history is not source of truth. The ledger, files, commands, and git state are.

### Anti-Cheat

Always include:

- Do not edit evaluator, benchmark, parser, fixture, source-of-truth data, or protected checks unless explicitly authorized.
- Do not hardcode hidden cases or benchmark identifiers.
- Do not weaken tests or delete failing cases to create a keep.
- Do not make competitor/reference behavior worse.
- Do not report a keep from narrative confidence; use the declared verdict source.
- Do not hide crashes, hangs, or worse results.

## Task Adapters

Use these as lightweight patterns. Do not print the adapter name unless it helps the prompt.

### Numeric Optimization

Use for performance, latency, loss, eval score, memory, cost, throughput, or ELO.

Required additions:

- primary metric and direction;
- baseline command;
- parser;
- noise floor or repeat policy;
- secondary/protected checks;
- keep threshold.

### Coverage / Worklist

Use for compiler dialect coverage, lint/type burndown, docs gaps, TODOs, dependency upgrades, alerts, security findings, or bug queues.

Required additions:

- source-of-truth discovery command;
- item identity/signature;
- done-check;
- priority rule;
- blocked/repeated-failure rule.

### Reference / Parity

Use for competitor/reference implementation parity, conformance, golden outputs, or compatibility.

Required additions:

- reference source;
- equivalence rule;
- allowed tolerance;
- regression guard for already-passing cases.

### Stability First

Use when crashes, flakes, hangs, variance, or correctness failures matter more than headline speed.

Required additions:

- stability metric or failure source;
- repeated-run policy;
- fail-fast checks;
- rule that performance work starts only after stability gates pass.

### Qualitative / Playability

Use for game playability, UI feel, writing quality, or other partially subjective work.

Required additions:

- scenario checklist;
- smoke test or telemetry when possible;
- human-review lane when subjective judgment is required;
- no autonomous keep when the declared authority is human review.

## Falsifier Policy

Falsifiers are useful, but not every task has a meaningful pre-change falsifier.

Pick one:

- **Independent falsifier:** a cheap check that disproves the idea before a full run.
- **Post-change done-check:** the normal verification proves whether the change worked.
- **Logical check:** a static or local check makes the hypothesis impossible.
- **No cheap falsifier:** record that fact and require stronger verification or human review.

Do not invent fake falsifiers just to satisfy a template.

## Output Rules

- Output one artifact only.
- Do not generate multiple variants.
- Do not require a special loop command or script.
- Do not prescribe delegation.
- Do not hardcode language, repo, benchmark, package manager, metric name, or result filename unless the user provided it.
- Use simple markdown that can be pasted directly into a coding assistant.
- Keep the artifact specific enough that a session can start work immediately.

## Template

Use this template and fill it with the user's task details:

````markdown
# autoloop

## Goal
[objective and success condition]

## Scope
- Editable:
  - [paths or surfaces]
- Out of scope:
  - [what not to touch]

## Protected Surface
- [evaluators, commands, fixtures, data, credentials, external systems]

## Setup
1. [read/check command or file]
2. [read/check command or file]
3. Confirm branch and working tree state.

## Baseline
- Command/check: `[command]`
- Parser/rule: `[how to read result]`
- Baseline record: append the initial result to the ledger before editing.

## Ledger
Append one row after every iteration:

```text
iteration	target	change	verdict	result	status	notes
```

## Iteration
Repeat until interrupted or until a pause gate fires:

1. Check branch and working tree state.
2. Pick one target.
3. Pick one idea.
4. Apply the smallest change that tests the idea.
5. Run `[command/check]`, redirecting noisy output to `[log path]`.
6. Parse the result with `[parser/rule]`.
7. Decide keep/discard/crash using the Verdict section.
8. Apply the Keep / Discard / Crash section.
9. Append the ledger.
10. Continue to the next iteration.

## Verdict
- Keep if: [exact condition]
- Discard if: [exact condition]
- Crash/hang if: [exact condition]
- Protected checks: [must pass]

## Keep / Discard / Crash
- Keep: [commit/save policy]
- Discard: [restore policy]
- Crash/hang: [log and restore policy]

## Idea Refill
If no useful idea remains, refill from:
- ledger rejects and near-misses;
- profiler/test/log output;
- source code patterns;
- relevant docs;
- small combinations of prior useful changes.

## Pause Gates
Pause and ask only if:
- [task-specific gate]
- protected surface must be edited;
- external/production/destructive action is needed;
- repeated crashes block progress;
- safe rollback is not possible.

## Resume
On a fresh session:
1. Read this file.
2. Read the ledger.
3. Check branch and working tree state.
4. Verify or rerun the baseline if needed.
5. Continue from the next unblocked target.

## Anti-Cheat
- Do not edit protected evaluator/check files.
- Do not hardcode hidden cases or benchmark identifiers.
- Do not weaken tests or remove failing cases to create a keep.
- Do not report keep from confidence; use the verdict source.
- Do not hide crashes, hangs, or regressions.
````
