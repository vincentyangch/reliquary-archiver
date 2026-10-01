#!/usr/bin/env python3
"""Sanity-check an archiver export after a game-version bump.

    validate-export.py <archive_output.json>

Decryption succeeding does not mean the export is correct. If protobuf field
numbers are stale the packets still decrypt and still parse -- they just parse
into the wrong fields, producing a structurally valid file full of nonsense.
This looks for that.

The distinction that matters here is between *structure* and *content*:

  - Structure is fixed by the game's design. There are exactly six relic slots;
    relic levels stop at 15; every item has a name. A misparse breaks these
    across most records at once, so violations are failures.

  - Content grows every patch. New paths get added (Remembrance, then Elation),
    new characters, new sets. An unknown value here means the checker is older
    than the game, not that the export is wrong, so these are reported and not
    failed on.

Getting that backwards makes the check fail on every new patch -- exactly when
you need it -- so unknown paths are informational and only their *prevalence*
is treated as a symptom.

Exit 0 = export looks sane, 1 = problems found.
"""
import argparse
import collections
import json
import pathlib
import sys

# Structural: fixed by the game's design, not by content updates.
SLOTS = {"Head", "Hands", "Body", "Feet", "Planar Sphere", "Link Rope"}
MAX_RELIC_LEVEL = 15
MAX_CHARACTER_LEVEL = 80
MAX_EIDOLON = 6
MAX_SUPERIMPOSITION = 5

# Content: known at the time of writing, expected to grow.
KNOWN_PATHS = {
    "Destruction", "Hunt", "Erudition", "Harmony", "Nihility",
    "Preservation", "Abundance", "Remembrance", "Elation",
}

# If more than this fraction of records look wrong, it is a misparse rather than
# new content -- a stale field number corrupts nearly everything, not a few.
MISPARSE_FRACTION = 0.05


class Report:
    def __init__(self):
        self.failures = []
        self.notes = []

    def fail(self, msg):
        self.failures.append(msg)

    def note(self, msg):
        self.notes.append(msg)

    def check_fraction(self, bad, total, what):
        """Fail only when a problem is widespread enough to mean a misparse."""
        if not total or not bad:
            return
        frac = len(bad) / total
        sample = ", ".join(str(b) for b in bad[:3])
        msg = f"{len(bad)}/{total} {what} ({frac:.1%}) -- e.g. {sample}"
        if frac > MISPARSE_FRACTION:
            self.fail(msg)
        else:
            self.note(msg)


def check_relics(relics, r: Report):
    if not relics:
        r.fail("no relics in export")
        return
    n = len(relics)
    slots = collections.Counter(x.get("slot") for x in relics)
    print(f"  relics: {n}")
    print("    slots: " + ", ".join(f"{k} {v}" for k, v in sorted(slots.items(), key=lambda kv: -kv[1])))

    bad_slot = [x.get("slot") for x in relics if x.get("slot") not in SLOTS]
    if bad_slot:
        # Slots are structural: six, always. Any unknown value is a misparse.
        # repr() so that control characters and stray whitespace stay visible --
        # a misparsed string field often looks correct until you can see it.
        shown = ", ".join(repr(s) for s in sorted(set(bad_slot), key=str)[:5])
        r.fail(f"{len(bad_slot)} relic(s) with a slot outside the six known: {shown}")
    missing = [i for i, x in enumerate(relics) if not x.get("name")]
    r.check_fraction(missing, n, "relics unnamed")

    levels = [x.get("level", 0) for x in relics]
    out = [lv for lv in levels if not 0 <= lv <= MAX_RELIC_LEVEL]
    if out:
        r.fail(f"{len(out)} relic(s) with level outside 0-{MAX_RELIC_LEVEL}: {sorted(set(out))[:5]}")
    print(f"    level range: {min(levels)}-{max(levels)}")

    rarities = collections.Counter(x.get("rarity") for x in relics)
    print("    rarities: " + ", ".join(f"{k}* {v}" for k, v in sorted(rarities.items())))
    bad_rarity = [k for k in rarities if not isinstance(k, int) or not 2 <= k <= 5]
    if bad_rarity:
        r.fail(f"relic rarities outside 2-5: {bad_rarity}")

    nosub = [i for i, x in enumerate(relics) if not x.get("substats")]
    r.check_fraction(nosub, n, "relics with no substats")


