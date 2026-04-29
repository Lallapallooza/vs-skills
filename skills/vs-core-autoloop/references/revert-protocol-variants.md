# Revert protocol variants

*Level: loop-kernel (universal menu of four protocols; the per-instance choice is made at scaffold time).*

The per-iter playbook calls `revert()` and `commit()` hooks. The instance picks one of four protocols at scaffold time. Nothing in the loop kernel hardcodes a specific implementation.

## The four protocols

| Protocol | When to pick | Hooks |
|---|---|---|
| `git-commit-revert` | Code-modifying loops where iters produce diffs | `git commit`, `git reset --hard HEAD^` |
| `branch-per-iter` | Loops where each iter is a branch kept for traceability, merged on keep | `git checkout -b iter-N`, `git merge --ff-only` (on keep), `git checkout main` (on discard) |
| `external-state-snapshot` | Loops touching state outside version control | User-supplied `snapshot()` and `restore()` scripts |
| `no-revert / append-only` | Curatorial loops where each iter is a decision, not a reversible experiment | `commit()` writes the decision; `revert()` is a no-op |

The protocol is declared in `MANDATES.md` at scaffold time and is not changeable without re-scaffolding (a change requires re-rendering MANDATES and clearing `archive/`).

## `git-commit-revert`

Default for any loop where each iter modifies tracked files in a version-controlled tree.

### Hooks

```
commit(verdict, description):
    git add <changed-files>
    git commit -m "autoloop: <verdict> on <target> — <description>"

revert():
    git reset --hard HEAD^
```

The commit message prefix `autoloop:` makes the loop's commits filterable. Description is a one-line summary of the idea.

### Properties

- Each iter is one commit. Revert is one command.
- The version-control log is the durable record; the archive is reproducible from it.
- Tier-2 cross-target guard runs against the just-made commit; if it trips, the harness runs `revert()` and downgrades to `discard_guard`.
- Commits accumulate. The loop's history is auditable as a linear chain.

### Constraints

- The working tree must be clean between iters. The harness asserts this at step 1 (RENDER STATE) by checking `git status --porcelain`.
- The commit author and committer are set by the harness, not the agent. (Agent could lie about authorship; harness sets it deterministically from a config.)
- No `git push` from inside the loop. Pushing is an out-of-band operation.

## `branch-per-iter`

For loops where the user wants to retain failed attempts as branches for later analysis.

### Hooks

```
commit(verdict, description):
    git checkout -b iter-<N>
    git add <changed-files>
    git commit -m "autoloop iter-<N>: <verdict> on <target>"
    if verdict == keep:
        git checkout main
        git merge --ff-only iter-<N>
        git branch -d iter-<N>     # optionally keep; instance config
    else:
        git checkout main
        # iter-<N> branch retained for analysis

revert():
    git checkout main
    # nothing else; the failed branch is just orphaned
```

### Properties

- Failed iters are recoverable as branches if the user wants to re-examine them.
- `main` is always at the latest `keep`; failed iters never appear there.
- Branch count grows; instance config controls retention (default: keep last 100; older orphan branches pruned).

### Constraints

- More disk pressure than `git-commit-revert`.
- Tooling that doesn't expect many branches (e.g., some IDEs that auto-fetch all branches) may slow down.

## `external-state-snapshot`

For loops where iters affect state outside the version-controlled working tree:

- Cloud configurations (Terraform state, Kubernetes manifests applied to a live cluster).
- Database schemas / data.
- Model weights (finetune iters).
- Long-running services whose internal state changes during measurement.

### Hooks

User supplies two scripts at scaffold time. Minimal worked-example skeletons:

```bash
# snapshot.sh — capture all out-of-band state to a per-iter directory
#!/usr/bin/env bash
set -euo pipefail
iter_id="$1"
out=".spec/<slug>/archive/iter-${iter_id}/snapshot"
mkdir -p "$out"

# Filesystem state outside the working tree
tar -cf "$out/external-fs.tar" /etc/myapp /var/lib/myapp 2>/dev/null

# Database
pg_dump --no-owner mydb > "$out/db.sql"

# Cloud config (Terraform)
(cd terraform/ && terraform state pull) > "$out/tf-state.json"

# Model weights / artifacts (size-aware: snapshot the path, not the contents,
# if weights are append-only-immutable)
echo "$(readlink -f models/current.bin)" > "$out/model-pointer.txt"
```

```bash
# restore.sh — reverse of snapshot.sh
#!/usr/bin/env bash
set -euo pipefail
iter_id="$1"
src=".spec/<slug>/archive/iter-${iter_id}/snapshot"

tar -xf "$src/external-fs.tar" -C /
psql mydb < "$src/db.sql"
(cd terraform/ && terraform state push "$src/tf-state.json")
ln -sfn "$(cat "$src/model-pointer.txt")" models/current.bin
```

