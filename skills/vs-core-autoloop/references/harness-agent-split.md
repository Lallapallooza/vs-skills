# Harness/agent split — the load-bearing principle

*Level: loop-kernel (universal across archetypes and target types).*

Every artifact the loop produces has exactly one author: either a **harness script** or the **agent**. Co-authored artifacts are forbidden.

This is the only line of defense against the failure modes that took down prior autonomous-loop projects: agents producing fake or selectively-quoted tool output to satisfy a checklist; agents reading authoritative-looking artifacts they themselves produced and treating them as ground truth; runaway sessions that accumulate self-reinforcing errors.

## The split

| Artifact | Author | Why |
|---|---|---|
| Locks (per-measurement-primitive) | **Harness** | Forgeable if the agent owns them; concurrent runs corrupt the next iter's measurement |
| Environment fingerprint manifest | **Harness** | Same — the manifest is the input to the verdict; the agent must not be able to alter it |
| Measurement output | **Tool** (the measurement primitive) | The verdict's input must be reproducible from inputs alone |
| Test/correctness results | **Tool** (the test runner) | Same |
| `mission.md` Head sections (Pipeline State, Scoreboard, Compact-recovery, Resume Protocol) | **Renderer script** | Regenerable cache over the Decision Log + git/file state; agent edits are silently overwritten |
| `mission.md` Decision Log entries — all kinds **except** `[kind=lesson]` | **Harness** | Mechanical functions of inputs; the agent must not "decide" verdicts. Canonical kind list in [`directory-layout.md`](directory-layout.md) § "Decision Log kinds". |
| `mission.md` Decision Log entries — `[kind=lesson]` only | **Agent (text)** + **Harness (row format)** | Lesson body is what LLMs are good at; the row format and the bounded length are harness-enforced |
| `archive/iter-<N>/` measurement payloads | **Tool** (the measurement primitive); **Harness** (manifest, change.diff) | Immutable record; referenced from Decision Log entries by relative path |
| `queue/ideas/<id>.md` or `queue/worklist.tsv` rows | **Agent (body)** + **Harness (frontmatter schema)** | Free-text body is the agent's contribution; frontmatter is validated |
| Hypothesis text, mechanism notes, commit messages | **Agent** | Narrative ownership is fine; these are not verdict inputs |
| Working tree changes | **Agent** | This is the experiment |

## Worked rationale per row

### Why locks must be harness-authored

If the agent owns the lock primitive, it can rationalize past it on a slow iter ("the lock is a soft suggestion; I'll proceed"). Documented across multiple production incidents in the autonomous-loop literature. Concurrent measurement-primitive runs corrupt each other's numbers — the verdict input becomes meaningless.

The lock acquisition is therefore a wrapper script's job, not the agent's. The agent invokes the wrapper; the wrapper acquires the lock or fails fast. The agent has no way to "skip" the lock.

### Why the verdict must be renderer-authored

The verdict is a **function of measurement output + thresholds + cross-target guard + test result**. Functions of inputs are renderer territory. If the agent computes the verdict, the agent can:

- Round in its favor on a borderline measurement.
- Selectively report tier-1 guard cells.
- Rationalize past a flaky test.

None of these are detectable from the agent's commit message; they require the renderer's deterministic logic to expose.

### Why the Head must be re-rendered, not appended

The Head sections of `mission.md` (Pipeline State, Scoreboard, Compact-recovery checklist, Resume Protocol) are a regenerable cache. The Decision Log is the source of truth.

If the agent could append to the Head, the Head would become a confirmation cache: the agent reads its own past summaries on the next iter and treats them as ground truth even when the underlying primary sources have moved on (commits reverted, queue items resolved by other processes, lessons that turned out wrong).

The render-don't-append rule means the Head is always a fresh function of the Log + git/file state. If reality moved, the Head's next render reflects it. The agent's previous summary is overwritten. This is the orchestration-tier protocol's "Log wins; Head is regenerated" rule applied to autoloop.

### Why idea-queue rows have a co-authored shape

Ideas are inherently the agent's contribution — they encode hypotheses no script can generate. But the idea queue's shape (mechanism class, falsifier presence, status enum) is the harness's responsibility. The frontmatter is validated; the body is free text.

Concretely: if the agent writes an idea without a `false_signal` field, the harness rejects it at queue-write time. The agent cannot bypass the falsifier requirement by simply "forgetting" to author one.

### Why working tree changes are agent-authored

This is the experiment. The agent is doing exactly the work that requires LLM judgment — applying a small change matching a hypothesis to a specific symbol or configuration. There is no script that does this; if there were, it would be a bigger refactoring tool, not an autoloop.

The agent's writes here are recorded by the version-control system (or the revert protocol's equivalent), so the harness can revert them mechanically at step 11.

## What this rules out

- **The agent must not write `[kind=verdict]` entries.** Even one carefully-narrated "I think this is a `keep`" entry pollutes the renderer's contract. Verdict entries are harness-emitted only.
- **The agent must not edit existing Decision Log entries.** The Log is append-only by protocol; entries are immutable once written.
- **The agent must not rewrite the Head sections to "fix" what it sees.** The next regeneration fixes it; agent edits would be silently lost.
- **The agent must not bypass the lock.** "I checked; nothing else is running" is not evidence; the lock acquisition is the evidence.
- **The agent must not edit the environment fingerprint.** If the host changed, the next iter's render will reflect it; the agent does not get to declare the host stable.

## What this enables

- **Compaction-resistant restart.** STATE is a render of primary sources; if the agent's context is wiped, the next iter's STATE is fresh and complete.
- **Auditability.** The verdict is a deterministic function of recorded inputs; any disputed verdict can be re-derived from the archive.
- **Schema stability.** The harness owns the schema for the Decision Log entries, the queue, the verdict enum, and the manifest. Drift requires explicit code change to the harness, not agent improvisation.
- **Concurrent-instance safety.** Two instances sharing a measurement primitive share a lock; neither can corrupt the other's numbers.

## Common rationalizations the rule rejects

| Rationalization | Why it's rejected |
|---|---|
| "I'll write the verdict because the renderer is slow." | The renderer is a 50-line script; if it's slow, fix it. The verdict cannot move to the agent. |
| "I'll patch the Head because the renderer is missing a field." | Add the field to the renderer. Agent-side patches are silently overwritten on the next render. |
| "I'll skip the lock because nothing else is running." | The lock is the evidence. Without it, the assertion is unverifiable. |
| "I'll log this as `keep` even though tests are flaky." | The test result is the test runner's authority. If the suite is flaky, fix the suite or mark it as a known-flaky in the renderer's input. |
| "I'll edit a past `[kind=verdict]` entry because the description field was too short." | Append a `[kind=verdict-correction]` entry referencing the original by iter id (this kind exists in the canonical list for exactly this case). The Log is append-only; existing entries are immutable. |

## Implementation note for the harness scripts

The harness is not a single binary; it is a small set of single-purpose scripts:

- `lock-acquire`, `lock-release`
- `fingerprint-emit`, `fingerprint-compare`
- `target-select`
- `falsifier-run`
- `verdict-render`
- `revert-apply`, `commit-apply`
- `archive-snapshot`
- `state-render`

Each is short (under 100 lines typically). Each has a single owner, a single output, and is invoked by the wrapper that runs the per-iter sequence. The wrapper is itself short — its job is to call the scripts in order and route failures to the right verdict.

The agent never invokes these scripts directly. The wrapper invokes them; the agent invokes the wrapper.
