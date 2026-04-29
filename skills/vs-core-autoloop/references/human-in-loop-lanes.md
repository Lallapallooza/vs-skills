# Human-in-loop lanes

*Level: loop-kernel (universal queue-shape pattern; archetype-level integration documented inline).*

When some verdicts require a human to ratify, the integration is a **queue-shape change**, not a verdict-state change.

The bot writes to `pending` and `in-flight`. Only humans move items from `needs-human-review → done` (or `→ won't-fix`).

The verdict enum stays at 8 values; human gating is queue-side, via lanes.

## Why a lane, not a verdict

Adding a `pending-human-review` value to the verdict enum looks tempting but is the wrong shape:

- Verdicts are per-iter. Lanes are per-item (in coverage archetype) or per-cell (in optimization archetype). Many iters can target one item; the human-review state belongs to the item.
- A verdict-state approach makes the queue length invisible. Lanes make it explicit and queryable.
- The published triage tools (Prodigy, Snorkel, Phabricator, bug-bounty platforms) all converged on lanes. None use a `pending-review` verdict shape.

## The lanes

```
pending           — bot may act
in-flight         — currently being attempted (single-iter tenancy)
needs-human-review — bot has acted; only human can move to done
done              — terminal
won't-fix         — terminal with rationale
blocked           — paused; agent may not pick this until unblock condition fires
```

### `pending`

Default lane for new items. The bot picks from here.

### `in-flight`

The active item moves here at iter step 4 (SELECT TARGET). Single-iter tenancy: at most one item can be in `in-flight` per instance. After the iter completes, the item moves to a terminal lane (`done`, `needs-human-review`) or back to `pending` for retry.

### `needs-human-review`

The bot has acted on the item but believes a human should ratify before it becomes terminal. Triggers:

- Confidence below a threshold (e.g., dedup ML returned 0.7 confidence, threshold is 0.9).
- Sensitivity flag (the item touches code/data marked as requiring human review).
- The instance's verdict policy: certain verdicts always go to review (e.g., security-finding fixes always need human ratification before merging).

The bot writes to this lane; only humans drain it. When a human reviews:

- Item passes review → human moves it to `done` (or merges the underlying PR, etc.).
- Item fails review → human moves it back to `pending` with a `defer_reason` note, or to `won't-fix` with a rationale.

The agent does not loop on `needs-human-review` items. The instance pauses progress on those items until human action.

### `done`

Terminal. The item is resolved; it stays in the queue for audit/history but does not re-enter the rotation unless its underlying source changes (and the source-of-truth tool re-discovers it on a refresh).

### `won't-fix`

Terminal with a rationale. The instance treats this as resolved-with-decision. Items here are **not** re-discovered by the source-of-truth tool (the harness adds a fingerprint that suppresses re-detection — implementation-specific to the source tool, but the principle is universal).

### `blocked`

Paused. The bot may not pick. Triggers:

- K consecutive `discard_*` on the item (default K=5).
- Explicit user/agent decision (e.g., "blocked on dependency Y").
- A declared unblock condition is not met (e.g., "unblock when item Z is done").

The instance configures the unblock policy. Default: human action required to unblock.

## Lane transitions

```
[discovered]
     │
     ▼
  pending ◄─────── (after discard_*)
     │
     ▼
 in-flight
     │
     ├── (keep + low confidence) ──► needs-human-review ──► (human) ──► done
     │                                     │
     │                                     └── (human) ──► pending  (with defer_reason)
     │                                     └── (human) ──► won't-fix
     │
     ├── (keep + high confidence) ──► done
     │
     ├── (discard_*) ──► pending  (attempts++)
     │       │
     │       └── (after K rejects) ──► blocked
     │
     └── (lane move to blocked, with unblock condition)
```

## Confidence threshold for routing to review

Some loops route every keep through `needs-human-review`. Others route only borderline cases. The threshold is per-instance.

Common shapes:

- **Always-review**: all keeps go to human review. For high-stakes loops (security fixes, production deploys).
- **Confidence-gated**: bot routes to review only when its confidence (e.g., dedup ML score, model log-prob) is below a threshold.
- **Sensitivity-gated**: bot routes based on item attributes (file path, severity, blast radius).
- **Sample-gated**: bot routes a random sample (1 in N) for QA, even if all are high-confidence.

The instance declares the policy at scaffold time. The harness implements it deterministically; the agent does not "decide" whether to route.

## Multiple human reviewers

If the instance has multiple human reviewers, the harness can implement work-stealing — each reviewer pulls from a per-reviewer slice of `needs-human-review`. The slicing rule (round-robin, file-path hash, expertise tags) is per-instance.

The autoloop skill does not prescribe a slicing rule. It supports per-reviewer slicing if the instance config declares one.

## Defer vs skip

When a human moves an item out of `needs-human-review`, they choose:

- `→ done`: the item is resolved.
- `→ won't-fix`: the item is resolved-with-decision; never re-discovered.
- `→ pending` (with `defer_reason`): the item is sent back; the bot will pick it up again, with the defer reason as context for the next attempt.
- `→ blocked` (with unblock condition): the item is paused until the condition fires.

These are different. `won't-fix` is final; `pending` recycles; `blocked` waits. The agent reads the `defer_reason` when re-attempting an item that came back from review.

## Human action without a UI

The skill does not ship a UI. Human reviewers act on the queue file directly:

- Edit the row's `lane` field.
- Add a `defer_reason` or `unblock_condition` field.
- Commit the edit.

For instances that integrate with external tools (PR systems, ticket trackers, code-review platforms), the integration is per-instance. The harness can read the external tool's state (e.g., PR merged) to auto-update lanes — but only as a one-way sync (external → queue), never the reverse without explicit human action.

