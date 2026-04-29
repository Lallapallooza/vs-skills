# Case study: lint burndown

Coverage archetype. Boolean done-check. Signature-bucketed worklist. File-based target unit.

This is one example of how to wire the autoloop kernel to a target type. It is **not** the skill body; it is illustrative.

## Target unit

A **lint finding** — one (file, rule-id, line-region) tuple flagged by the project's linter or static analyzer.

Target the burndown at one rule (or a small set of related rules) per instance, not the whole linter at once. A loop that targets every rule simultaneously becomes unfocused; one that targets a handful of related rules makes per-iter judgment tractable.

## Measurement primitive

The linter binary, scoped to one file:

```
<linter> --rules <rule-list> --json <file-path>
```

Output schema:

```json
{
  "findings": [
    {
      "rule_id": "<id>",
      "line_start": <int>,
      "line_end": <int>,
      "message": "<text>",
      "severity": "<error|warning|info>"
    },
    ...
  ]
}
```

Done-check: the file's findings list (filtered to the rules in scope) is empty.

## Verdict shape

Per-iter verdict is one of:

- `keep` — the file no longer has findings for the in-scope rules; functional tests pass; falsifier did not fire.
- `discard_objective` — the file still has findings (the change did not actually fix it).
- `discard_falsified` — the falsifier fired (e.g., the proposed annotation is not the right fix).
- `discard_test` — functional tests broke.
- A lane transition to `needs-human-review`, `won't-fix`, or `blocked` (the agent or human determined this finding cannot be auto-fixed). The verdict for the iter is whatever gate fired (typically `discard_falsified` if the falsifier rejected the proposed fix); the lane move happens alongside.
- `crash` / `hang` — the linter or test runner crashed/timed out.

There is no `discard_secondary` for typical lint loops — the verdict is binary done. Instances with multi-rule scoring may use it.

## Mechanism class taxonomy

Common starting taxonomy for lint burndown:

- `add-annotation` — adding a type annotation, decorator, or attribute that satisfies the rule.
- `restructure` — refactoring the code so the rule no longer applies (extracting a function, simplifying a conditional).
- `silence-with-rationale` — suppressing the lint with a comment that names the reason. Used only when the rule does not apply or is a false positive.
- `delete-dead` — removing code the lint flags as unreachable or unused.
- `move` — relocating the offending construct to a place where the rule doesn't fire (e.g., out of a strict-mode file).

The instance declares which classes are acceptable; some loops disallow `silence-with-rationale` entirely.

## Worked falsifier examples

### Class: `add-annotation`

```yaml
mechanism_class: add-annotation
hypothesis: adding type annotation X to symbol Y satisfies rule R
true_signal: linter --rules R reports zero findings on the file after the change
false_signal: remove the annotation again; if the linter still reports zero
              findings, the annotation is unnecessary (the rule is satisfied
              by something else, or the file changed elsewhere)
inconclusive_signal: adding the annotation produces a different finding under
                     the same rule — the annotation is wrong but related
```

### Class: `restructure`

```yaml
mechanism_class: restructure
hypothesis: extracting the inner block into a named function eliminates rule R
true_signal: linter passes; functional tests pass; the extracted function has
             a non-trivial body (not just a single statement)
false_signal: revert the extraction; if the linter passes anyway, the
              extraction was not the cause (the file may have been fixed by a
              concurrent edit)
inconclusive_signal: linter passes but tests fail — the extraction was wrong;
                     pick a different mechanism
```

### Class: `silence-with-rationale`

```yaml
mechanism_class: silence-with-rationale
hypothesis: the rule R fires here because of a known false-positive pattern P
true_signal: pattern P is documented in the rule's known-issues list (tracker
             link or upstream issue)
false_signal: the rule's known-issues list does not contain pattern P
inconclusive_signal: pattern P is plausibly false-positive but not documented;
                     escalate to needs-human-review rather than auto-silence
```

The `silence-with-rationale` class typically routes through `needs-human-review` automatically (see "Human-in-loop policy" below).

## Worklist source

The source-of-truth tool is the linter run across the whole project, output bucketed by file and rule:

