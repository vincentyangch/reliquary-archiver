#!/usr/bin/env bash
# Checks whether a new game-version update has landed in the `reliquary` dependency.
#
# reliquary is where all game-version-specific data lives (initial decryption key,
# command ids, protobuf field numbers). When it publishes a new major tag, this
# archiver can be updated by bumping the tag in Cargo.toml.
#
# Exit codes:
#   0  no change since the pinned version
#   10 an update is available (new tag, or main moved past the pinned tag)
#   1  error

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RELIQUARY_URL="https://github.com/IceDynamix/reliquary"
GAMEDATA_API="https://gitlab.com/api/v4/projects/Dimbreath%2Fturnbasedgamedata/repository/commits?per_page=1"

pinned_tag="$(grep -oE 'reliquary\?[^"]*tag = "v[0-9]+\.[0-9]+\.[0-9]+"' "$REPO_ROOT/Cargo.toml" 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
if [ -z "$pinned_tag" ]; then
  pinned_tag="$(grep -oE 'tag = "v[0-9]+\.[0-9]+\.[0-9]+"' "$REPO_ROOT/Cargo.toml" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
fi
[ -n "$pinned_tag" ] || { echo "ERROR: could not find pinned reliquary tag in Cargo.toml" >&2; exit 1; }

# All tags, newest-first by version sort.
all_tags="$(git ls-remote --tags "$RELIQUARY_URL" 2>/dev/null \
  | grep -oE 'refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$' \
  | sed 's|refs/tags/||' | sort -t. -k1.2,1n -k2,2n -k3,3n)"
[ -n "$all_tags" ] || { echo "ERROR: could not reach $RELIQUARY_URL" >&2; exit 1; }

latest_tag="$(echo "$all_tags" | tail -1)"
main_sha="$(git ls-remote --heads "$RELIQUARY_URL" refs/heads/main | cut -f1)"
pinned_sha="$(git ls-remote "$RELIQUARY_URL" "refs/tags/${pinned_tag}" | cut -f1)"

game_build="$(curl -sf --max-time 20 "$GAMEDATA_API" 2>/dev/null \
  | sed -n 's/.*"title":"\([^"]*\)".*/\1/p' | head -1 || echo "unknown")"

echo "pinned_tag=$pinned_tag"
echo "latest_tag=$latest_tag"
echo "reliquary_main=${main_sha:0:8}"
echo "reliquary_pinned=${pinned_sha:0:8}"
echo "game_data_build=$game_build"

status=0
if [ "$latest_tag" != "$pinned_tag" ]; then
  echo "RESULT=new-tag  $pinned_tag -> $latest_tag"
  status=10
elif [ -n "$main_sha" ] && [ "$main_sha" != "$pinned_sha" ]; then
  echo "RESULT=main-ahead  main is ${main_sha:0:8}, pinned tag is ${pinned_sha:0:8}"
  status=10
else
  echo "RESULT=no-change  still on $pinned_tag"
fi
exit $status
