---
name: vs-core-plain
description: Write or rewrite text in plain, simple English using ASD-STE100 and plain-language rules. Use this skill when the user asks to simplify text, says "simple english", "STE", "ASD-STE100", "plain language", "make it simpler", "too verbose", "oververbose", "I don't get the point", or is drafting a message for a non-native-English audience such as upstream maintainers, mailing lists, issue threads, or docs.
allowed-tools: Read Glob Grep Bash Edit Write
---

# Plain Writing

Produce text that a tired non-native reader understands on the first pass.

This is the constructive counterpart to `vs-core-tropes`. Tropes detects AI patterns in text that already exists. This decides how text gets written. For anything going to a public audience, run both.

## Reference Files

- `references/evidence-base.md` -- the mechanisms: why unclear writing happens, and what the research supports. Read this when a rule seems wrong, or when justifying a rewrite.
- `references/writing-rules.md` -- the operational rule set with STE numerics and substitution tables.

Load `writing-rules.md` for any rewrite. Load `evidence-base.md` when a rule conflicts with clarity, when the user challenges a rule, or when deciding how far to simplify.

## Pick the Mode First

The register decides which rules apply. Choosing wrong is the most common failure.

| Mode | Use for | Rules |
|---|---|---|
| **Strict** | Procedures, CLI help, error messages, tool descriptions, safety text, API docs | All rules. 20-word limit. Imperative. No exceptions without saying so. |
| **Prose** | Issue comments, maintainer threads, RFCs, READMEs, design docs | Structural rules only: 25-word limit, active voice, one word one meaning, no hedges. Keep the grammar needed to concede, disagree, and ask. |

STE was built for maintenance manuals: one actor, procedures, no argument. A discussion post needs to say "I disagree, but you are right about X", and STE has no grammar for that. Applying strict mode to a debate produces text that is simple and useless.

**Never import** into prose mode: the 900-word dictionary, imperative-only mood, the ban on past participles as verbs.

## Process

1. Read the target text, or the request if writing from scratch.
2. Identify the audience and pick the mode. State which mode you chose.
3. Apply `references/writing-rules.md`, in this order:
   - **Order first.** Fix given-new flow before anything else. It outranks length.
   - **Cut hedges and padding.** Highest yield, shortens and strengthens together.
   - **Promote buried verbs.** Usually fixes length and missing actors at once.
   - **Then split long sentences**, if they are still long.
4. **Mandatory:** run the checker.
   ```bash
   bash <skill-dir>/check-plain.sh <target-path>
   ```
5. Triage every flag. Fix it, or record it as a false positive with the reason. The checker is dumb by design.
6. If the text is public-facing, run `vs-core-tropes`.

## Output

```
## Plain Rewrite

**Mode**: strict | prose
**Before**: N words, longest sentence M
**After**: N words, longest sentence M

[the rewritten text, no preamble]

### Changes
- [what changed and which rule drove it]

### Kept as-is
- [anything breaking a rule on purpose, with the reason]

### Checker
- [flags triaged: fixed, or false positive with reason]
```

When the user asked only for a rewrite, output the text alone. Add the sections when they ask what changed, or when you broke a rule and need to say why.

## Failure Modes

These are the ways this skill goes wrong. Check yourself against them before returning.

**Optimising the metric.** Word counts predict only 23-34% of variance in real reading ease. "Mike eats your cat gun now!" passes every formula. Splitting a sentence to get under 25 words, at the cost of the given-new chain, makes the text worse while improving the score. See `evidence-base.md` §8.

**Deleting meaning to hit a rule.** The single unacceptable failure. If a claim is uncertain, say so in plain words. Removing a genuine qualification is a change of meaning, not a simplification.

**Flattening register.** Prose that concedes, disagrees, or asks needs grammar that strict mode forbids. Simple is not the same as blunt, and a maintainer thread is not a manual.

**Simplifying for a peer audience.** Two people with identical context can compress heavily. Novice-level plainness there wastes time and can read as condescension. Match the reader you have.

**Trusting your own reread.** The curse of knowledge means rereading re-activates the context the reader lacks, so it feels clear to you regardless. This is why the checker is mandatory rather than advisory. See `evidence-base.md` §1.

## Discussion Threads

For issue threads, mailing lists, and chat with maintainers. These are communication rules, not clarity rules, and they compound with the writing above.

- **One question per message.** Five questions reliably gets one answered, and you do not choose which.
- **Offer the candidate answers.** "Do you mean A, or B?" gets a reply in four words. "What did you mean?" gets silence.
- **Lead with the concession.** Grant the valid point first. This removes their need to defend it, and the rest stops reading as defence.
- **State facts, not verdicts.** Dates and evidence let the reader reach the conclusion. Handing them the conclusion invites an argument about the conclusion.
- **Do not hard-wrap.** Chat clients soft-wrap. Hard-wrapped text pasted into Zulip, Slack, or GitHub renders broken. One paragraph, one line.