```
<linter> --rules <rule-list> --json <project-root>
| <bucketing-script>
```

The bucketing script writes one worklist row per (file, rule-id) tuple. The signature is:

```
signature = "<file-path>:<rule-id>"
```

Coarser than per-line — the loop fixes all findings of the same rule in the same file in one iter. Finer than per-file — different rules in the same file are different items.

The worklist is refreshed at a configurable cadence (default: every iter; some instances override to "every 10 iters" if the linter is expensive).

## Priority score

```
priority_score = severity_weight × age_factor × reachability_factor
```

Where:

- `severity_weight`: 3 for errors, 2 for warnings, 1 for info.
- `age_factor`: 1 + (iters_since_discovery / 100). Older items get a small boost to prevent starvation.
- `reachability_factor`: 1.5 if the file is on the project's "hot list" (e.g., entrypoint files, public API); 1 otherwise.

The instance can override the formula. The harness computes the score; the agent does not.

## Noise-floor calibration

Lint outputs are typically deterministic (the same input produces the same output). Calibration usually shows zero dispersion; the noise floor concept does not gate verdicts.

Where calibration matters: when the linter is itself flaky (e.g., type-checker non-determinism, language-server caching effects). In those cases:

```
K = 5 runs of the linter on a representative file with no changes.
Dispersion = the count of distinct outputs across the K runs.
If dispersion > 0, route the file to needs-human-review until the linter is stable.
```

For most lint primitives, this calibration is a one-time check at scaffold and does not need re-running.

## Cross-target guard

The cross-target guard for lint burndown is the **whole-project linter pass**: tier-1 is a fast scope (e.g., the immediate file plus its direct dependents); tier-2 is the full project run.

Tier-1 trip: the change broke the linter elsewhere. `discard_guard` and revert.

Tier-2 trip: deferred to commit-time. If the change passes tier-1 but tier-2 detects a related-but-distant lint regression, revert and downgrade.

For coverage archetype loops with a fast measurement primitive, tier-1 and tier-2 may collapse into one — depends on the linter's wall-clock cost.

## Revert protocol

`git-commit-revert`. Default for code-modifying lint loops.

If the loop is itself producing a lot of refactor commits, `branch-per-iter` may be preferred so that failed attempts are visible as orphan branches rather than reset-and-lost.

## Human-in-loop policy

`silence-with-rationale` always routes through `needs-human-review`. The bot proposes the silence and the rationale; a human ratifies. This prevents the failure mode where the loop accumulates silence comments that paper over real bugs.

`add-annotation`, `restructure`, `delete-dead`, `move` are auto-merged on `keep` if functional tests pass.

For high-stakes files (declared in `MANDATES.md`'s `sacred-files` list), all classes route through `needs-human-review`.

## Worklist-side dedup

Two findings with the same signature merge into one worklist row. The merged row's `also_seen` field tracks the duplicates.

When a find resolves (verdict `keep`), all merged duplicates resolve too. The next worklist refresh re-discovers any that the bucketing script considered separate.

## Loop termination

The loop terminates when:

- The worklist has zero items in `pending` lane, AND
- No new items have been discovered in the last 10 iters (i.e., the linter has been stable across multiple refreshes).

After termination, the user typically runs a final whole-project lint pass to confirm zero findings on the in-scope rules. If a pass finds something the loop missed (rare), the user re-scopes the loop and re-runs.

## Difference from optimization-archetype loops

| Aspect | Optimization | Coverage (lint) |
|---|---|---|
| Verdict gating | Numeric threshold + sacred axes | Boolean done + tests |
| Termination | Bar escalation, never self-stops | Worklist drain + new-item-quiescence |
| Queue | Quality-diversity grid | Tagged worklist with dedup signature |
| Selection | Lowest-density argmin over cells | Lowest-attempts argmin over pending items |
| Idea reuse | Embedding-based dedup; island reset | Item resolution is terminal; no reuse needed |
| Falsifier | Tests the mechanism | Tests the proposed fix's necessity |

The kernel is the same. The differences are entirely in the queue, the verdict, and the termination rule — all archetype-level concerns.
