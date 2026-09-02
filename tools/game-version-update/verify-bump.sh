#!/usr/bin/env bash
# Confirms that a bumped `reliquary` dependency really is a new game version.
#
#   ./tools/game-version-update/verify-bump.sh [--from <tag>] [--to <tag>]
#
# After changing the pinned tag it is easy to assume the update worked because
# the build succeeded. A build proves the *types* still resolve; it says nothing
# about whether the new dependency carries new game data. This checks the three
# things a real version bump must change (see README.md):
#
#   1. a new initial decryption pad in the key table
#   2. new command ids for the commands this archiver reads
#   3. regenerated protobuf definitions
#
# With no arguments it compares the currently pinned tag against the previous
# one, recovered from this repository's own history of Cargo.toml.
#
# This is a structural check. It can prove a dependency is *different*; only a
# capture can prove it matches your client:
#     ./tools/game-version-update/capture-and-verify.sh
#
# Exit codes:
#   0  looks like a genuine version bump
#   1  error, or the comparison found no evidence of one

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$REPO_ROOT/.gamedata-work/verify"
RELIQUARY_URL="https://github.com/IceDynamix/reliquary"

FROM="" ; TO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="$2"; shift 2 ;;
    --to)   TO="$2";   shift 2 ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

tag_from_toml() {
  local toml; toml="$(cat)"
  { echo "$toml" | grep -E '^\s*reliquary = ' || echo "$toml"; } \
    | grep -oE 'tag = "v[0-9]+\.[0-9]+\.[0-9]+"' \
    | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true
}

# --- work out which two versions to compare --------------------------------
[ -n "$TO" ] || TO="$(tag_from_toml < "$REPO_ROOT/Cargo.toml")"
[ -n "$TO" ] || { echo "ERROR: could not find a pinned reliquary tag in Cargo.toml" >&2; exit 1; }

if [ -z "$FROM" ]; then
  # Walk this repo's history of Cargo.toml for the previously pinned tag.
  while read -r sha; do
    prev="$(git -C "$REPO_ROOT" show "$sha:Cargo.toml" 2>/dev/null | tag_from_toml)"
    if [ -n "$prev" ] && [ "$prev" != "$TO" ]; then FROM="$prev"; break; fi
  done < <(git -C "$REPO_ROOT" log --format=%H -- Cargo.toml 2>/dev/null)
fi
[ -n "$FROM" ] || { echo "ERROR: could not determine the previous tag; pass --from" >&2; exit 1; }

echo "comparing reliquary $FROM -> $TO"

# --- locate a source tree for each tag --------------------------------------
# Prefer the checkout cargo already made during the build; clone only if absent.
checkout_for() {
  local tag="$1" sha short dir
  sha="$(git ls-remote "$RELIQUARY_URL" "refs/tags/$tag" 2>/dev/null | cut -f1)"
  if [ -n "$sha" ]; then
    short="${sha:0:7}"
    for dir in "$HOME"/.cargo/git/checkouts/reliquary-*/"$short"; do
      [ -d "$dir/src/network" ] && { echo "$dir"; return 0; }
    done
  fi
  dir="$WORK/$tag"
  if [ ! -d "$dir/src/network" ]; then
    mkdir -p "$WORK"
    git clone -q --depth 1 --branch "$tag" "$RELIQUARY_URL" "$dir" >&2 || return 1
  fi
  echo "$dir"
}

OLD="$(checkout_for "$FROM")" || { echo "ERROR: could not obtain reliquary $FROM" >&2; exit 1; }
NEW="$(checkout_for "$TO")"   || { echo "ERROR: could not obtain reliquary $TO" >&2; exit 1; }

failures=0

# --- 1. initial decryption pads ---------------------------------------------
# The key table is `match version { <u32> => "<base64 pad>", ... }`. That u32 is
# not a version number -- it is the first four bytes of the pad itself, which
# makes it a self-identifying fingerprint (README.md explains why).
echo
echo "==> initial decryption keys"
key_ids() { grep -oE '^[[:space:]]+[0-9]{6,} =>' "$1/src/network/crypto.rs" | grep -oE '[0-9]+' | sort; }
old_keys="$(key_ids "$OLD")" ; new_keys="$(key_ids "$NEW")"
added="$(comm -13 <(echo "$old_keys") <(echo "$new_keys"))"
removed="$(comm -23 <(echo "$old_keys") <(echo "$new_keys"))"
echo "    $FROM: $(echo "$old_keys" | grep -c .) keys"
echo "    $TO: $(echo "$new_keys" | grep -c .) keys"
if [ -n "$added" ]; then
  echo "    added: $(echo "$added" | tr '\n' ' ')"
