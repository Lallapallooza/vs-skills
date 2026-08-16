#!/usr/bin/env bash
# check-plain.sh - mechanical plain-English checks (ASD-STE100 structural rules)
#
# Usage: bash check-plain.sh [--strict] <file> [file...]
#   --strict  apply the 20-word instruction limit to every sentence
#
# This finds CANDIDATES, not defects. Readability proxies predict only ~23-34%
# of variance in real reading ease, so a flag is a place to look. Triage every
# one: fix it, or record it as a false positive. Never optimise for a clean run.
#
# Exits 0 if clean, 1 if flags found, 2 on usage error.

set -uo pipefail

STRICT=0
if [ "${1:-}" = "--strict" ]; then
    STRICT=1
    shift
fi

if [ $# -eq 0 ]; then
    echo "usage: check-plain.sh [--strict] <file> [file...]" >&2
    exit 2
fi

STRICT=$STRICT python3 - "$@" <<'PYEOF'
import os
import re
import sys

STRICT = os.environ.get("STRICT") == "1"

# ASD-STE100: 20 words for instructions, 25 for descriptive text.
DESCRIPTIVE_LIMIT = 25
INSTRUCTION_LIMIT = 20
MAX_SENTENCES_PER_PARA = 6

HEDGES = [
    "as far as i can tell", "it seems that", "it appears that", "i think maybe",
    "sort of", "kind of", "somewhat", "arguably", "it's worth noting",
    "it is worth noting", "it bears mentioning", "needless to say",
    "just wanted to", "if that makes sense", "i would just like to",
    "i'd just like to", "happy to do it", "in my humble opinion",
    "basically", "essentially", "simply put", "to be honest",
    "as mentioned above", "as we have seen",
]

FORMAL = {
    "utilize": "use", "utilise": "use", "commence": "start",
    "terminate": "end", "endeavour": "try", "endeavor": "try",
    "regarding": "about", "concerning": "about", "therefore": "so",
    "additionally": "also", "furthermore": "also", "prior to": "before",
    "subsequent to": "after", "in order to": "to", "a number of": "some",
    "at this point in time": "now", "leverage": "use", "delve into": "look at",
}

# Phrasal verbs that have a single-word equivalent. Established technical
# phrasal verbs (roll back, check out, log in, fall through) are excluded.
PHRASAL = {
    "put off": "delay", "carry out": "do", "find out": "learn",
    "come up with": "propose", "go over": "review", "take care of": "handle",
    "run into": "hit", "look into": "investigate", "cut down on": "reduce",
    "make use of": "use", "get rid of": "remove",
}

# Weak carrier verb + nominalization. The buried verb should be promoted.
NOMINAL = re.compile(
    r"\b(perform|conduct|achieve|provide|undertake|carry out|make|give)\s+"
    r"(?:a|an|the)?\s*\w*(?:tion|ment|ance|ence|ity|sis)\b", re.I
)

MARKETING = [
    "seamless", "seamlessly", "powerful", "robust", "cutting-edge",
    "best-in-class", "world-class", "elegant", "rich set of", "comprehensive",
]

PASSIVE = re.compile(
    r"\b(?:is|are|was|were|be|been|being)\s+(?:\w+ly\s+)?(\w+(?:ed|en))\b", re.I
)

IMPERATIVE = re.compile(
    r"^\s*(?:Do|Don't|Use|Run|Add|Set|Make|Check|Write|Read|Open|Close|Start|"
    r"Stop|Delete|Remove|Install|Configure|Enable|Disable|Send|Apply)\b"
)

def strip_noise(text):
    """Blank YAML frontmatter, fenced code, inline code, URLs. Keep line numbers."""
    lines = text.split("\n")
    out, in_fence, start = [], False, 0

    if lines and lines[0].strip() == "---":
        for i in range(1, len(lines)):
            if lines[i].strip() == "---":
                out = [""] * (i + 1)
                start = i + 1
                break

    for line in lines[start:]:
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            out.append("")
            continue
        if in_fence:
            out.append("")
            continue
        line = re.sub(r"`[^`]*`", "", line)
        line = re.sub(r"https?://\S+", "", line)
        out.append(line)
    return out

def sentences(par):
    return [p for p in re.split(r"(?<=[.!?])\s+", par.strip()) if p.strip()]

def wordcount(s):
    return len(re.findall(r"[A-Za-z0-9'\-]+", s))

total = 0
for path in sys.argv[1:]:
    try:
        raw = open(path, encoding="utf-8").read()
    except OSError as e:
        print(f"{path}: cannot read: {e}", file=sys.stderr)
        total += 1
        continue

    lines = strip_noise(raw)
    flags = []

    for n, line in enumerate(lines, 1):
        stripped = line.strip()
        # Skip blanks, quotes, headings, and table rows.
        if not stripped or stripped.startswith((">", "#")) or stripped.startswith("|"):
            continue

        low = line.lower()
        for h in HEDGES:
            if h in low:
                flags.append((n, "hedge", f'"{h}" - delete it'))
        for word, better in FORMAL.items():
            if re.search(rf"\b{re.escape(word)}\b", low):
                flags.append((n, "formal", f'"{word}" -> "{better}"'))
        for word, better in PHRASAL.items():
            if re.search(rf"\b{re.escape(word)}\b", low):
                flags.append((n, "phrasal", f'"{word}" -> "{better}"'))
        for m in NOMINAL.finditer(line):
            flags.append((n, "nominal", f'"{m.group(0).strip()}" - promote the verb'))
        for word in MARKETING:
            if re.search(rf"\b{re.escape(word)}\b", low):
                flags.append((n, "marketing", f'"{word}" - carries no information'))
        for m in PASSIVE.finditer(line):
            flags.append((n, "passive", f'"{m.group(0).strip()}" - name the actor'))
        if ";" in re.sub(r"&\w+;", "", line):
            flags.append((n, "semicolon", "split into two sentences"))

        body = re.sub(r"^\s*(?:[-*+]|\d+\.)\s+", "", line)
        for s in sentences(body):
            wc = wordcount(s)
            is_instruction = STRICT or bool(IMPERATIVE.match(s))
            limit = INSTRUCTION_LIMIT if is_instruction else DESCRIPTIVE_LIMIT
            if wc > limit:
                kind = "instruction" if is_instruction else "sentence"
                flags.append((n, "long", f"{wc} words in a {kind} (limit {limit})"))

    # Paragraph density, prose paragraphs only.
    para, start = [], 0
    def flush(para, start):
        if not para:
            return
        if re.match(r"^\s*(?:[-*+]|\d+\.|#|>|\|)", para[0]):
            return
        n = len(sentences(" ".join(para)))
        if n > MAX_SENTENCES_PER_PARA:
            flags.append((start, "dense", f"{n} sentences (limit {MAX_SENTENCES_PER_PARA})"))
    for i, line in enumerate(lines, 1):
        if line.strip():
            if not para:
                start = i
            para.append(line)
        else:
            flush(para, start)
            para = []
    flush(para, start)

    if flags:
        total += len(flags)
        by_kind = {}
        for _, kind, _ in flags:
            by_kind[kind] = by_kind.get(kind, 0) + 1
        summary = ", ".join(f"{v} {k}" for k, v in sorted(by_kind.items()))
        print(f"\n{path}: {len(flags)} flag(s) -- {summary}")
        for n, kind, msg in sorted(flags):
            print(f"  {n}: [{kind}] {msg}")
    else:
        print(f"{path}: clean")

if total:
    print(f"\n{total} flag(s). These are candidates, not defects.")
    print("Triage each: fix it, or record it as a false positive with the reason.")
    sys.exit(1)
sys.exit(0)
PYEOF
