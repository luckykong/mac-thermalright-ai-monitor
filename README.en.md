# MacTR — AI Agent & System Monitor for Thermalright LCD

[中文](README.md) · [English](README.en.md)

<p align="center">
  <img src="img/app-icon-v1.4.1.png" width="112" alt="MacTR app icon">
</p>

Turn the 1920×480 LCD on your Thermalright CPU cooler into a live dashboard that shows
your Mac's vitals **and what your AI coding agents are doing right now** — all native on
macOS, no Windows required.

![MacTR 1920×480 dashboard screenshot](img/dashboard.png)

![Dashboard](img/dashboard.gif)

<sub>The static frame comes from the current renderer with system metrics from the
connected Mac. Agent text and the custom card use redacted examples; the animated
preview uses the built-in showcase dataset.</sub>

> Fork of [beret21/MacTR](https://github.com/beret21/MacTR), reworked around a central
> **AI Agents** panel that tracks [Claude Code](https://claude.com/claude-code) and
> [Codex](https://openai.com/codex) sessions in real time.

## Highlights

### 🤖 AI Agents panel
Reads your **local** Claude Code and Codex session logs (read-only, no network) and shows,
for each agent, side by side:

- **Current project** and the **last thing it said** — Markdown tables in the message are
  rendered as real aligned tables, not raw `| … |` text.
- **Plan / step progress** — `步骤 4/6` badge + a segmented progress bar, parsed from
  Codex `update_plan` and Claude `TodoWrite`. Stale plans from a finished turn disappear.
- **Today's token usage** — total + In/Out, in a compact `万 / 亿` format.
- **Codex remaining quota** — % left + reset countdown, tracked across all recent sessions.
- **Live status** — the column **breathes** while an agent is working and **flashes** for
  ~10 s when it finishes a turn or needs your input.

### 🖥️ System panels

The left side now uses a non-equal grid: CPU / GPU / Memory above Network / Custom
Card / Clock + Fan. Time is more prominent, while the Claude and Codex columns are
narrower without removing project, message, step, token, or quota details.

- **CPU** — usage arc gauge, compact per-core P/E bars, temperature (via
  IOHIDEventSystemClient, no sudo), and 1-minute load.
- **GPU** — device, renderer and tiler utilization, temperature and allocated memory.
- **Memory** — pressure-colored usage gauge plus Active/Wired/Compressed/Available details.
- **Network** — live DOWN and UP rates share one row; both rates are also called out
  inside the mirrored 30-second trend graph. Current values and individual history
  bars keep their direction color through 5 MB/s, turn orange above 5 MB/s, and red
  above 10 MB/s.
- **Fans** — built-in fan RPM is integrated into the clock/Bongo Cat card. A compact
  rotor sits inline with its RPM and accelerates with the fan while leaving clear
  space above the cat. A one-fan Mac shows one reading; multi-fan Macs use `×N`;
  `FANLESS` and `N/A` remain distinct.
- **Clock** — large time, plus date, seconds, uptime, and process count.

### 🧩 Custom script card

- Choose a script, card title, and a repeat interval from 5 seconds to 24 hours.
- `.sh`, `.zsh`, and `.command` files run through `/bin/zsh`; other files require
  execute permission and a valid shebang.
- The card displays plain-text stdout/stderr only, capped at 8 KB with ANSI controls removed.
- Runs never overlap and time out automatically. A failure keeps the last successful
  output visible alongside the error state.

### 🐱⚡ Desk pets that react to activity
- A **Bongo Cat** taps its keyboard while your agents work (and dozes when idle).
- A **Pikachu** whose electricity crackles harder as CPU load rises, and who hops and
  turns while an agent is running.

### ⚙️ Under the hood
- **Three performance modes** — Balanced is the always-on default; Eco reduces work
  further, while Smooth trades CPU for more fluid animation. Metric cadence follows the mode.
- **Low-resource rendering** — reuses the 1920×480 raster and preview frame, applies
  brightness through an optimized C lookup table, and throttles status updates and
  local agent-log scans instead of accumulating per-frame work.
- **USB hotplug** — auto-reconnect on plug/unplug and sleep/wake.
- **On-Mac preview** — open it from the menu at any time, or opt into showing it
  automatically while the LCD is disconnected.
- **Menu bar app** — runs in the background with no Dock icon; closing Preview or
  Settings does not quit it.

Performance modes trade animation smoothness and metric freshness for resource use.
The USB output remains 1920×480 in every mode.

| Mode | Active-agent animation | Idle refresh | Best for |
|---|---:|---:|---|
| Eco | up to 2 fps | as slow as 2 s/frame | lowest always-on cost |
| Balanced (default) | up to 4 fps | as slow as 1 s/frame | long-running use |
| Smooth | up to 10 fps | as slow as 0.5 s/frame | smoother pets and rotor |

With the LCD connected on the development Mac, Balanced settled around 47–54 MB
physical memory, 10 threads, and roughly 8% CPU while an agent was active. Hardware,
log size, and telemetry availability affect the result.

### 🕘 Menu bar, login launch, and daily scheduling

- Pause/resume LCD output, reconnect, preview, and open Settings from the menu bar.
- Uses macOS `SMAppService` for Launch at Login—no hand-written LaunchAgent.
- A daily schedule can pause output at one time and resume at another, including
  overnight active windows.
- The close action can instead quit MacTR. A terminated app cannot start itself at the
  resume time; reopen it manually or use Launch at Login.
- Brightness, rotation, refresh interval, preview behavior, and schedule settings persist.

<table>
  <tr>
    <td width="36%"><img src="img/menu-bar-v1.4.1.png" alt="MacTR native menu-bar controls"></td>
    <td width="64%"><img src="img/settings-v1.4.1.png" alt="MacTR settings and custom card"></td>
  </tr>
</table>

<sub>The menu image is captured from the running native `NSMenu`; the Settings image
is the real SwiftUI interface from the same build.</sub>

## Distribution

This repository **does not provide prebuilt apps, DMGs, or ZIPs anymore**. GitHub
Releases retain version history and GitHub-generated source archives only; those
`Source code` archives are not executable applications.

The current UI contains decorative third-party Bongo Cat and Pikachu artwork whose
copyright is not owned by this project. The source remains available for study and
personal builds, but do not redistribute a build containing those assets. Replace or
remove them and review the relevant rights before any public distribution.

## Hardware

| | |
|---|---|
| **Product** | [Thermalright Trofeo Vision 9.16 LCD](https://www.thermalright.com/product/trofeo-vision-9-16-lcd-black/) |
| **Display** | 9.16" IPS, 1920 × 480 |
| **Connection** | USB Type-C (USB 2.0) |
| **Device** | `0416:5408` (LY Bulk protocol) |

## Runtime requirements

- Apple Silicon Mac (M1–M5)
- macOS 15 (Sequoia) or newer
- Thermalright Trofeo Vision 9.16 LCD (the manual Preview still works without hardware)

## Build a standalone app from source

These steps create a self-contained app, DMG, and ZIP that can be copied to another
Apple Silicon Mac. The resulting app bundles libusb, so the target Mac does not need
Homebrew, Swift, or Xcode.

### 1. Prepare the build Mac

- Apple Silicon Mac running macOS 15 or newer.
- Xcode or Command Line Tools with Swift 6.1 support (Xcode 16.3 or newer is
  recommended). If you use Command Line Tools only, verify that `swift`, `xcrun`,
  `clang`, `make`, `codesign`, `hdiutil`, and `iconutil` are available.
- `pkg-config` from [Homebrew](https://brew.sh/). The packaging script downloads and
  builds pinned libusb 1.0.30 itself; Homebrew libusb is not a runtime dependency.

```bash
xcode-select --install                 # macOS reports if it is already installed
brew install pkg-config

swift --version
xcrun --sdk macosx --show-sdk-path
pkg-config --version
```

### 2. Get the source

```bash
git clone https://github.com/luckykong/mac-thermalright-ai-monitor.git
cd mac-thermalright-ai-monitor
git checkout main
```

### 3. Build the standalone packages

```bash
chmod +x packaging/build-release.sh
./packaging/build-release.sh
```

The script:

1. Downloads libusb 1.0.30 source and verifies its pinned SHA-256.
2. Builds libusb and MacTR for arm64 with macOS 15 as the deployment target.
3. Creates `MacTR.app` with bundled libusb and license files.
4. Removes Homebrew, SwiftPM cache, and development-machine absolute dependencies.
5. Ad-hoc signs the app and creates a DMG, ZIP, and checksum file.

Main outputs:

```text
.build/release-package/MacTR.app
dist/v1.4.1/MacTR-v1.4.1-macos-arm64.dmg
dist/v1.4.1/MacTR-v1.4.1-macos-arm64.zip
dist/v1.4.1/SHA256SUMS.txt
```

### 4. Verify the packages

```bash
codesign --verify --deep --strict --verbose=2 \
  .build/release-package/MacTR.app

otool -L .build/release-package/MacTR.app/Contents/MacOS/MacTR

cd dist/v1.4.1
shasum -a 256 -c SHA256SUMS.txt
hdiutil verify MacTR-v1.4.1-macos-arm64.dmg
```

`otool -L` should not show `/opt/homebrew`, `.build`, or an absolute development-machine
path.

### 5. First launch on another Mac

Open the DMG and drag `MacTR.app` to Applications, or unzip the ZIP and move the app.
The local build is ad-hoc signed, not Developer ID notarized. On first launch,
Control-click or right-click the app, choose **Open**, and confirm once. Do not disable
Gatekeeper globally.

### Quick development build

For local development only, without a standalone app:

```bash
brew install libusb pkg-config
swift build -c release
.build/release/MacTR --preview
```

This quick build may depend on `/opt/homebrew` and should not be copied to another Mac.
Use `packaging/build-release.sh` for a transferable private build.

## Modes

```bash
.build/release/MacTR                 # menu-bar app (LCD, or quiet background mode without it)
.build/release/MacTR --preview       # force the on-Mac preview window
.build/release/MacTR --demo          # drive the LCD with the built-in showcase dataset
.build/release/MacTR --snapshot x.png --cores 10   # render one demo frame to a PNG
.build/release/MacTR --snapshot x.png --redact-agents   # real metrics + redacted session text
.build/release/MacTR --gif x.gif --frames 48 --fps 12 --scale 2   # animated demo GIF
.build/release/MacTR --benchmark 120 # measure achievable LCD frame rate
.build/release/MacTR --smc-test      # diagnose built-in fan access
```

Only one process can hold the USB device at a time — stop the running instance before
using `--demo` / `--benchmark`.

## How agent data is read

MacTR never talks to any network or API. It only reads local session transcripts that the
CLIs already write to disk:

| Agent | Source | What's parsed |
|---|---|---|
| Claude Code | `~/.claude/projects/*/*.jsonl` | assistant messages, `usage` tokens, `TodoWrite` |
| Codex | `~/.codex/sessions/YYYY/MM/DD/*.jsonl` | agent messages, `token_count`, `rate_limits`, `update_plan` |

Token totals are scoped to the local day; the panel gracefully shows the last session's
context when an agent hasn't run yet today.

## Privacy

Metrics and agent transcripts stay local and read-only. There is no telemetry and nothing
is uploaded. “View Latest Release” only opens this repository’s Releases page in your
default browser when you choose it.

## Credits

- [beret21/MacTR](https://github.com/beret21/MacTR) — the original macOS driver this is built on
- [thermalright-trcc-linux](https://github.com/Lexonight1/thermalright-trcc-linux) — LY Bulk protocol reverse engineering
- [fermion-star/apple_sensors](https://github.com/fermion-star/apple_sensors) — IOHIDEventSystemClient temperature reading
- [kuroni/bongocat-osu](https://github.com/kuroni/bongocat-osu) — Bongo Cat sprite
- Pikachu artwork via [PokeAPI/sprites](https://github.com/PokeAPI/sprites) — Pokémon is © Nintendo / Creatures / GAME FREAK; included here as a cosmetic homage only

> The Bongo Cat and Pikachu are purely decorative. If you redistribute builds, note that
> their artwork belongs to the respective owners — swap or remove the embedded
> `BongoCatAsset.swift` / `PikachuAsset.swift` if that matters for your use.

## License

MacTR is available under the [MIT License](LICENSE). Local packaged builds dynamically link
libusb 1.0.30 (LGPL-2.1-or-later); its complete license and source information are bundled
inside the app. Third-party artwork remains under its own terms.

---

Built with Swift + libusb. Developed with [Claude Code](https://claude.com/claude-code).
