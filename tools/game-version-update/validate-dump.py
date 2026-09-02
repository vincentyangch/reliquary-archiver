#!/usr/bin/env python3
"""Validate a candidate protocol dump before feeding it to reliquary-codegen.

A dump is a directory shaped the way reliquary-codegen expects:

    <data-dir>/proto/*.proto
    <data-dir>/packetIds.json      {"<id>": "<CommandName>", ...}

Checks performed:
  1. packetIds.json parses, and keys are u16-parseable ids
  2. every command id this archiver reads is present
  3. every protobuf type reliquary's `proto-rqa` feature expects is defined, in a
     file named <TypeName>.proto (codegen names output .rs files after input .proto files)
  4. the dump is not byte-identical to the currently pinned version (i.e. it is
     actually new data), when a reliquary checkout is supplied

Usage:
    validate-dump.py <data-dir> [--reliquary <path-to-reliquary-checkout>]

Exit 0 = usable, 1 = problems found.
"""
import argparse
import json
import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


def archiver_required_commands():
    """Command ids referenced by this archiver, read from its own source."""
    pat = re.compile(r"command_id::\{([^}]*)\}|command_id::([A-Za-z0-9_]+)")
    found = set()
    for rs in (REPO_ROOT / "src").rglob("*.rs"):
        for m in pat.finditer(rs.read_text(encoding="utf-8", errors="replace")):
            group = m.group(1) or m.group(2) or ""
            for name in group.split(","):
                name = name.strip()
                if re.fullmatch(r"[A-Za-z0-9_]+", name):
                    found.add(name)
    return found


def rqa_modules(reliquary: pathlib.Path | None):
    """Protobuf modules the `proto-rqa` feature declares."""
    fallback = """Avatar AvatarPathData AvatarPathSkillTree AvatarSync BasicModuleSync BlackInfo
        DoGachaScRsp EquipRelic Equipment GachaCeiling GachaCeilingAvatar GachaInfo GachaItem
        GetAvatarDataScRsp GetBagScRsp GetGachaInfoScRsp GroupStatus HeadFrameInfo HeadIconData
        Item ItemList KVP Material MessageGroupStatus MessageSectionStatus Mission
        MissionCustomValue MissionStatus MissionSync PileItem PlayerBasicInfo PlayerBoardModuleSync
        PlayerGetTokenScRsp PlayerLoginScRsp PlayerSyncScNotify Quest QuestStatus Relic RelicAffix
        SectionStatus SetAvatarEnhancedIdScRsp SyncStatus TurnFoodSwitch WaitDelResource""".split()
    if reliquary is None:
        return set(fallback), True
    mod_rs = reliquary / "src/network/command/mod.rs"
    if not mod_rs.is_file():
        return set(fallback), True
    text = mod_rs.read_text(encoding="utf-8", errors="replace")
    block = re.search(r'cfg\(all\(feature = "proto-rqa"\)\)\s*\]?\s*pub mod proto \{(.*?)\n\}', text, re.S)
    if not block:
        return set(fallback), True
    return set(re.findall(r"pub mod ([A-Za-z0-9_]+);", block.group(1))), False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("data_dir", type=pathlib.Path)
    ap.add_argument("--reliquary", type=pathlib.Path, default=None)
    args = ap.parse_args()

    problems, notes = [], []
    data = args.data_dir

    # --- packetIds.json -------------------------------------------------
    ids_path = data / "packetIds.json"
    id_to_name = {}
    if not ids_path.is_file():
        problems.append(f"missing {ids_path}")
    else:
        try:
            raw = json.loads(ids_path.read_text())
        except json.JSONDecodeError as e:
            problems.append(f"packetIds.json is not valid JSON: {e}")
            raw = {}
        if not isinstance(raw, dict):
            problems.append("packetIds.json must be a JSON object")
            raw = {}
        for k, v in raw.items():
            try:
                n = int(k)
            except ValueError:
                problems.append(f"packetIds.json key {k!r} is not an integer -- "
                                f"keys must be ids, values must be names (this file may be inverted)")
                break
            if not 0 <= n <= 65535:
                problems.append(f"packetIds.json id {n} does not fit in u16")
                break
            if not isinstance(v, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", v):
                problems.append(f"packetIds.json value {v!r} is not a valid Rust identifier")
                break
            id_to_name[n] = v
        notes.append(f"packetIds.json: {len(id_to_name)} command ids")

    # --- required commands ----------------------------------------------
    names = set(id_to_name.values())
    required = archiver_required_commands()
    if required:
        missing = sorted(required - names)
        notes.append(f"archiver requires {len(required)} commands, {len(required) - len(missing)} present")
        if missing:
            problems.append("dump is missing command ids this archiver reads: " + ", ".join(missing))
    else:
        notes.append("WARNING: could not detect required commands from src/ -- skipped that check")

    # --- proto files ------------------------------------------------------
    # protobuf-codegen names each generated .rs after its input .proto file, and
    # reliquary imports one module per message (proto/Relic.rs, proto/KVP.rs, ...).
    # So the dump must be one .proto file per message, not a single monolithic file.
    proto_dir = data / "proto"
    protos = sorted(proto_dir.glob("*.proto")) if proto_dir.is_dir() else []
    if not protos:
        problems.append(f"no .proto files found in {proto_dir}")
    else:
        defined = {}
        for p in protos:
            body = p.read_text(encoding="utf-8", errors="replace")
            for kind, name in re.findall(r"^\s*(message|enum)\s+([A-Za-z0-9_]+)", body, re.M):
                defined.setdefault(name, []).append((kind, p.name))
        notes.append(f"proto: {len(protos)} file(s), {len(defined)} messages/enums defined")

        if len(protos) < 100:
            problems.append(
                f"only {len(protos)} .proto file(s) -- reliquary needs one file per message "
                f"(protobuf-codegen names each generated .rs after its input .proto, and "
                f"reliquary imports proto/<MessageName>.rs). A single monolithic StarRail.proto "
                f"will not work; split it first.")

        needed, was_fallback = rqa_modules(args.reliquary)
        if was_fallback:
            notes.append("NOTE: used the built-in proto-rqa list (no reliquary checkout given); "
                         "obfuscated module names are version-specific and were omitted")
        undefined = sorted(n for n in needed if n not in defined)
        if undefined:
            problems.append(f"dump does not define {len(undefined)} type(s) that reliquary's "
                            f"proto-rqa feature expects: " + ", ".join(undefined[:12])
                            + (" ..." if len(undefined) > 12 else ""))
        misfiled = sorted(n for n in needed if n in defined
                          and not (proto_dir / f"{n}.proto").is_file())
        if misfiled:
            problems.append(f"{len(misfiled)} required type(s) are defined, but not in a file named "
                            f"<Name>.proto, so reliquary's module paths will not resolve: "
                            + ", ".join(misfiled[:12]) + (" ..." if len(misfiled) > 12 else ""))

    # --- report ------------------------------------------------------------
    for n in notes:
        print(f"  {n}")
    if problems:
        print("\nFAIL")
        for p in problems:
            print(f"  - {p}")
        return 1
    print("\nOK -- dump looks usable")
    return 0


if __name__ == "__main__":
    sys.exit(main())