else
  echo "    added: NONE -- no new pad, so no new game version" >&2
  failures=$((failures + 1))
fi
[ -n "$removed" ] && echo "    removed: $(echo "$removed" | tr '\n' ' ')  (unusual -- old captures will stop working)"

# --- 2. command ids ----------------------------------------------------------
# Derived from this archiver's own imports rather than hardcoded, so the list
# stays correct as the archiver starts or stops reading commands. Both the plain
# `command_id::Name` and the brace form `command_id::{A, B, C}` are in use, and
# a naive match on the former silently sees only the first name in each group.
echo
echo "==> command ids read by this archiver"
commands="$(python3 - "$REPO_ROOT/src" <<'PY'
import pathlib, re, sys
pat = re.compile(r"command_id::\{([^}]*)\}|command_id::([A-Za-z0-9_]+)")
found = set()
for rs in pathlib.Path(sys.argv[1]).rglob("*.rs"):
    for m in pat.finditer(rs.read_text(encoding="utf-8", errors="replace")):
        for name in (m.group(1) or m.group(2) or "").split(","):
            name = name.strip()
            if re.fullmatch(r"[A-Za-z0-9_]+", name):
                found.add(name)
print("\n".join(sorted(found)))
PY
)"
[ -n "$commands" ] || { echo "    ERROR: found no command_id references in src/" >&2; exit 1; }

id_of() { grep -oE "pub const $2: u16 = [0-9]+" "$1/src/network/command/command_id.rs" 2>/dev/null \
  | grep -oE '[0-9]+$' || true; }

changed=0 ; missing=0
while read -r cmd; do
  [ -n "$cmd" ] || continue
  o="$(id_of "$OLD" "$cmd")" ; n="$(id_of "$NEW" "$cmd")"
  if [ -z "$n" ]; then
    printf "    %-26s %-8s -> MISSING\n" "$cmd" "${o:-?}" >&2
    missing=$((missing + 1))
  elif [ "$o" != "$n" ]; then
    printf "    %-26s %-8s -> %-8s changed\n" "$cmd" "${o:-?}" "$n"
    changed=$((changed + 1))
  else
    printf "    %-26s %-8s -> %-8s unchanged\n" "$cmd" "${o:-?}" "$n"
  fi
done <<< "$commands"

total="$(echo "$commands" | grep -c .)"
echo "    $changed of $total changed"
if [ "$missing" -gt 0 ]; then
  echo "    $missing command(s) absent from $TO -- the archiver will not build or will misroute" >&2
  failures=$((failures + 1))
fi
if [ "$changed" = 0 ]; then
  echo "    no command ids moved, which does not happen across a real version bump" >&2
  failures=$((failures + 1))
fi

# --- 3. protobuf definitions -------------------------------------------------
echo
echo "==> protobuf definitions"
old_n="$(ls "$OLD/src/network/command/proto/" 2>/dev/null | wc -l | tr -d ' ')"
new_n="$(ls "$NEW/src/network/command/proto/" 2>/dev/null | wc -l | tr -d ' ')"
echo "    modules: $old_n -> $new_n"
regenerated=0
for f in Relic Avatar Equipment; do
  if [ ! -f "$NEW/src/network/command/proto/$f.rs" ]; then
    echo "    $f.rs: MISSING from $TO" >&2
    failures=$((failures + 1))
  elif cmp -s "$OLD/src/network/command/proto/$f.rs" "$NEW/src/network/command/proto/$f.rs"; then
    echo "    $f.rs: identical"
  else
    echo "    $f.rs: differs"
    regenerated=$((regenerated + 1))
  fi
done
if [ "$regenerated" = 0 ]; then
  echo "    no core message changed -- field numbers shuffle every patch, so this is suspect" >&2
  failures=$((failures + 1))
fi

# --- verdict -----------------------------------------------------------------
echo
if [ "$failures" -gt 0 ]; then
  echo "FAIL: $failures check(s) found no evidence of a version bump ($FROM -> $TO)"
  exit 1
fi
echo "PASS: $TO carries a new pad, new command ids, and regenerated protos"
echo
echo "Structural only. Confirm against real traffic before trusting it:"
echo "    ./tools/game-version-update/capture-and-verify.sh"
