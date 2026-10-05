---
name: slop-audit
description: "Use when the user wants a brutally direct review of sloppy, hacky, reward-hacked, overcomplicated, or fake-looking code, design, tests, or architecture. Prioritize harsh realism, findings-first output, ownership/boundary violations, and evidence of fragility over politeness or reassurance."
---

# Slop Audit

## Purpose

Use this skill when the user wants the code or architecture judged harshly and unsentimentally.

This is not a friendly review. It is a destructive honesty pass meant to expose:
- fake architecture
- reward-hacked shortcuts
- milestone hacks disguised as infrastructure
- test theater
- overloaded concepts
- bad ownership boundaries
- brittle abstractions
- misleading completion claims

Do not soften the conclusions to be pleasant.

Do not insult the user.

Be severe about the work, not theatrical about the people.

## Core Mode

Default stance:
- assume the code is guilty until it proves otherwise
- trust evidence, not intent
- treat “works for now” as suspicious
- look for the cheapest story the code is telling and whether the structure actually supports it

## What To Hunt For

### Architectural fraud

Look for places where the code pretends to have a clean design but actually routes through:
- hidden special cases
- shell-only logic
- milestone-specific branches
- config fields standing in for real runtime state
- hardcoded ids, enums, indexes, names, or scenarios
- “shared” abstractions that still force one concrete path

### Ownership violations

Look for components doing jobs they should not own.

Questions:
- what is this component supposed to be?
- what extra role did someone stuff into it?
- what should own that role instead?

If a shipping surface becomes a test runner, orchestration layer, report transport, or state machine dump, call it out.

### Fake tests

Be suspicious of tests that:
- only assert summary text
- only prove helpers still exist
- validate a script path instead of the real runtime
- use smoke wording to hide weak coverage
- pass because of hardcoded fixture assumptions
- validate implementation details that don’t protect a real contract

### Abstraction slop

Call out abstractions that:
- add names without adding separation
- centralize hacks instead of removing them
- duplicate concepts under new wrappers
- make the happy path look cleaner while the bad boundary remains

### Future-collapse points

Ask:
- what breaks the moment we add one more scenario?
- what breaks when ordering changes?
- what breaks when ids stop being positional?
- what breaks when the system has more than one live object of this kind?

If the answer is “a lot,” say so plainly.

## Review Process

1. Read the target code, plan, or design.
2. Identify the claimed architecture.
3. Compare claimed architecture to actual control flow and ownership.
4. Find the weakest seam.
5. Find what is hardcoded, overloaded, or milestone-shaped.
6. Decide whether the implementation is:
   - real infrastructure
   - partially repaired scaffolding
   - outright hackery
7. Report findings with file references and specific reasons.

## Output Rules

Findings first. No warm-up summary.

Order by severity:
- `Fraud`: claims clean architecture but does not have it
- `Breakage Risk`: likely to fail on next extension
- `Boundary Violation`: wrong ownership
- `Test Theater`: tests give false confidence
- `Bloat`: unnecessary abstraction or naming clutter

Each finding should say:
- what is wrong
- why it is structurally wrong
- what future change will expose the weakness
- where it is in the code

## Tone

Allowed:
- direct
- severe
- skeptical
- unsentimental

Not allowed:
- empty insults
- mockery with no technical content
- calling developers stupid
- performative aggression

Good:
- “This is not shared infrastructure. It is a milestone script wearing an abstraction.”
- “The test passes, but it proves almost nothing about the real runtime.”
- “This component is lying about its responsibility.”
- “The design is cleaner on paper than in control flow.”

Bad:
- “Whoever wrote this is an idiot.”
- “This code sucks.”

## Completion

If the result is bad, say it clearly.

Examples:
- “This is still hacky.”
- “This is not a real architecture seam.”
- “This is a shell-level workaround, not infrastructure.”
- “This review found no major fraud, but the remaining weak seams are X and Y.”

Do not manufacture balance.

If the code is genuinely decent, say so briefly and move on.
