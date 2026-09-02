#!/usr/bin/env python3
"""Insert a new initial decryption key into a local reliquary checkout.

Game traffic is XOR'd against a repeating 4096-byte pad. Before login the pad is a
per-build constant shipped in the game client; reliquary keeps a table of them in
src/network/crypto.rs keyed by a u32 "game version".

That u32 is not a real version number -- it is the first four bytes of the pad
itself, big-endian. reliquary recovers it from ciphertext because every command's
plaintext starts with the magic 0x9D74C714:

    ciphertext[0:4] ^ 0x9D74C714  ==  pad[0:4] ^ 0x9D74C714 ^ 0x9D74C714  ==  pad[0:4]

So the lookup index is derivable from the key, and this script does that rather
than making you supply it. (Verified against all 29 keys in reliquary v22.0.0.)

Usage:
    apply-key.py <reliquary-checkout> --key <base64>        # version derived
    apply-key.py <reliquary-checkout> --key-file <path>
    apply-key.py <reliquary-checkout> --key <b64> --expect-version <u32>
"""
import argparse
import base64
import pathlib
import re
import sys

MAGIC = 0x9D74C714
PAD_LEN = 4096
CHUNK = 110


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("reliquary", type=pathlib.Path)
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--key", help="base64-encoded initial pad")
    src.add_argument("--key-file", type=pathlib.Path, help="file holding the pad (base64 or raw)")
    ap.add_argument("--expect-version", type=int, default=None,
                    help="fail unless the derived version matches this")
    args = ap.parse_args()

    if args.key:
        raw = base64.b64decode(args.key, validate=True)
    else:
        blob = args.key_file.read_bytes()
        try:
            raw = base64.b64decode(b"".join(blob.split()), validate=True)
        except Exception:
            raw = blob

    if len(raw) != PAD_LEN:
        print(f"ERROR: pad is {len(raw)} bytes, expected {PAD_LEN}", file=sys.stderr)
        return 1

    version = int.from_bytes(raw[:4], "big")
    print(f"derived version: {version}  (pad[0:4] big-endian)")
    if args.expect_version is not None and args.expect_version != version:
        print(f"ERROR: expected version {args.expect_version}, key yields {version}", file=sys.stderr)
        return 1

    crypto = args.reliquary / "src/network/crypto.rs"
    if not crypto.is_file():
        print(f"ERROR: {crypto} not found", file=sys.stderr)
        return 1
    text = crypto.read_text()

    sentinel = "_ => return None"
    if sentinel not in text:
        print(f"ERROR: could not find the '{sentinel}' arm in crypto.rs; "
              f"upstream may have restructured lookup_initial_key", file=sys.stderr)
        return 1

    # Drop any existing arm for this version so re-runs are idempotent.
    text, n = re.subn(rf'^\s*{version}\s*=>\s*(?:"[^"]*"|concat!\(.*?\))\s*,\s*\n',
                      "", text, flags=re.S | re.M)
    if n:
        print(f"replaced {n} existing arm(s) for version {version}")

    b64 = base64.b64encode(raw).decode()
    lines = [b64[i:i + CHUNK] for i in range(0, len(b64), CHUNK)]
    body = ",\n".join(f'                    "{ln}"' for ln in lines)
    arm = f"                {version} => concat!(\n{body}\n                ),\n"

    idx = text.index(sentinel)
    line_start = text.rindex("\n", 0, idx) + 1
    text = text[:line_start] + arm + text[line_start:]
    crypto.write_text(text)

    print(f"inserted key for version {version} into {crypto}")
    print(f"  pad: {len(raw)} bytes, {len(lines)} source lines")
    return 0


if __name__ == "__main__":
    sys.exit(main())
