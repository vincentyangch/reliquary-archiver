#!/usr/bin/env bash
# Checks whether a new game-version update has landed, and reports the cheapest
# route to pick it up.
#
# Two things can move, and they imply different work:
#
#   1. `reliquary` publishes a new tag. That is where all game-version-specific
#      data lives (initial decryption key, command ids, protobuf field numbers).
#   2. The upstream *archiver* merges that tag itself. When this has happened the
#      correct action is to merge upstream, not to hand-edit Cargo.toml -- an
#      upstream bump usually travels with fixes you would otherwise miss.
#
# Checking only (1) is misleading: it recommends editing the tag by hand even
# when upstream has already done it and shipped bug fixes alongside.
#
# Exit codes:
#   0  no change since the pinned version
#   10 an update is available (see RESULT for the recommended route)
#   1  error

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RELIQUARY_URL="https://github.com/IceDynamix/reliquary"
ARCHIVER_SLUG="IceDynamix/reliquary-archiver"
ARCHIVER_RAW="https://raw.githubusercontent.com/$ARCHIVER_SLUG/main/Cargo.toml"
GAMEDATA_API="https://gitlab.com/api/v4/projects/Dimbreath%2Fturnbasedgamedata/repository/commits?per_page=1"

# Pull the reliquary tag out of a Cargo.toml given on stdin.
#
# The dependency is declared as one line carrying both the git URL and the tag:
#     reliquary = { git = "https://.../reliquary", tag = "v23.0.0", features = [
# so scope to that line first. Matching `reliquary[^"]*tag` does not work -- the
# URL in between is quoted, and the character class cannot cross it.
pinned_tag_from() {
  local toml; toml="$(cat)"
  { echo "$toml" | grep -E '^\s*reliquary = ' || echo "$toml"; } \
    | grep -oE 'tag = "v[0-9]+\.[0-9]+\.[0-9]+"' \
    | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true
}

pinned_tag="$(pinned_tag_from < "$REPO_ROOT/Cargo.toml")"
[ -n "$pinned_tag" ] || { echo "ERROR: could not find pinned reliquary tag in Cargo.toml" >&2; exit 1; }

# --- reliquary -------------------------------------------------------------
# All tags, newest-first by version sort.
all_tags="$(git ls-remote --tags "$RELIQUARY_URL" 2>/dev/null \
  | grep -oE 'refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$' \
  | sed 's|refs/tags/||' | sort -t. -k1.2,1n -k2,2n -k3,3n)"
[ -n "$all_tags" ] || { echo "ERROR: could not reach $RELIQUARY_URL" >&2; exit 1; }

latest_tag="$(echo "$all_tags" | tail -1)"
main_sha="$(git ls-remote --heads "$RELIQUARY_URL" refs/heads/main | cut -f1)"
pinned_sha="$(git ls-remote "$RELIQUARY_URL" "refs/tags/${pinned_tag}" | cut -f1)"

# --- upstream archiver ------------------------------------------------------
# Prefer a configured remote so we can count commits; fall back to reading the
# raw Cargo.toml, which still tells us which tag upstream pins.
upstream_remote="$(git -C "$REPO_ROOT" remote -v 2>/dev/null \
  | grep -F "$ARCHIVER_SLUG" | grep '(fetch)' | awk '{print $1}' | head -1 || true)"

upstream_pins=""
commits_ahead=""
if [ -n "$upstream_remote" ]; then
  if git -C "$REPO_ROOT" fetch -q "$upstream_remote" main 2>/dev/null; then
    commits_ahead="$(git -C "$REPO_ROOT" rev-list --count HEAD..FETCH_HEAD 2>/dev/null || echo "")"
    upstream_pins="$(git -C "$REPO_ROOT" show FETCH_HEAD:Cargo.toml 2>/dev/null | pinned_tag_from)"
  fi
fi
if [ -z "$upstream_pins" ]; then
  upstream_pins="$(curl -sf --max-time 20 "$ARCHIVER_RAW" 2>/dev/null | pinned_tag_from)"
fi

game_build="$(curl -sf --max-time 20 "$GAMEDATA_API" 2>/dev/null \
  | sed -n 's/.*"title":"\([^"]*\)".*/\1/p' | head -1 || echo "unknown")"

echo "pinned_tag=$pinned_tag"
echo "latest_tag=$latest_tag"
echo "reliquary_main=${main_sha:0:8}"
echo "reliquary_pinned=${pinned_sha:0:8}"
echo "upstream_pins=${upstream_pins:-unknown}"
echo "upstream_commits_ahead=${commits_ahead:-unknown}"
echo "game_data_build=$game_build"

# --- verdict ----------------------------------------------------------------
# Merging upstream is preferred whenever it is actually ahead: it picks up the
# dependency bump *and* whatever else shipped with it.
status=0
if [ -n "$commits_ahead" ] && [ "$commits_ahead" != "0" ]; then
  note="upstream/main is $commits_ahead commit(s) ahead"
  if [ -n "$upstream_pins" ] && [ "$upstream_pins" != "$pinned_tag" ]; then
    note="$note and pins $upstream_pins (you are on $pinned_tag)"
  fi
  echo "RESULT=merge-upstream  $note"
  echo "    git merge ${upstream_remote}/main"
  status=10
elif [ "$latest_tag" != "$pinned_tag" ]; then
  # A new reliquary tag upstream has not picked up yet -- bump it by hand.
  echo "RESULT=new-tag  $pinned_tag -> $latest_tag"
  echo "    upstream still pins ${upstream_pins:-unknown}; edit Cargo.toml yourself"
  status=10
elif [ -n "$main_sha" ] && [ "$main_sha" != "$pinned_sha" ]; then
  echo "RESULT=main-ahead  main is ${main_sha:0:8}, pinned tag is ${pinned_sha:0:8}"
  status=10
else
  echo "RESULT=no-change  still on $pinned_tag"
fi

if [ "$status" = 10 ]; then
  echo
  echo "After updating, confirm the dependency really is the new game version:"
  echo "    ./tools/game-version-update/verify-bump.sh"
fi
exit $status
