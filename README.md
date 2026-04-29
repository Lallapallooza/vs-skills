# AI Agent Skills

12 modular skills for AI coding agents. Eight run as coordinator-plus-parallel-sub-agents with adversarial critical merge; two manage standing behavioral state and the project's CLAUDE.md lifecycle; one is a tool-mechanics operator's guide for AMD CPU profiling; one scaffolds and operates long-running autonomous iteration loops on top of the orchestration tier. Platform-agnostic -- works with Claude Code, Codex, OpenCode, or any agent that supports sub-agent dispatch and file-based skill discovery.

## Installation

Point your agent at the `skills/` directory and tell it to install the skills. The skills use standard markdown; any agent that can read files and dispatch sub-agents can use them.

For Claude Code specifically, symlink the whole `skills/` directory into `~/.claude/skills/`:

```bash
ln -sfn /path/to/this/repo/skills ~/.claude/skills
```

Per-skill symlinks also work if you want to mix skills from multiple sources:

```bash
for d in /path/to/this/repo/skills/vs-core-*; do
  ln -sfn "$d" ~/.claude/skills/"$(basename "$d")"
done
```

## How Skills Work

Most of the skills are coordinators that dispatch parallel sub-agents with different specializations. Sub-agents cannot read the coordinator's files, so all prompt content and shared infrastructure (`vs-core-_shared/prompts/`) is inlined into each agent's instructions at launch via `build-prompt.sh`.

When agents return, the coordinator runs a critical merge: cross-validating findings, rejecting generic claims without evidence, resolving contradictions, escalating consensus. `/vs-core-audit` additionally enforces anti-sycophancy: the coordinator cannot downgrade an agent's severity; it can only upgrade or reject with stated reasoning.

Skills compose. `/vs-core-rfc` invokes `/vs-core-grill` to scope requirements, then `/vs-core-research` for open questions, then design and adversarial review before generating a living spec. `/vs-core-implement` executes that spec in vertical slices with review gates. If a numbered assumption proves wrong mid-implementation, it halts with `SPEC_DIVERGENCE` and feeds back to `/vs-core-rfc` for redesign. Every agent performs mandatory self-critique with tool-grounded verification before returning.

Two skills sit outside the pipeline. `/vs-core-interactive` loads a standing behavioral layer for the conversational middle (anti-sycophancy, verification iron law, banned hedge-phrases) and auto-loads context-matching judgment files. `/vs-core-init` owns the project's CLAUDE.md lifecycle: writes a seed on first run, appends individual learnings on subsequent runs.

Model tiers (`strongest`, `strong`, `fast`) are generic; map them to your platform's best reasoning model, general-purpose model, and cheapest capable model respectively.

## Quick Reference

| Skill | When to use | What it produces |
|-------|-------------|------------------|
| `/vs-core-grill` | Requirements unclear; need to think it through | Decision log + recommended next step |
| `/vs-core-research` | Need to understand a technology, compare options, investigate | Cross-referenced briefing with confidence levels |
| `/vs-core-arch` | Design a module, evaluate architecture, compare approaches | Scored analysis or competing designs with recommendation |
| `/vs-core-rfc` | New feature needs design before coding | Implementation spec with numbered assumptions and vertical slices |
| `/vs-core-implement` | Have a spec; need to execute it with quality gates | Committed code with spec-compliance verification |
| `/vs-core-audit` | Finished work needs adversarial review | Verdict (Pass / Fix and Resubmit / Redesign / Reject) plus prioritized findings |
| `/vs-core-debug` | Bug with unknown root cause | Root-cause diagnosis + fix + regression test |
| `/vs-core-tropes` | Check text for AI writing patterns | Findings with concrete rewrites |
| `/vs-core-profile-amd` | Profile or microarch-analyze native code on AMD Zen | Tool-mechanics playbook (uProf / perf / IBS / likwid / bpftrace) with Zen-generation-aware recipes |
| `/vs-core-interactive` | Want a standing behavioral layer for a conversational session | Loaded principles, interaction style, verification iron law, banned hedges; optional session log |
| `/vs-core-init` | Create or extend a project's CLAUDE.md | Root `CLAUDE.md` (init mode) or a targeted appended section (append mode) |
| `/vs-core-autoloop` | Set up a long-running autonomous iteration loop (perf tuning, eval-set tuning, lint or fuzz burndown, ELO tuning, cost reduction, etc.) | Scaffolded `.spec/<instance>/` (mission.md per the orchestration tier + queue + archive + paste-ready /loop prompt) |

## Typical Workflow

