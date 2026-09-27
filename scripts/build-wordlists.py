#!/usr/bin/env python3
"""
Builds Zephydian's word lists from SCOWL (Spell Checker Oriented Word Lists).

    1. Download SCOWL 2020.12.07 from http://wordlist.aspell.net/ and extract it.
    2. python3 scripts/build-wordlists.py path/to/scowl-2020.12.07

Writes to app/Zephydian/Resources/Words/:
    five-answers.txt   common 5-letter words used as Five answers (shuffled, fixed seed)
    five-valid.txt     every 5-letter word accepted as a Five guess
    wheel-words.txt    common 3–6 letter words used to build Spokes puzzles
    wheel-valid.txt    every 3–6 letter word accepted (extra finds count as bonus words)
    SCOWL-LICENSE.txt  SCOWL's copyright notice (its license requires shipping it)

SCOWL "size" levels roughly track how common a word is: 10–35 are everyday words,
up to 80 adds rarer but real words. Proper names, abbreviations and contractions
live in separate SCOWL files and are never read.
"""
import random
import re
import shutil
import sys
from pathlib import Path

COMMON_SIZES = [10, 20, 35]
VALID_SIZES = [10, 20, 35, 40, 50, 55, 60, 70, 80]
SOURCES = ["english-words", "american-words"]

# Never shown as an answer or puzzle word (still accepted if a player types it).
# Inflections (-s, -es, -ed, -ing, -er, -y) are blocked automatically.
BLOCKLIST = """
anal anus arse bastard bitch bitchy boner boob booby bugger butt chink cock coon crap crotch cum
cunt dago damn dick dildo dyke erotic fag fagot faggot fart feces fuck gimp gook homo hooker horny
jap jizz kike kinky lesbo nazi negro nigga nigger nipple orgy penis pimp piss porn porno prick
pube pubic pussy queer rape rapist retard scrotum semen sex sexy shit slut smut spaz spic sperm
tit titty tranny turd twat vagina wank whore wop
""".split()


# Informal or not-quite-words that SCOWL lists as common; fine as guesses, odd as answers.
NOT_ANSWERS = set("""
lemme gonna gotta wanna kinda sorta dunno gimme outta multi ain't yeah yep nope okay whoa
""".split())


def blocked(word: str) -> bool:
    for base in BLOCKLIST:
        if word == base or any(word == base + suffix for suffix in ("s", "es", "ed", "ing", "er", "ers", "y", "ies")):
            return True
    return False


def load(final_dir: Path, sizes: list[int]) -> set[str]:
    words: set[str] = set()
    for source in SOURCES:
        for size in sizes:
            path = final_dir / f"{source}.{size}"
            if not path.exists():
                continue
            for line in path.read_text(encoding="latin-1").splitlines():
                word = line.strip()
                if re.fullmatch(r"[a-z]+", word):  # lowercase ASCII only: no names, accents or apostrophes
                    words.add(word)
    return words


def is_inflection(word: str) -> bool:
    """Plurals and past tenses make poor Five answers (as in the original game)."""
    return (word.endswith("s") and not word.endswith(("ss", "us", "is"))) or word.endswith("ed")


def write(path: Path, words) -> None:
    path.write_text("\n".join(words) + "\n", encoding="utf-8")
    print(f"{path.name:18} {len(words):6} words")


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    scowl = Path(sys.argv[1])
    final_dir = scowl / "final"
    out = Path(__file__).resolve().parent.parent / "app/Zephydian/Resources/Words"
    out.mkdir(parents=True, exist_ok=True)

    common = {w for w in load(final_dir, COMMON_SIZES) if not blocked(w)}
    valid = load(final_dir, VALID_SIZES) | common

    answers = sorted(w for w in common if len(w) == 5 and not is_inflection(w) and w not in NOT_ANSWERS)
    random.Random(2026).shuffle(answers)  # fixed seed: the daily order is stable between builds
    write(out / "five-answers.txt", answers)
    write(out / "five-valid.txt", sorted(w for w in valid if len(w) == 5))
    write(out / "wheel-words.txt", sorted(w for w in common if 3 <= len(w) <= 6 and w not in NOT_ANSWERS))
    write(out / "wheel-valid.txt", sorted(w for w in valid if 3 <= len(w) <= 6))
    shutil.copy(scowl / "Copyright", out / "SCOWL-LICENSE.txt")
    print(f"SCOWL-LICENSE.txt  copied")


if __name__ == "__main__":
    main()