The skeletons above are illustrative. Real instances will have target-type-specific contents (e.g., a finetune loop's snapshot is mostly the optimizer state file; a cloud-config loop's snapshot is mostly the rendered Terraform plan). The contract: `snapshot.sh <id>` captures everything that needs to be restorable; `restore.sh <id>` reverses it; both must be idempotent.

The harness invokes:

```
commit(verdict, description):
    if verdict != keep:
        restore.sh <iter-id>     # roll back to pre-iter snapshot
    # If keep, the in-tree changes (if any) are committed via git;
    # the snapshot is retained as the new pre-iter snapshot for next time.

revert():
    restore.sh <iter-id>
```

### Properties

- The snapshot script is the user's contract for "what defines the world before this iter."
- Snapshot/restore scripts can use any technology: `terraform state pull`, `pg_dump`, `tar`, etc.
- Reverts are as fast as the user-supplied restore script.

### Constraints

- The user must write and maintain the snapshot/restore scripts.
- Snapshot integrity is the user's responsibility — if the snapshot is incomplete or corrupted, reverts will leave inconsistent state.
- Snapshots may be large (DB dumps, model weights); instance config should declare retention to avoid disk exhaustion.

## `no-revert / append-only`

For loops where each iter is a decision rather than a reversible experiment. Examples:

- PR review backlog: each iter ratifies or rejects a PR; the decision is the artifact.
- Security finding triage: each iter classifies a finding; classification is durable.
- Doc-completeness curation: each iter writes documentation for a symbol; written docs stay written.
- TODO/tech-debt burndown: each iter resolves or defers a TODO; the resolution is the artifact.

### Hooks

```
commit(verdict, description):
    # Append-only write to the appropriate output (decision log, PR comment, etc.)
    write_decision(verdict, description)

revert():
    # No-op. The verdict is itself the artifact.
    pass
```

### Properties

- Reverts are not meaningful — there's nothing to revert. A `discard_*` outcome means "this iter's attempt didn't resolve the item; try a different idea next time."
- The version-control log records each decision as a commit (with `autoloop: decision on <item>` prefix), but the decision itself is the artifact, not a code change.
- Coverage-archetype loops with `no-revert` typically use a subset of the 9-value enum: `keep`, `discard_falsified`, `discard_test`, `crash`, `hang`, `discard_environment_changed`. Lane transitions (`needs-human-review`, `won't-fix`, `blocked`) happen alongside the verdict at step 11 — they are queue-shape changes, not verdict variants. Numeric verdicts (`discard_objective`, `discard_secondary`) don't apply when the verdict is boolean.

### Constraints

- The instance must be careful that decisions are reversible at higher levels (a wrong PR-review ratification can be re-reviewed; a wrong doc commit can be edited later). The protocol assumes this at the human level.
- Tier-2 cross-target guard typically does not apply, since changing one decision doesn't affect other decisions.

## How the wrapper invokes the hooks

```
# Step 8: APPLY CHANGE — agent writes to working tree.
# Step 9: MEASURE — tool emits measurement.
# Step 10: RENDER VERDICT.
# Step 11: APPLY VERDICT.

verdict = read_verdict()

if verdict == "keep":
    commit(verdict, description)
    if has_tier2_guard:
        run_tier2_guard()
        if tier2_regressed:
            revert()
            verdict = "discard_guard"
            commit(verdict, description)  # for protocols where commit happens regardless
elif verdict.startswith("discard_") or verdict in ["crash", "hang"]:
    revert()
else:
    raise ValueError(f"unknown verdict: {verdict}")
```

## Choosing the right protocol at scaffold time

The scaffold-time grill asks:

1. Does the loop's iter modify files in a version-controlled tree? → `git-commit-revert` or `branch-per-iter`.
2. Does the loop's iter affect state outside the tree? → `external-state-snapshot`.
3. Is each iter a decision rather than a reversible experiment? → `no-revert / append-only`.
4. Do you want failed iters retained as branches? → `branch-per-iter` over `git-commit-revert`.

Mixed cases (some iters modify files, others affect external state) are not supported — pick one protocol and adapt the other dimension. If the work genuinely requires both, scaffold two instances (hybrid composition).

## Boundaries

The protocol covers local revert only. Multi-machine deployment, pushing to remotes, and history compaction are out of scope; those are explicit user actions outside the loop. If revert fails (working tree dirty, branch conflicts), the wrapper emits `crash` with `description=revert_failed` and pauses for manual resolution.
