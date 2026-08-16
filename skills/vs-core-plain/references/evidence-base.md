# Evidence Base for Plain Writing

A decision framework for making text comprehensible, grounded in psycholinguistics and controlled-language research. Each topic gives the mechanism, the practical implication, the conditions where it fails, and the smell that tells you it is failing.

Read this to justify a rewrite. Read it also when a rule in `writing-rules.md` seems wrong for the text in front of you. The rules are downstream of these mechanisms. When a rule and a mechanism conflict, the mechanism wins.

---

## Why Unclear Writing Happens

### 1. The Curse of Knowledge -- The Root Cause, Not a Style Failure

Nickerson (Psychological Bulletin, 1999), "How We Know -- and Sometimes Misjudge -- What Others Know", established that people systematically impute their own knowledge to others. Newton's 1990 Stanford tapping study is the sharpest demonstration: participants tapped out well-known songs and wildly overestimated how often listeners would identify them. Pinker calls this "the chief contributor to opaque writing."

**The practical implication:** Unclear writing is usually not laziness or bad style. The writer cannot simulate a reader who lacks their context. This means self-review does not work well, because rereading your own text re-activates the knowledge the reader does not have. You need mechanical checks and explicit reader-modelling, not "read it again carefully."

**The direction of the effect:** the more you know, the worse you write for novices. Expertise makes it worse, not better. A senior engineer's draft is more likely to be opaque than a junior's, not less.

**When it breaks:** Text for a genuine peer audience with identical context. A message between two people who built the same system can compress heavily and stay clear. Applying novice-level plainness there wastes both readers' time and can read as condescension.

**The smell:** You cannot name the fact the reader is missing. You only feel it "should be obvious." Watch for "obviously", "of course", "simply", and "just". Those words mark the exact points where you skipped a step you can no longer see.

### 2. The Given-New Contract -- Order Matters More Than Length

Haviland and Clark (Journal of Verbal Learning and Verbal Behavior, 1974), "What's new? Acquiring new information as a process in comprehension", showed how readers process a sentence. They first search memory for an antecedent that matches the Given information. They then attach the New information to it. Follow-up work on expository paragraphs found that a paragraph which supports this strategy is measurably easier to process than one that frustrates it.

**The practical implication:** Start each sentence with something the reader already has, end with what is new. The new thing then becomes the given thing for the next sentence. This produces a chain. A sentence that opens with an unfamiliar term forces the reader to hold it unresolved. That costs working memory and often forces a reread.

**This outranks sentence length.** Two short sentences in the wrong order are harder than one longer sentence in the right order. If you can only fix one thing, fix the order.

**When it breaks:** Deliberate topic shifts, where you *want* the reader to notice a new thread has started. Headings and paragraph breaks do this work. Forcing a given-new bridge across a real topic change produces false continuity.

**The smell:** Sentences that begin with a definition or an unexplained noun phrase. Readers rereading the first clause of your sentences. Paragraphs where every sentence starts with the same subject, which usually means you are restating rather than chaining.

---

## Why the Structural Rules Work

### 3. Working Memory Is the Binding Constraint

Sentence-comprehension research consistently ties difficulty to working-memory load. Passive sentences are syntactically more complex than actives, and they violate English canonical subject-verb-object order. Readers with lower working-memory capacity show disproportionate difficulty with them, and that gap widens with age. Studies that manipulate whole-sentence length find that longer sentences reduce comprehension accuracy.

**The practical implication:** The 20-word and 25-word limits are not aesthetic. They are a proxy for how much unresolved structure a reader holds before the sentence resolves. Active voice helps for the same reason: it puts the actor first and matches the parsing heuristic English readers apply by default.

**Who this protects:** the tired reader, the non-native reader, the reader on a phone, and the reader skimming twenty other threads. Not the hypothetical incompetent one. Your maintainer at 11pm has the working memory of a novice.

**When it breaks:** A long sentence with simple, linear structure (a list of parallel items, one clause) can read easily at 35 words. A 15-word sentence with a center-embedded clause can be brutal. Structure dominates count.

**The smell:** You cannot read the sentence aloud in one breath. Or you must reread to find which noun a pronoun or verb attaches to.

### 4. Consistent Terms Beat Elegant Variation

ASD-STE100's core dictionary principle is one word, one meaning, one part of speech. The dictionary holds about 900 approved words and roughly 1,200 unapproved words with prescribed alternatives. Projects add their own technical nouns and verbs.

