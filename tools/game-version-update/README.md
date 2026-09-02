# Game version update runbook

When the game updates (4.4 -> 4.5 -> ...), this archiver stops working with:

    decryption key is missing for command
    "This game version is not supported yet."

Nothing in *this* repo needs to change. Every version-specific value lives in the
[`reliquary`](https://github.com/IceDynamix/reliquary) dependency pinned in
`Cargo.toml`. These scripts rebuild that dependency from a new protocol dump.

---

## How the traffic is encrypted

Worth understanding, because it determines what data an update actually needs.

Game commands are XOR'd against a repeating pad — no AES, no asymmetric crypto on
the packet body:

```rust
// reliquary/src/network/crypto.rs
for i in 0..encrypted.len() {
    encrypted[i] ^= key[i % key.len()];
}
```

Every command restarts at pad offset 0. There are two pads in play:

**1. The initial pad** — a 4096-byte per-build constant shipped inside the game
client, used for pre-login traffic. This is the only real secret, and the only
piece that cannot be derived from captured traffic alone.

**2. The session pad** — during login the server sends `PlayerGetTokenScRsp`
carrying `secret_key_seed: u64`. Both sides expand it with a Mersenne Twister
(MT19937-64), 512 draws of 8 bytes = the same 4096 bytes:

```rust
let mut generator = Mt64::new(seed);       // 512 * u64 = 4096 bytes
```

So once you can decrypt `PlayerGetTokenScRsp`, everything afterwards is
reconstructible — the session key is derived from a seed that travels in the
packet stream. **An update only ever needs the initial pad.**

### How reliquary knows which pad to use, and whether it worked

Every command's plaintext starts with the magic `0x9D74C714`. That gives both a
lookup index and an integrity check, via one function:

```rust
pub fn get_game_version(bytes: &[u8]) -> u32 {
    u32::from_be_bytes(bytes[..4].try_into().unwrap()) ^ 0x9D74C714
}
```

- Run it on **ciphertext**: `(magic ^ pad[0..4]) ^ magic` = `pad[0..4]`. The
  "game version" u32 in the key table is therefore just *the first four bytes of
  the pad itself* — a self-identifying fingerprint, not a version number.
  (Verified: this holds for all 29 keys in reliquary v22.0.0.)
- Run it on **plaintext**: `magic ^ magic` = `0`. Anything non-zero means the
  wrong pad, which reliquary reports as `VersionMismatch`.

`apply-key.py` uses the first property to derive the table index from the key,
so you never have to supply the version number separately.

### Wire format

```
[0..4]                    magic 0x9D74C714
[4..6]                    command_id      (u16 BE)   <- shuffled every version
[6..8]                    header_len      (u16 BE)
[8..12]                   data_len        (u32 BE)
[12 .. 12+header_len]     proto_header
[.. + data_len]           proto_data      (protobuf)  <- field numbers shuffled too
[last 4]                  tail magic
```

---

## What a version bump actually requires

Three things, all derived from the new client binary:

| # | Thing | Lands in | Consequence if stale |
|---|-------|----------|----------------------|
| 1 | Initial 4096-byte pad | `crypto.rs` `lookup_initial_key` | `DecryptionKeyMissing` — nothing decrypts at all |
| 2 | Command ids | `command_id.rs` | Commands unrecognised or misrouted |
| 3 | Protobuf field numbers | `proto/*.rs` | Fields parse as garbage |

All three change every patch. Measured across the 4.3 -> 4.4 bump, all nine
commands this archiver reads moved:

| command | 4.3 | 4.4 |
|---|---|---|
| PlayerGetTokenScRsp | 13 | 81 |
| PlayerLoginScRsp | 3 | 78 |
| PlayerLoginFinishScRsp | 31 | 27 |
| GetBagScRsp | 503 | 578 |
| GetAvatarDataScRsp | 303 | 378 |
| PlayerSyncScNotify | 673 | 625 |
| SetAvatarEnhancedIdScRsp | 335 | 312 |
| GetGachaInfoScRsp | 1903 | 1978 |
| DoGachaScRsp | 1927 | 1958 |

Field numbers shuffle as well — in `Relic`, `unique_id` moved from wire tag 120
to 8 across the same bump. **A key alone is not enough.**

The game *resource* data (characters, relics, text) is separate and already
self-updating: `build.rs` pulls it from Dimbreath's repo at build time, so new
characters and relic sets arrive without any code change.

---

## The happy path

If upstream has already tagged a release for the new version, you do not need any
of this. Check first:

```sh
./tools/game-version-update/check-upstream.sh
```

If it reports a new tag, just bump `tag = "v22.0.0"` in `Cargo.toml` and rebuild.
That is the supported route and should always be preferred.

## The manual path

Only when you have a dump and upstream has not shipped yet.

```sh
./tools/game-version-update/regen.sh --data <dump-dir> --key <base64-or-file>
```

which validates the dump, regenerates protos and command ids via
`reliquary-codegen`, inserts the pad, points `Cargo.toml` at the local checkout
through a `[patch]` block, and builds. Undo with:

```sh
./tools/game-version-update/regen.sh --revert
```

Working clones live in `.gamedata-work/` (gitignored, ~57 MB).

### Dump layout

`reliquary-codegen` expects:

```
<dump-dir>/packetIds.json          {"<id>": "<CommandName>", ...}   ids are keys
<dump-dir>/proto/<Name>.proto      ONE FILE PER MESSAGE
```

The one-file-per-message rule is not optional: `protobuf-codegen` names each
generated `.rs` after its input `.proto`, and reliquary imports
`proto::Relic`, `proto::KVP` and so on. A single monolithic `StarRail.proto`
produces a single `StarRail.rs` and nothing resolves. Reliquary v22.0.0 ships
4,912 such modules.

Run `validate-dump.py <dump-dir> --reliquary .gamedata-work/reliquary` to check a
candidate before regenerating. It verifies the id map is the right way round, that
all nine commands this archiver reads are present, and that every type the
`proto-rqa` feature imports exists in a correctly-named file.

### Known-bad source: `yuvlian/hsr-proto`

It is the obvious candidate — public, has `CmdId.json` and `StarRail.proto` — and
it does **not** work. Measured against every reliquary version:

| reliquary | shared names | identical ids |
|---|---|---|
| 4.0 | 1310 | 22 (1.7%) |
| 4.1 | 1342 | 14 (1.0%) |
| 4.2 | 1364 | 11 (0.8%) |
| 4.3 | 1779 | 35 (2.0%) |
| 4.4 | 1432 | 13 (0.9%) |

~1-2% agreement is what you would expect from chance collisions within the same
bucketing scheme, not a shared source — it tracks a different client branch. Its
`CmdId.json` is also inverted (name -> id) and monolithic. Do not wire it in.

### Verifying a rebuild

Structural validation cannot prove a dump matches your client. Only a capture can:

```sh
./target/debug/reliquary-archiver --pcap <capture.pcap> -v out.json
```

A capture taken while logging in is enough — success means the pad decrypted
`PlayerGetTokenScRsp` and the ids and field numbers all lined up.
