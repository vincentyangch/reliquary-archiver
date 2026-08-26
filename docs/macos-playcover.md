# macOS Apple Silicon and PlayCover

The supported macOS shape is an Apple Silicon command-line pcap build. There is no macOS GUI build or GUI capture workflow.

PlayCover game traffic uses the host macOS network stack. The existing UDP `23301-23302` capture filter is therefore the intended capture path. This is a practical capture workflow, not official upstream PlayCover support, and compatibility is not guaranteed across game or PlayCover versions.

## Prerequisites

- An Apple Silicon Mac.
- Xcode Command Line Tools. Install them with `xcode-select --install`.
- Rust installed with [rustup](https://rustup.rs/).
- A working PlayCover installation and game.

macOS already provides the system `libpcap` used by this build. Npcap is Windows-only and is not needed on macOS.

Build the command-line capture binary with:

```sh
cargo build --release --no-default-features --features pcap,stream
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

Identify the active interface with:

```sh
networksetup -listallhardwareports
```

Then capture the login traffic (replace `en1` with the interface you identified):

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
- **Wrong interface:** use `networksetup -listallhardwareports` to identify the interface, and read the capture back with `tcpdump -nn -r hsr-login.pcap` to verify that it contains the expected traffic.
- **Game-version changes:** the parser may need an update when the game protocol changes; a valid capture can still fail to produce an export until a parser update is available.
- **VPNs and filtering:** VPNs, firewalls, or other network filtering can prevent the expected packets from appearing. First allowlist the game and capture traffic, or retry on another network path; if you temporarily disable filtering to test, re-enable it immediately afterward.
