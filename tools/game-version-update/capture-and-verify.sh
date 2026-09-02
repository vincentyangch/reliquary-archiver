#!/usr/bin/env bash
# Capture a login and prove the archiver can still read it, in one command.
#
#   ./tools/game-version-update/capture-and-verify.sh            # capture, then verify
#   ./tools/game-version-update/capture-and-verify.sh --replay <file.pcap>
#
# Structural checks (verify-bump.sh) prove a dependency is different. Only real
# traffic proves it matches your client, so this is the step that actually
# closes out a version bump.
#
# The capture itself has a few sharp edges, and all of them fail quietly:
#
#   - The login handshake is the whole point. PlayerGetTokenScRsp is what the
#     initial pad has to decrypt, and it goes past exactly once, at login. Start
#     capturing before pressing "Click to Start" or there is nothing to read.
#   - tcpdump needs the right interface. The wrong one yields a valid, empty file.
#   - tcpdump runs under sudo, so the capture ends up owned by root.
#
# So: detect the interface, prompt at the right moment, hand the file back to
# you, and fail loudly rather than producing an empty capture.
#
# Options:
#   --iface <name>   capture interface (default: the default route's)
#   --replay <file>  skip capturing, verify an existing .pcap
#   --out <file>     where to write the capture
#   --json <file>    where to write the export
#   --clean          delete the capture once verified
#
# Exit codes:
#   0  capture decrypted and the export looks sane
#   1  something failed (message says what)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOLS="$REPO_ROOT/tools/game-version-update"
BIN="$REPO_ROOT/target/debug/reliquary-archiver"
FILTER="udp portrange 23301-23302"

IFACE="" ; REPLAY="" ; OUT="" ; JSON="" ; CLEAN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --iface)  IFACE="$2";  shift 2 ;;
    --replay) REPLAY="$2"; shift 2 ;;
    --out)    OUT="$2";    shift 2 ;;
    --json)   JSON="$2";   shift 2 ;;
    --clean)  CLEAN=1;     shift ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

stamp="$(date +%Y%m%dT%H%M%S)"
OUT="${OUT:-$REPO_ROOT/hsr-login-$stamp.pcap}"
JSON="${JSON:-$REPO_ROOT/hsr-verify-$stamp.json}"

# --- the archiver itself ----------------------------------------------------
if [ ! -x "$BIN" ]; then
  echo "==> building the archiver first"
  ( cd "$REPO_ROOT" && cargo build )
fi

# --- capture ----------------------------------------------------------------
if [ -n "$REPLAY" ]; then
  [ -f "$REPLAY" ] || { echo "ERROR: no such capture: $REPLAY" >&2; exit 1; }
  OUT="$REPLAY" ; CLEAN=0
  echo "==> replaying $OUT (no capture)"
else
  if [ -z "$IFACE" ]; then
    IFACE="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}' | head -1 || true)"
  fi
  [ -n "$IFACE" ] || { echo "ERROR: could not determine an interface; pass --iface" >&2; exit 1; }

  echo "==> capturing on $IFACE -> $OUT"
  echo "    filter: $FILTER"
  echo
  echo "    tcpdump needs root, so you may be asked for your password now."
  sudo -v || { echo "ERROR: sudo is required to capture" >&2; exit 1; }

  echo
  echo "    1. Get the game to the \"Click to Start\" screen. Do not enter the game yet."
  echo "    2. Press Enter here to start capturing."
  echo "    3. Then press \"Click to Start\" and let the game load in."
  echo "    4. Come back and press Ctrl+C to stop."
  echo
  if [ -t 0 ]; then
    printf "    ready? [Enter] "
    read -r _
  fi

  # tcpdump runs in the foreground so Ctrl+C reaches it directly and it can
  # print its own statistics. Trapping INT here keeps that same Ctrl+C from
  # taking the script down with it, so we still get to verify the result.
  trap ':' INT
  sudo tcpdump -i "$IFACE" -n -s 0 -w "$OUT" "$FILTER" || true
  trap - INT

  # Written by root; hand it back so the rest runs unprivileged.
  [ -f "$OUT" ] && sudo chown "$(id -u):$(id -g)" "$OUT"
fi

# --- did we actually get the traffic? ---------------------------------------
echo
if [ ! -s "$OUT" ]; then
  echo "FAIL: capture file is empty or missing" >&2
  exit 1
fi

packets="$(tcpdump -nn -r "$OUT" 2>/dev/null | grep -c . || true)"
echo "==> captured $packets packet(s), $(du -h "$OUT" | cut -f1) in $OUT"
if [ "$packets" -eq 0 ]; then
  # Only interfaces holding an IPv4 address are plausible candidates. Listing
  # every interface buries the answer under a screenful of idle utun devices.
  candidates=""
  for i in $(ifconfig -l 2>/dev/null | tr ' ' '\n'); do
    addr="$(ipconfig getifaddr "$i" 2>/dev/null || true)"
    [ -n "$addr" ] && candidates="$candidates      $i ($addr)"$'\n'
  done
  cat >&2 <<EOF

FAIL: the capture contains no game traffic.

Most likely one of:
  - The capture was not running during login. It has to be started before
    "Click to Start" -- the handshake goes past once and is not repeated.
    This is the common one; just run it again and watch the ordering.
  - Wrong interface${IFACE:+ (this run used $IFACE)}. Interfaces with an address:
${candidates:-      (none found)}    Re-run with --iface <name>.
  - A VPN or filter is moving the traffic off this interface.
EOF
  exit 1
fi

# --- decrypt and export ------------------------------------------------------
echo
echo "==> replaying through the archiver"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
if ! "$BIN" --pcap "$OUT" -v -e "$JSON" >"$log" 2>&1; then
  echo "FAIL: the archiver exited non-zero" >&2
  tail -20 "$log" >&2
  exit 1
fi

# The one line that proves the pinned pad matched this client.
if grep -q 'found initial decryption key' "$log"; then
  echo "    $(grep -m1 -o 'found initial decryption key.*' "$log")"
else
  echo "FAIL: no initial decryption key matched this capture." >&2
  echo "      The pinned reliquary version does not support this game version." >&2
  grep -iE 'decryption key is missing|not supported' "$log" | head -3 >&2 || true
  exit 1
fi

for cmd in PlayerGetTokenScRsp PlayerLoginScRsp; do
  line="$(grep -m1 -oE "command_id: [0-9]+, command_name: Some\(\"$cmd\"\)" "$log" || true)"
  [ -n "$line" ] && echo "    $line"
done

if [ ! -s "$JSON" ]; then
  echo "FAIL: no export was written" >&2
  exit 1
fi

# --- is the export sane? -----------------------------------------------------
echo
echo "==> validating the export"
if ! "$TOOLS/validate-export.py" "$JSON"; then
  echo >&2
  echo "FAIL: the capture decrypted but the export looks wrong." >&2
  echo "      Decryption working while fields are wrong points at stale protobuf" >&2
  echo "      definitions rather than a bad key." >&2
  exit 1
fi

echo
if [ "$CLEAN" = 1 ]; then
  rm -f "$OUT"
  echo "removed $OUT"
else
  echo "Capture kept at $OUT (gitignored -- it contains your session traffic)."
fi
echo "PASS: this build reads live game traffic and exports correctly."
