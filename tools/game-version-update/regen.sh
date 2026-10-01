#!/usr/bin/env bash
# One-command rebuild of the reliquary dependency for a new game version.
#
#   ./tools/game-version-update/regen.sh --data <dump-dir> --key <base64-or-file>
#
# <dump-dir> must be shaped the way reliquary-codegen expects:
#     <dump-dir>/proto/<MessageName>.proto     (one file per message -- see README)
#     <dump-dir>/packetIds.json                {"<id>": "<CommandName>", ...}
#
# Steps: fetch reliquary + reliquary-codegen -> validate the dump -> regenerate
# protos and command ids -> insert the initial decryption key -> point Cargo.toml
# at the local checkout -> build.
#
# Use --revert to unpin and go back to the upstream tag.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$REPO_ROOT/.gamedata-work"
TOOLS="$REPO_ROOT/tools/game-version-update"
RELIQUARY_URL="https://github.com/IceDynamix/reliquary"
CODEGEN_URL="https://github.com/IceDynamix/reliquary-codegen"
MARKER="# >>> game-version-update patch"

DATA="" ; KEY="" ; REF="" ; BUILD=1 ; REVERT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --data)          DATA="$2"; shift 2 ;;
    --key)           KEY="$2";  shift 2 ;;
    --reliquary-ref) REF="$2";  shift 2 ;;
    --no-build)      BUILD=0;   shift ;;
    --revert)        REVERT=1;  shift ;;
    -h|--help)       awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

unpin() {
  python3 - "$REPO_ROOT/Cargo.toml" "$MARKER" <<'PY'
import re, sys
p, marker = sys.argv[1], sys.argv[2]
with open(p) as f: t = f.read()
t2 = re.sub(r"\n*" + re.escape(marker) + r".*?# <<< game-version-update patch\n", "", t, flags=re.S)
if t2 != t:
    t2 = t2.rstrip("\n") + "\n"
    with open(p, "w") as f: f.write(t2)
    print("removed [patch] block from Cargo.toml")
else:
    print("no [patch] block present")
PY
}

if [ "$REVERT" = 1 ]; then
  unpin
  echo "reverted -- Cargo.toml now uses the upstream reliquary tag again"
  exit 0
fi

mkdir -p "$WORK"

# --- 1. sources ------------------------------------------------------------
pinned_tag="$(grep -oE 'tag = "v[0-9]+\.[0-9]+\.[0-9]+"' "$REPO_ROOT/Cargo.toml" \
  | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
ref="${REF:-$pinned_tag}"

if [ ! -d "$WORK/reliquary/.git" ]; then
  echo "==> cloning reliquary @ $ref"
  git clone -q --depth 1 --branch "$ref" "$RELIQUARY_URL" "$WORK/reliquary"
else
  echo "==> reliquary checkout present ($(git -C "$WORK/reliquary" describe --tags --always 2>/dev/null || echo unknown))"
  if [ -n "$REF" ]; then
    git -C "$WORK/reliquary" fetch -q --depth 1 origin "$ref"
    git -C "$WORK/reliquary" checkout -q FETCH_HEAD
    echo "    checked out $ref"
  fi
fi

if [ ! -d "$WORK/reliquary-codegen/.git" ]; then
  echo "==> cloning reliquary-codegen"
  git clone -q --depth 1 "$CODEGEN_URL" "$WORK/reliquary-codegen"
fi

# --- 2. validate + regenerate ----------------------------------------------
if [ -n "$DATA" ]; then
  DATA="$(cd "$DATA" && pwd)"
  echo "==> validating dump at $DATA"
  "$TOOLS/validate-dump.py" "$DATA" --reliquary "$WORK/reliquary"

  echo "==> regenerating protos and command ids"
  ( cd "$WORK/reliquary-codegen" && cargo run --quiet --release -- "$WORK/reliquary" "$DATA" )
  echo "    command_id.rs: $(grep -c '^pub const' "$WORK/reliquary/src/network/command/command_id.rs" || echo '?') constants"
  echo "    proto modules: $(ls "$WORK/reliquary/src/network/command/proto/"*.rs 2>/dev/null | wc -l | tr -d ' ')"
else
  echo "==> no --data given, skipping protobuf/command-id regeneration"
fi

# --- 3. decryption key ------------------------------------------------------
if [ -n "$KEY" ]; then
  echo "==> applying initial decryption key"
  if [ -f "$KEY" ]; then
    "$TOOLS/apply-key.py" "$WORK/reliquary" --key-file "$KEY"
  else
    "$TOOLS/apply-key.py" "$WORK/reliquary" --key "$KEY"
  fi
else
  echo "==> no --key given, keeping the existing key table"
fi

# --- 4. point Cargo.toml at the local checkout -----------------------------
if ! grep -q "$MARKER" "$REPO_ROOT/Cargo.toml"; then
  echo "==> pinning Cargo.toml to the local reliquary checkout"
  cat >> "$REPO_ROOT/Cargo.toml" <<PATCH

$MARKER
# Overrides the reliquary git dependency (both [dependencies] and
# [build-dependencies]) with the locally regenerated checkout.
# Remove with: ./tools/game-version-update/regen.sh --revert
[patch."$RELIQUARY_URL"]
reliquary = { path = ".gamedata-work/reliquary" }
# <<< game-version-update patch
PATCH
else
  echo "==> Cargo.toml already pinned to the local checkout"
fi

# --- 5. build ---------------------------------------------------------------
if [ "$BUILD" = 1 ]; then
  echo "==> building"
  ( cd "$REPO_ROOT" && cargo build )
  echo
  echo "Built. Verify against a real capture before trusting it:"
  echo "    ./target/debug/reliquary-archiver --pcap <capture.pcap> -v out.json"
  echo "Structural checks cannot prove a dump matches your client -- a capture can."
else
  echo "==> skipping build (--no-build)"
fi
