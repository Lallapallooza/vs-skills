# Writing Rules

The operational rule set. ASD-STE100 has 53 writing rules in 9 sections plus a controlled dictionary. This file carries the rules that transfer outside aerospace maintenance manuals, and keeps the STE numerics where they exist.

The mechanism behind each rule is in `evidence-base.md`. When a rule fights comprehension, comprehension wins.

**On the dictionary:** ASD-STE100's dictionary holds about 900 approved words, each with one meaning and one part of speech. It adds about 1,200 unapproved words with prescribed alternatives, plus project-specific technical nouns and verbs. The dictionary is copyrighted and cannot be redistributed. This skill therefore applies the principle, which is plainest available word and one word one meaning, rather than checking against the official list.

---

## 1. Sentence Length

| Text type | Limit |
|---|---|
| Instruction, request, procedure step | 20 words |
| Descriptive or explanatory sentence | 25 words |

One idea per sentence. If a sentence needs "and" or "but" to join two claims, it is two sentences.

One instruction per sentence. Never combine two actions the reader must perform.

Structure beats the count: see `evidence-base.md` §3. A linear 30-word sentence can be fine. A center-embedded 15-word sentence can be brutal. Use the limit to find candidates, not to score.

## 2. Paragraphs

- One topic per paragraph.
- Maximum 6 sentences.
- Put the topic first. Readers skim first sentences.
- Use a vertical list when there are more than two parallel items. Readers skim embedded series. They read lists.

## 3. Verbs

**Allowed forms:** infinitive, imperative, simple present, simple past, simple future, past participle used as an adjective.

**Avoid** perfect and continuous constructions where a simple tense carries the meaning. "The build has been failing" becomes "The build fails."

**Active voice.** Passive is permitted only when the actor is genuinely unknown or irrelevant. Passives violate canonical English word order and cost working memory (§3).

**`-ing` forms** only as a technical noun ("the mapping") or a modifier ("the running process"). Never to bolt a second clause onto a sentence. "X, highlighting Y" is the trope. "X. This shows Y." is the fix.

**Promote buried verbs.** Nominalization hides the actor and pads the sentence:

| Nominalized | Direct |
|---|---|
| perform a validation of | validate |
| make a decision about | decide |
| provide an explanation for | explain |
| carry out an investigation | investigate |
| give consideration to | consider |
| there is a requirement that | must |

Watch the weak carrier verbs: perform, conduct, achieve, provide, undertake, carry out, make. Watch the suffixes: -tion, -ment, -ance, -ity. More than one per sentence usually means a verb is buried. Exception: established technical nouns (registration, allocation, authentication) are real nouns, not disguised verbs.

## 4. Words

**One word, one meaning.** Choose a term and repeat it. Never vary for elegance. If you call it a "set" once, it is a "set" every time -- not a group, collection, or bundle.

**Plainest available word:**

| Formal | Plain |
|---|---|
| utilize | use |
| commence | start |
| terminate | end |
| endeavour | try |
| regarding, concerning | about |
| therefore, thus | so |
| additionally, furthermore | also |
| prior to | before |
| subsequent to | after |
| in order to | to |
| a number of | some |
| at this point in time | now |
| leverage | use |
| delve into | look at |

**No phrasal verbs where a single verb exists.** Phrasal verbs are a known problem for non-native readers and for machine translation. Their meaning is not compositional.

| Phrasal | Single verb |
|---|---|
| set up | install, configure |
| put off | delay |
| carry out | do, perform |
| find out | learn, determine |
| come up with | propose, design |
| go over | review |
| take care of | handle |
| run into | meet, hit |

Keep a phrasal verb when it is the established technical term: "roll back", "check out", "log in", "fall through".

**Noun clusters: 3 words maximum.** Longer clusters force the reader to guess which noun modifies which one. "Lint level scoping mechanism" becomes "the mechanism that scopes lint levels."

**No marketing adjectives** in technical text: seamless, powerful, robust, cutting-edge, rich, comprehensive, elegant. They carry no information and cost credibility.

## 5. Do Not Omit Words

Keep articles, subjects, and verbs. Telegraphic style saves two words and costs a parse.

- Bad: "Config loaded before registration, names available."
- Good: "The driver loads the config before registration, so the names are available."

Keep the relative pronoun where it disambiguates: "the lint that the config defines" reads faster than "the lint the config defines."

## 6. Punctuation

- **No semicolons.** A semicolon joins two independent clauses. That is exactly what you should split into two sentences.
- **No parenthetical asides carrying load-bearing meaning.** If it matters, it is a sentence. If it does not, delete it.
- **Em dashes sparingly.** More than two or three in a piece reads as AI-generated (see `vs-core-tropes`).
- **Serial comma** always, since ambiguity costs more than the character.

## 7. Cuts That Shorten and Strengthen Together

Hedges and padding make text longer *and* weaker, so deletion wins twice. This is the highest-yield edit available.

- **Hedges:** as far as I can tell, it seems that, it appears that, sort of, kind of, somewhat, arguably. Also "probably", when you do not mean a real probability.
- **Politeness padding:** happy to do it, I'd just like to, if that makes sense, just wanted to check, I was wondering if.
- **Throat clearing:** it's worth noting that, importantly, basically, essentially, actually, simply put, to be honest, needless to say.
- **Meta-commentary:** as mentioned above, in this section we will, as we have seen.

Delete first, then reread. If the sentence still says what you mean, the hedge was decoration.

**The exception that matters:** never delete a hedge that carries real uncertainty. "This needs checking" and "I have not tested this" are plain and honest. Removing real uncertainty changes the meaning. It is not a simplification. See `evidence-base.md`, The Meta-Rule.

## 8. Safety and Warnings

Where the text carries a hazard or a destructive action, put the command or the condition first, before the explanation. "Stop the service before you delete the volume" beats "Before deleting the volume, which will destroy the data it contains, stop the service."

## 9. Ordering

Start each sentence with something the reader already has. End with what is new. The new thing becomes the given thing for the next sentence. This chains.

When a sentence must open with an unfamiliar term, define it in that sentence or move it later. See `evidence-base.md` §2 -- ordering outranks length. If you can only fix one thing, fix the order.