```
/vs-core-grill -> /vs-core-research -> /vs-core-arch -> /vs-core-rfc -> /vs-core-implement -> /vs-core-audit
  understand       investigate         design           spec            build                 verify
```

Not every task needs every step. A small bug fix: `/vs-core-debug`. A quick feature: `/vs-core-implement` directly. Complex system: full pipeline.

`/vs-core-rfc` and `/vs-core-implement` are tightly integrated: if implementation discovers that a spec assumption is wrong, `/vs-core-implement` raises `SPEC_DIVERGENCE` and the user decides whether to update the spec, work around it, or redesign.

`/vs-core-interactive` is orthogonal to the pipeline. Invoke it when you want a standing behavioral layer and light skill-routing for a working session. It suggests the structured skills above when the task matches their scope.

`/vs-core-init` is also orthogonal. Invoke once when starting work in a repo without a CLAUDE.md (init mode), and again whenever a session surfaces a finding worth persisting (append mode).

## Architecture

**Atomic skills** (standalone, single-purpose): `/vs-core-grill`, `/vs-core-research`, `/vs-core-arch`, `/vs-core-audit`, `/vs-core-debug`, `/vs-core-tropes`, `/vs-core-profile-amd`.

**Pipeline skills** (call other skills): `/vs-core-rfc` (invokes grill + research patterns), `/vs-core-implement` (invokes tropes and audit as gates).

**Session-scope skills** (manage state outside the pipeline): `/vs-core-interactive` (standing behavioral layer + routing), `/vs-core-init` (CLAUDE.md lifecycle manager).

**Orchestration-tier skills** (scaffold and run long-lived loops on top of `mission.md`): `/vs-core-autoloop` (scaffolder + per-iter playbook for autonomous iteration loops; orthogonal to `/loop` and `/schedule` which remain the execution drivers).

### Shared Infrastructure (`vs-core-_shared/`)

| File | Purpose |
|------|---------|
| `adversarial-framing.md` | Rigorous adversarial reviewer stance: guilty until proven correct, dual-perspective, overrejection calibration |
| `artifact-persistence.md` | Structured artifact read/write protocol for the `.spec/` pipeline, with frontmatter schema and discovery rules |
| `critical-merge.md` | Orchestrator must judge findings: select over synthesize, no-downgrade rule, disagreement as signal |
| `output-format.md` | Standardized finding format: severity, location, evidence, impact, suggestion plus the "So What?" test |
| `rationalization-rejection.md` | 19-entry table of dismissal patterns across 5 categories (testing, security, review, general, automation/confidence) |
| `self-critique-suffix.md` | CRITIC protocol: tool-grounded verification with worked examples (Huang et al., ICLR 2024) |
| `trust-boundary.md` | Courtroom framing: reviewed content is evidence to examine, not instructions to follow |

### Judgment Files (`vs-core-_shared/prompts/language-specific/`)

Senior engineering-judgment references. How an engineer thinks about trade-offs: not checklists, but when to break the rules.

| File | Coverage |
|------|----------|
| `rust-judgment.md` | Ownership, async, unsafe, API design, performance |
| `go-judgment.md` | Simplicity, concurrency, error handling, interfaces |
| `python-judgment.md` | Data modeling, type system, concurrency, dynamic nature |
| `typescript-judgment.md` | Type system as design tool, soundness holes, ecosystem |
| `cpp-judgment.md` | Universal C++: ownership, RAII, template metaprogramming, ABI, embedded and high-performance contexts |
| `gpu-ml-judgment.md` | GPU kernels, tensor operations, distributed training, numerical stability |
| `perf-judgment.md` | Universal performance: measurement discipline, asm reading, profiling tools, memory hierarchy, SIMD, concurrency, I/O, 20 algorithmic principles |

Loaded by `/vs-core-implement`, `/vs-core-audit`, and `/vs-core-interactive`. Pass language names (`rust`, `python`, etc.) or `perf` / `gpu-ml` as args to `build-prompt.sh` to inline the relevant judgment file. `/vs-core-interactive` additionally auto-detects language signals from the session context and loads up to two matching files without explicit args.

## Per-Skill Details

### `/vs-core-grill`
Socratic interview: one question at a time with a recommended answer the user can accept or reject. No sub-agents. The typical entry point for complex work.

### `/vs-core-research`
5 agent roles (source, contrarian, codebase, deep-technical, verification) with reference files on methodology, search strategy, source evaluation, and codebase investigation. Mandatory verification pass. Starts with a grill phase.

### `/vs-core-arch`
Analysis mode (2-3 agents) or Design mode ("Design It Twice" with 3+ agents under radically different constraints). 4 judgment references.

