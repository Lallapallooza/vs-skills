# Archetype: coverage

*Level: archetype (rules apply to every coverage-archetype instance; orthogonal to target type).*

For loops where the target unit is an **enumerable item** (a file, a symbol, a finding, a ticket, an op, an alert rule) and the verdict is a **boolean done plus a reason**.

Examples (instantiated as case studies, not part of the skill body): lint or type-error burndown, fuzz crash burndown, security-finding triage, doc-completeness automation, sweeping refactor (codemod fleet), dependency-upgrade fleet, alert-rule cleanup, op-coverage tracking, TODO/tech-debt burndown, PR-review backlog.

## Verdict shape

A coverage iter's verdict is one of:

- `keep` — the active item is now `done`, with a tool-verifiable reason.
- `discard_*` per the standard verdict enum if the attempt failed.
- A lane transition (the item moves to `needs-human-review`, `won't-fix`, or `blocked` lane — see [`human-in-loop-lanes.md`](human-in-loop-lanes.md)). The verdict for this iter is whatever the underlying gate produced (`keep` if the bot's first-pass attempt closed the item; otherwise the appropriate `discard_*`); the lane move happens at iter step 11 alongside the verdict, not as a separate verdict.

Coverage loops treat `keep` as terminal for the active item — once an item is `done`, it leaves the worklist and never comes back unless the underlying source it represents changes.

## Termination

Coverage loops terminate when:

- The worklist has zero items in `pending` state, AND
- No new items have been discovered (added to the worklist) in the last N iters (default N=10).

The execution driver's `--budget` still bounds the session; either condition stops the loop early.

## Queue shape: signature-bucketed worklist with named lanes

The worklist is **never a flat list**. It is a tagged queue with:

- A **signature** field that enables deduplication at write time.
- A **lane** field that segments items by who can act on them.
- A **priority score** field that orders selection within a lane.

### Lanes

```
pending           — bot may act
in-flight         — currently being attempted (single-iter tenancy)
needs-human-review — bot has acted; only human can move to done
done              — terminal
won't-fix         — terminal with rationale
blocked           — paused; agent may not pick this until unblock condition fires
```

Bot-writable lanes: `pending`, `in-flight`, `blocked`. Human-only writable lanes: `needs-human-review → done` and `→ won't-fix`. See [`human-in-loop-lanes.md`](human-in-loop-lanes.md).

### Signature for deduplication

The signature is target-type-specific:

- File-based loops: file path.
- Symbol-based loops: fully-qualified symbol name.
- Crash-based loops: stack-trace hash + truncated frames at the bug-location level.
- Finding-based loops: rule-id + location-hash.
- Op-based loops: op-name (within a dialect).

The signature is computed by the harness at write time. If a new candidate item's signature matches an existing item, the new item is rejected as `duplicate` (or merged into the existing item's `also_seen` list, depending on instance config).

### Priority score

Per-instance formula. Common ingredients:

- Severity (CWE class, lint severity, CVSS).
- Reachability (is the affected code on a hot path / used by other items?).
- Age (older items get a small priority boost to prevent starvation).
- Fix availability (auto-fix exists?).
- User-supplied tag (high/medium/low at item creation).

The harness computes the score; the agent does not.

### Worklist row schema

```
id              — stable identifier
signature       — for dedup
lane            — pending / in-flight / needs-human-review / done / won't-fix / blocked
priority_score  — number
discovered_at   — iter when added
last_attempt    — iter id of most recent attempt
attempts        — count
defer_reason    — for needs-human-review / won't-fix / blocked
also_seen       — list of duplicate signatures rolled up here (optional)
```

The instance may add extra fields; these eight are universal.

## Selection rule (lowest density + priority)

At the top of each iter:

```
candidates = [item for item in worklist if item.lane == "pending"]
if len(candidates) == 0:
    if no_new_items_in_last_N_iters: terminate
    else: pause until next item discovered

candidates.sort(key=lambda i: (i.attempts, -i.priority_score))
active_item = candidates[0]
```

Lowest-attempts first (fairness, prevents starvation); within ties, highest priority first.