**The practical implication:** Repeat the term. When you rename a thing mid-document -- set, group, profile, collection -- the reader must decide whether you mean a new thing. That decision is a cost, and half the time they decide wrong. Synonym variation is a literary virtue and a technical defect.

**When it breaks:** Nothing much. This rule is close to unconditional in technical text. The only real cost is prose that feels repetitive to the author. That is the curse of knowledge again. It feels repetitive because you already know the referent is the same.

**The smell:** Two nouns in the same document that you would have to think about to distinguish. If you hesitate, the reader stops.

### 5. Nominalization Hides the Actor

Turning verbs into nouns ("perform a validation of" instead of "validate", "make a decision" instead of "decide") lengthens the sentence and removes the agent. It combines badly with passive voice, because both delete who did what.

**The practical implication:** Find the buried verb and promote it. This usually shortens the sentence and forces you to name the actor, fixing two problems at once. Nominalization is the most reliable single edit for tightening technical prose.

**When it breaks:** Some nominalizations are the established technical term. "Registration", "allocation", "authentication" are things, not disguised verbs. Do not mangle a real noun to satisfy a rule.

**The smell:** Weak verbs carrying a heavy noun: perform, conduct, achieve, provide, undertake, carry out, make. Also the suffix cluster -tion, -ment, -ance, -ity appearing more than once per sentence.

---

## What the Simplification Research Actually Shows

### 6. Simplified Technical Text Is Read Faster and Understood Better -- With Thin Evidence

A moving-window self-paced reading pilot compared authentic aviation maintenance text against the same content rewritten in ASD-STE100. Readers processed the simplified version faster and scored higher on comprehension. The sample was 11 aviation maintenance students.

A larger self-paced reading study gave 48 second-language learners nine texts at authentic, intermediate and beginning levels. Simpler texts were processed faster and were more comprehensible. Separate work on beginning readers found significantly better fluency and comprehension on simplified text. A 2024 randomized trial on health information found plain-language revision dropped reading grade level by nearly three grades while retaining all key content.

**The practical implication:** The direction of the effect is consistent across populations and methods. Simplification does not trade comprehension for accessibility. In these studies it improved both.

**When it breaks:** The STE-specific evidence is genuinely thin. The pilot study says so itself. Do not claim STE is proven optimal, or cite it as though it were a large trial. The defensible claim is "simpler text was read faster and understood better in every study we have, though the STE-specific samples are small."

**The smell:** You are citing a number you did not check, or describing an 11-person pilot as "research shows."

### 7. Plain Language Is Not Only for Novices

Nielsen Norman Group usability testing with domain experts in science, technology and medicine found that highly educated readers also prefer succinct, scannable text. Their expert participants complained about density in their own fields.

**The practical implication:** "My audience is expert" is not a licence for dense prose. Experts are usually reading under more time pressure, not less, and are more likely to skim.

**When it breaks:** This is qualitative research with no comprehension metrics. It supports the direction, not any specific rewrite. Do not cite it as though it quantified anything.

**The smell:** Justifying density by audience seniority. That is nearly always the curse of knowledge wearing a suit.

### 8. Word Counts Are a Smell Detector, Not a Quality Measure

Readability formulas rely on weak proxies: characters or syllables per word for decoding difficulty, words per sentence for syntactic complexity. They ignore cohesion, semantics, and information structure entirely. They predict only about 23-34% of variance in measured reading ease. The canonical counterexample: "Mike eats your cat gun now!" scores as highly readable and means nothing.

**The practical implication:** `check-plain.sh` finds *candidates*. A flagged sentence is a place to look, not a defect. Passing the checker proves nothing about whether the text communicates. Never optimise for the metric.

**Specific failure:** short but unfamiliar words defeat these measures completely. Medical and technical jargon is often monosyllabic and opaque. A text can be simultaneously formula-perfect and unreadable.

**When it breaks:** Always, if treated as a score. The checker is useful precisely because it is dumb and consistent, in the same way a linter is.

**The smell:** Splitting a sentence purely to get under 25 words, producing two fragments that no longer chain. You optimised the proxy and damaged the given-new flow, which matters more.

---

## The Meta-Rule

Every rule here serves comprehension. When a rule and comprehension conflict, comprehension wins, and you say in the output that you broke the rule and why.

The one thing that is never acceptable: deleting a qualification to shorten a sentence. If a claim is uncertain, "this needs checking" is plain English and honest. Removing the uncertainty is not simplification, it is a change of meaning, and it is the most common way plain-language rewrites go wrong.