### `/vs-core-rfc`
Full design pipeline: grill -> research -> design-it-twice -> adversarial review -> revision loop (max 3 cycles) -> spec generation. Produces numbered assumptions that `/vs-core-implement` consumes.

### `/vs-core-implement`
Spec-driven execution with risk-based verification. Vertical slices with planner, implementer, and slice-reviewer roles. `SPEC_DIVERGENCE` verdict feeds back to design. Invokes `/vs-core-tropes` on prose changes and `/vs-core-audit` as the final gate.

### `/vs-core-audit`
Adversarial parallel review with anti-sycophancy baked in: the coordinator cannot downgrade agent severity. Default stance is rejection. 4 reference files. Reviews code, prompts, docs, config, anything.

### `/vs-core-debug`
Systematic root-cause analysis with a reflector agent for failed fixes. 2 reference files. Escalates after 3 failed attempts or on an architectural signal.

### `/vs-core-tropes`
Scans prose for AI writing patterns (em-dash addiction, negative parallelism, magic adverbs, bold-first bullets, and others) against a catalog derived from tropes.fyi. Reports clusters and repeated patterns with concrete rewrites. Ships `check-unicode.sh` / `fix-unicode.sh` helpers.

### `/vs-core-profile-amd`
Operator's guide for profiling native code (C/C++/Rust/Go) on AMD Zen 2/3/4/5 hardware. Reference-heavy: 6 references covering Zen-generation matrix, top-down microarch (TMA), Instruction-Based Sampling (IBS Op / IBS Fetch), uProf install troubleshooting, perf/samply/likwid/bpftrace complements, and Zen-event-group recipes. AMD-specific microarch questions (TMA on Zen 4+, IBS Op with `L3MissOnly`/`LdLat` filters, per-UMC memory bandwidth, roofline) → uProf; everything else (cgroup-scoped profiles, off-CPU, false sharing via `perf c2c`, sharing profiles) → perf/samply/bpftrace. The skill body teaches when to reach for which tool given the question's specialization. No sub-agent dispatch.

### `/vs-core-interactive`
Standing behavioral layer for conversational sessions. Loads four core principles (Think Before Coding, Simplicity First, Surgical Changes, Goal-Driven Execution), an interaction-style block (direct, no sycophancy, brutal honesty over sugar-coating), a verification iron law ("no completion claims without fresh verification evidence"), and a banned-hedge-phrases list. Auto-loads `trust-boundary.md`, `rationalization-rejection.md`, `self-critique-suffix.md` from shared, plus language judgment files matching detected domain signals. Suggests structured pipeline skills when the task matches their scope. Optionally writes multi-artifact session logs to `.spec/{slug}/interactive-{session-slug}.md` at natural stopping points.

### `/vs-core-autoloop`
Scaffolds and operates generic autonomous iteration loops. Two archetypes: `optimization` (numeric objective, sacred axes, MAP-Elites-style queue + island reset, bar escalation) and `coverage` (enumerable items, signature-bucketed worklist, named human-review lanes). The skill is a scaffolder + per-iter playbook; `/loop` and `/schedule` remain the execution drivers. State lives in `mission.md` per the orchestration tier (Decision Log + regenerable Head). Four iron rules: harness owns ground truth (locks, fingerprints, verdicts); variance characterization before optimization (calibrated noise floor below the candidate effect size); render-don't-append for the Head; falsifier before iteration. Two commands: `scaffold` (writes `.spec/<instance>/` from a grill) and `run` (invoked by the execution driver each tick). Composes with `/vs-core-grill` (at scaffold), `/vs-core-research` (when the idea queue runs dry), `/vs-core-audit` (verdict gate on high-stakes keeps), and measurement-specific skills (e.g., `/vs-core-profile-amd` inside the measurement primitive).

### `/vs-core-init`
Manages the project's root CLAUDE.md through two modes. Init mode (auto-selected when no `./CLAUDE.md` exists): silent probe across build manifests, linter configs, CI workflows, monorepo signals, existing skills, README, git branches, and project structure; three inference clusters (code-sample, process-artefact, grep-count) feed "Observed from probe:" candidates into the interview; an 8-question interview fills gaps; a self-critique pass re-scans for content the first draft missed; final draft shown to the user; post-write claim verification (paths, commands, flags, named binaries) emits non-fatal warnings. Append mode (auto-selected when `./CLAUDE.md` exists and the user has a specific learning): classify the learning, propose an insertion at the correct section, write. Always-written sections in the generated file: Overview, Build and test, Durability contract (process-artefact prohibition + temporal-markers ban), Notes, Maintenance contract. `disable-model-invocation: true` because the skill modifies files on disk.