The same parameter-free principle as optimization-archetype: never grind on one item that keeps failing while others have not been attempted.

### Move to in-flight

Before applying the change at iter step 8, the harness moves the active item from `pending` to `in-flight`. If the iter completes with a `keep`, the item moves to `done`. If `discard_*`, it moves back to `pending` with `attempts++`.

After K consecutive `discard_*` on the same item (default K=5), the harness moves it to `blocked` with reason `repeated_discards`. The instance can configure an unblock condition (e.g., "unblock when an adjacent item is fixed"), or it may require human action to unblock.

## Worklist refill

The worklist is **populated** from a source-of-truth tool. Coverage loops do not generate items — they enumerate them.

Source examples:

- A linter's pass count → one item per failing rule × file.
- A fuzzer's crash directory → one item per unique stack signature.
- A Doxygen warnings file → one item per undocumented symbol.
- A CVE feed → one item per finding ID.
- A test-suite flake report → one item per repeatedly-flaky test.
- A code-search → one item per `TODO` comment matching a pattern.

The harness re-runs the source-of-truth tool on a configurable cadence (default: every iter; override per instance) to discover new items. New items pass through the dedup signature; survivors are added to `pending`.

## Worked example: signature design

A fuzz-crash burndown loop's signature might be:

```
sha256(top_5_frames_with_line_numbers + crashing_pc).hex()[:16]
```

Two crashes with the same signature are treated as duplicates; the worklist row tracks both via `also_seen`.

A type-error elimination loop's signature might be:

```
"<file_path>:<error_code>"
```

So multiple instances of the same error type in the same file are one item, but the same error type in different files are different items.

A doc-coverage loop's signature might be:

```
"<symbol_fully_qualified_name>"
```

So one item per public symbol; stable across renames if the loop's resolution rule is name-based.

The signature design is the most important per-instance decision in a coverage loop. A signature that's too coarse merges things that should be separate. A signature that's too fine produces dedup misses and the worklist drowns.

## Falsifier in the coverage archetype

Coverage loops still ship a falsifier per attempt, even though the verdict is boolean. The falsifier answers: "what cheap experiment proves the proposed fix is **not** the right fix?"

For example:

- In a type-error burndown loop, the falsifier for "add a type annotation" might be "the existing tests pass with the annotation **removed**" — if they do, the annotation is unnecessary, not a fix.
- In a fuzz-crash burndown loop, the falsifier for "this is fixed by patching X" might be "re-run the original repro under the patched build" — if it still crashes, the fix is wrong.
- In a doc-coverage loop, the falsifier for "this symbol is now documented" might be "the docstring is non-empty AND mentions at least one parameter" — a placeholder docstring is not a fix.

The falsifier runs at iter step 6, before applying the change. If it fires, the idea is `discard_falsified` and the item stays in `pending`.

## Hybrid composition

When coverage is the outer loop of a hybrid (outer coverage walks a worklist; inner optimization runs per item), the integration:

1. The outer loop's iter selects an active item.
2. The inner optimization loop is scoped to that one item — its grid is filtered to cells that target this item.
3. The inner runs until it produces a `keep` for the headline objective on this item, or until it exhausts its per-item iter budget.
4. On inner `keep`, the outer marks the item `done` and rotates to the next.
5. On inner exhaustion (budget hit, all cells exhausted), the outer marks the item `blocked` and rotates.

The two loops share the active-item field. Implementation: two instance slugs (`<outer-slug>` and `<outer-slug>-<active-item>` rotating); the outer's Pipeline State section in `mission.md` (rendered from the most recent active-item Decision Log entry) becomes the inner's scope.

This is the cleanest way to handle hybrid loops because each archetype keeps its own queue shape; the only coupling is the active-item field.

## Agent rationalizations the archetype rejects

- **"I'll add this item to the worklist because the source-of-truth tool missed it."** Items come from the source-of-truth tool only. If the tool missed something, fix the tool or the bucketing script — do not write items the bot invented.
- **"I'll rewrite the signature function for this item because the dedup is too coarse."** The signature function is declared at scaffold time and is part of the harness's validation. Mid-session signature rewrites would silently merge or split rows in ways that drift the worklist's history.
