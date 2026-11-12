# macOS Apple Silicon and PlayCover

The supported macOS shape is an Apple Silicon command-line pcap build. There is no macOS GUI build or GUI capture workflow.

PlayCover game traffic uses the host macOS network stack. The existing UDP `23301-23302` capture filter is therefore the intended capture path. This is a practical capture workflow, not official upstream PlayCover support, and compatibility is not guaranteed across game or PlayCover versions.

## Compatibility (checked 2026-11-11)

Game version 4.7 works ahead of upstream. This repository includes upstream Archiver `v0.19.0`, whose dependency lines in `Cargo.toml` name `reliquary v24.0.0` for [game version 4.6](https://github.com/IceDynamix/reliquary/blob/v24.0.0/README.md). A `[patch]` section at the end of that file overrides it with `reliquary 25.0.0` from the open upstream pull request [Update protos for version 4.7](https://github.com/IceDynamix/reliquary/pull/27), pinned to commit `40c868e`, the first commit of that pull request, in the pull request author's fork. That commit contains the 4.7 initial decryption key, command IDs, and regenerated protobuf definitions. Commits added to the pull request since then are not included: as of this check they only add or rename definitions for affinitive eidolons and relic recon, which Archiver `v0.19.0` does not read.

The override was checked with a 4.7 login captured from PlayCover: `./tools/game-version-update/capture-and-verify.sh` passed, and this branch's release build produces the same export when it replays that capture.

Known limitations: Archiver `v0.19.0` predates 4.7. Compared with the open upstream pull request [update reliquary to v25](https://github.com/IceDynamix/reliquary-archiver/pull/191), which is not included here, its export lacks:

- the Elation debt trace (skill-tree point anchor `23`). The archiver logs `unknown point anchor` and skips that point; the rest of the character is exported.
- affinitive eidolons.
- relic recon relics, both in the export file and as live events under `--stream`.

Only the first of these shows up in the log; the other two are skipped without a warning.

The override is temporary. Once upstream releases `reliquary v25.0.0`, drop it (`./tools/game-version-update/regen.sh --revert`, then `cargo update reliquary` so that `Cargo.lock` follows) and take the update from upstream.

The login check above covers only the client it was run on. To verify JSON export from your own PlayCover client, run `./tools/game-version-update/capture-and-verify.sh` from this worktree to capture and validate a fresh login, or use `--replay <file.pcap>` for an existing capture. An older capture tests its original game version only. Keep captures local because they contain session traffic.

## Prerequisites

- An Apple Silicon Mac.
- Xcode Command Line Tools. Install them with `xcode-select --install`.
- Rust installed with [rustup](https://rustup.rs/). Reliquary v24 requires Rust 1.95 or newer; this repository selects Rust 1.98.1 through `rust-toolchain.toml`.
- A working PlayCover installation and game.

macOS already provides the system `libpcap` used by this build. Npcap is Windows-only and is not needed on macOS.

Build the command-line capture binary with:

```sh
cargo build --locked --release --no-default-features --features pcap,stream
```

The binary is `target/release/reliquary-archiver`.

## Capture PlayCover traffic

1. Launch the game in PlayCover and stop at the **Click to Start** screen; do not enter the game yet.
2. From the repository root, start the archiver before entering the game:

   ```sh
   sudo ./target/release/reliquary-archiver --timeout 180
   ```

3. Enter the game by clicking **Click to Start** and wait for the login/capture to complete.
4. Import the newest generated `archive_output-*.json` into the destination application; older exports may already be present.

Live capture requires access to macOS Berkeley Packet Filter (BPF) devices. Using `sudo` is the simplest way to grant that access for a capture. If you prefer not to run the archiver as root, install and configure Wireshark's ChmodBPF launch daemon, following [Wireshark's macOS installation instructions](https://www.wireshark.org/docs/wsug_html_chunked/ChBuildInstallOSXInstall.html), and then retry without `sudo`. For repeated use, ChmodBPF is recommended; `sudo` may create root-owned output or log files.

## Offline capture

Identify the interface used by the default route with:

```sh
route -n get default | awk '/interface:/{print $2}'
```

Use the resulting interface (for example, `en1`) to capture the login traffic. If you need to map interface names to hardware ports, or the default-route command is unavailable, use `networksetup -listallhardwareports` as a mapping/fallback:

```sh
sudo tcpdump -i en1 -n -s 0 -w hsr-login.pcap 'udp portrange 23301-23302'
```

Start the capture before entering the game, stop `tcpdump` after the login traffic has been captured, and parse the file with:

```sh
./target/release/reliquary-archiver --pcap hsr-login.pcap
```

Import the newest resulting `archive_output-*.json` file; older exports may already be present.

## Troubleshooting

- **`/dev/bpf` permission errors:** run the archiver command shown in **Capture PlayCover traffic** with `sudo`. Alternatively, configure Wireshark ChmodBPF as described above.
- **No JSON output or capture does not start:** make sure the archiver is running while the game is still at **Click to Start**, then enter the game. If the game was already running, log out and repeat the sequence.
- **Wrong interface:** identify the default-route interface with `route -n get default | awk '/interface:/{print $2}'`; use `networksetup -listallhardwareports` to map or cross-check it, and read the capture back with `tcpdump -nn -r hsr-login.pcap` to verify that it contains the expected traffic.
- **Game-version changes:** the parser may need an update when the game protocol changes; a valid capture can still fail to produce an export until a parser update is available.
- **VPNs and filtering:** VPNs, firewalls, or other network filtering can prevent the expected packets from appearing. First allowlist the game and capture traffic, or retry on another network path; if you temporarily disable filtering to test, re-enable it immediately afterward.