def check_characters(chars, r: Report):
    if not chars:
        r.fail("no characters in export")
        return
    n = len(chars)
    print(f"  characters: {n}")

    missing = [i for i, x in enumerate(chars) if not x.get("name")]
    r.check_fraction(missing, n, "characters unnamed")

    levels = [x.get("level", 0) for x in chars]
    out = [lv for lv in levels if not 1 <= lv <= MAX_CHARACTER_LEVEL]
    if out:
        r.fail(f"{len(out)} character(s) with level outside 1-{MAX_CHARACTER_LEVEL}: {sorted(set(out))[:5]}")
    print(f"    level range: {min(levels)}-{max(levels)}")

    eidolons = [x.get("eidolon", 0) for x in chars]
    out = [e for e in eidolons if not 0 <= e <= MAX_EIDOLON]
    if out:
        r.fail(f"{len(out)} character(s) with eidolon outside 0-{MAX_EIDOLON}: {sorted(set(out))[:5]}")

    # New paths ship with new patches. Report them; only treat them as a symptom
    # if they dominate, which is what a misparsed field looks like.
    paths = collections.Counter(x.get("path") for x in chars)
    unknown = [p for p in paths if p not in KNOWN_PATHS]
    print("    paths: " + ", ".join(f"{k} {v}" for k, v in sorted(paths.items())))
    if unknown:
        count = sum(paths[p] for p in unknown)
        if count / n > MISPARSE_FRACTION * 4:
            r.fail(f"{count}/{n} characters on unrecognised paths {unknown} -- likely a misparse")
        else:
            r.note(f"unrecognised path(s) {unknown} -- probably new content, worth confirming in game")


def check_light_cones(cones, r: Report):
    if not cones:
        r.fail("no light cones in export")
        return
    n = len(cones)
    print(f"  light_cones: {n}")
    missing = [i for i, x in enumerate(cones) if not x.get("name")]
    r.check_fraction(missing, n, "light cones unnamed")

    si = [x.get("superimposition", 1) for x in cones]
    out = [s for s in si if not 1 <= s <= MAX_SUPERIMPOSITION]
    if out:
        r.fail(f"{len(out)} light cone(s) with superimposition outside 1-{MAX_SUPERIMPOSITION}: {sorted(set(out))[:5]}")
    levels = [x.get("level", 0) for x in cones]
    print(f"    level range: {min(levels)}-{max(levels)}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("export", type=pathlib.Path)
    args = ap.parse_args()

    if not args.export.is_file():
        print(f"ERROR: no such file: {args.export}", file=sys.stderr)
        return 1
    try:
        data = json.loads(args.export.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        print(f"ERROR: {args.export} is not valid JSON: {e}", file=sys.stderr)
        return 1

    r = Report()
    meta = data.get("metadata") or {}
    print(f"export: {args.export}  ({args.export.stat().st_size / 1e6:.1f} MB)")
    print(f"  build: {data.get('build', '?')}   uid: {meta.get('uid', '?')}   "
          f"trailblazer: {meta.get('trailblazer', '?')}")
    if not meta.get("uid"):
        r.fail("no uid in metadata -- login was probably not captured")

    check_relics(data.get("relics") or [], r)
    check_characters(data.get("characters") or [], r)
    check_light_cones(data.get("light_cones") or [], r)
    print(f"  materials: {len(data.get('materials') or [])}")

    print()
    for n in r.notes:
        print(f"NOTE: {n}")
    if r.failures:
        for f in r.failures:
            print(f"FAIL: {f}", file=sys.stderr)
        print(f"\nFAIL: {len(r.failures)} problem(s) -- the export looks misparsed", file=sys.stderr)
        return 1
    print("PASS: export is structurally sound")
    return 0


if __name__ == "__main__":
    sys.exit(main())
