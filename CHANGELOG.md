# Changelog

All notable changes to MacTR are documented here.

## [1.4.2] - 2026-07-28

### Added

- Added Claude rate-limit windows to the AI Agents panel. The quota bar was never
  Codex-specific in the renderer, but Claude Code persists no rate-limit data on disk,
  so nothing supplied it. MacTR now makes one authenticated request to Anthropic's
  OAuth usage endpoint and shows the 5-hour and 7-day windows side by side. The token
  is read from Claude Code's own keychain item and **never refreshed** — the refresh
  token there is shared with Claude Code and rotating it would sign it out. This is the
  only network request MacTR makes; see the README for how to opt out.
- Enlarged both mascots. Pikachu goes from 49 to 66 pt and Bongo Cat from 0.54 to 0.78
  scale, and image drawing now requests high interpolation quality. At the old size the
  170 px Pikachu sprite lost its red cheeks and black outlines to downscaling and read
  as a pale yellow blob.

### Fixed

- Fixed the quota reset countdown mixing languages: the split two-window layout fell
  back to a bare "3h"/"4d" while Codex showed "5 天后重置" in the same panel.

- Fixed reconnect building an unbounded call stack. `connectAndRun` and
  `runFrameLoop` called each other, so every reconnect cycle pushed two stack
  frames that never unwound; reconnection is now a loop with 5–60 s exponential
  backoff.
- Fixed a data race on the engine's `enabled`/`running` flags, which were plain
  `Bool`s written from the main thread, the USB queue and the IOKit hotplug
  queue. They are atomic now, and the remaining unsynchronised hotplug work
  moved onto the USB queue.
- Fixed a device conflict being reported as `Failed to set configuration
  (code -4)`. On macOS an exclusive-access conflict surfaces at
  `libusb_set_configuration`, not at `libusb_claim_interface`, so the friendly
  "device in use by another application" message was unreachable.
- Fixed `USBHotplug` leaking IOKit notification iterators: both product IDs
  shared one pair of variables, so every registration but the last leaked and
  could not be deregistered.
- Fixed the frame sender advancing its cursor by a fixed 4096 bytes rather than
  the number of bytes actually written, and enforced the previously unused
  650 KB frame limit.
- Fixed `JPEGEncoder`'s `rotate` parameter, whose name, default value and
  documentation all contradicted its `if !rotate { …rotate… }` implementation.
  It is now `rotate180`, and the handshake's `needsRotation` — parsed since
  1.0 but never read — is finally used.
- Fixed custom-card output being contaminated by the script's stderr. The two
  streams shared one pipe, so warnings and exception text (potentially
  including credentials) were rendered on the LCD.
- Fixed the app querying `SMAppService` once per second from a menu-refresh
  timer, even with the menu closed.
- Fixed application logs being unretrievable: they were emitted at `.info`,
  which is not persisted, and `--cli` produced no terminal output at all.
- Fixed `swift test` being unrunnable without a full Xcode install; use
  `./scripts/test.sh`.
- Fixed the version number being duplicated across six locations that had
  drifted apart. `Info.plist` is now the only source.
- Fixed the dot-weather example hardcoding the author's personal paths,
  requiring a separate unpublished project even for `--sample`, falling back to
  an unboundedly stale cache, leaving requests without a timeout, and printing
  API keys into failure messages.

### Added

- Added a persistent runtime language picker for Simplified Chinese and English.
  Simplified Chinese is the first-run default, and both Settings and the menu bar
  can switch the entire app and LCD dashboard without restarting.
- Added localized runtime/device states, daily-schedule descriptions, dashboard
  labels, time units, and language-specific compact token formats.
- Added persistent Auto / Small / Medium / Large custom-card text sizing. Auto
  selects the largest fully fitting font, vertically centers short output, uses
  a large centered treatment for six-digit codes, and safely scales or truncates
  long text.

### Changed

- Moved the animated fan rotor beside the RPM label so it no longer crowds Bongo Cat.
- Added per-sample network rate colors: normal direction colors through 5 MB/s,
  orange above 5 MB/s, and red above 10 MB/s.
- Removed all prebuilt DMG, ZIP, and checksum attachments from public Releases.
  Releases are source-only; the README now documents the complete local standalone
  packaging and verification workflow.

## [1.4.1] - 2026-07-27

### Added

- A reusable custom script card with a user-selected path, title, and 5-second to
  24-hour interval.
- Safe launch rules: shell files run as one `/bin/zsh` path argument; all other
  files require execute permission and a shebang. Output is plain text, capped,
  sanitized, non-overlapping, and time-limited.
- Eco, Balanced, and Smooth performance modes for explicit always-on tradeoffs.
- SMC diagnostics for verifying built-in fan access on a target Mac.

### Changed

- Rebalanced the 1920×480 layout into three compact top system cards and a lower
  Network / Custom / Clock + Fan row.
- Made the clock more prominent and integrated fan RPM plus a speed-reactive rotor
  above Bongo Cat, avoiding a mostly empty one-fan panel on Mac mini.
- Put live DOWN and UP rates on one line and labeled both series inside the network graph.
- Narrowed the Claude and Codex columns while retaining their full content.
- Replaced stale documentation assets with captures from the actual renderer, native
  menu, and settings interface.

### Fixed and optimized

- Corrected the AppleSMC C-ABI structure layout so fan keys read successfully on
  Apple Silicon.
- Replaced the retaining Core Image brightness path with reusable raster storage
  and an optimized C lookup table.
- Reused the frame sent to the LCD for Preview, throttled UI status delivery, reduced
  local transcript scanning, and avoided large tail-file allocations.
- Stopped metrics and USB work while output is paused or an absent LCD has no Preview.

### Packaging

- Standalone Apple Silicon DMG and ZIP remain self-contained with bundled libusb,
  ad-hoc signing, and SHA-256 checksums.

## [1.4.0] - 2026-07-27

### Added

- GPU device, Renderer/Tiler, temperature, and allocated-memory telemetry.
- Aggregate non-loopback download/upload speed with a 30-second trend graph.
- AppleSMC fan discovery with RPM, min/max values, percentage bars, and separate
  `FANLESS` and unavailable states.
- Persistent menu-bar settings for brightness, rotation, refresh interval, and
  disconnected-device preview behavior.
- Native Launch at Login control through `SMAppService`.
- Daily display schedules with calendar-aware pause/resume, overnight windows,
  sleep/wake reconciliation, and an optional quit-at-close action.
- Manual pause/resume state that leaves the scheduler and menu bar running.
- Reproducible App icon, settings/menu documentation renders, and schedule tests.

### Changed

- Reworked the 1920×480 dashboard into a 630 px system area and a 1252 px dual-agent
  area instead of four equal panels.
- CPU, memory, GPU, network, fans, date, time, uptime, and process count now share
  compact named regions while the complete Claude/Codex panels remain intact.
- Closing Preview or Settings now keeps the LSUIElement app running in the menu bar.
- A missing LCD no longer opens Preview automatically unless the user enables it.
- Removed Sparkle and the inherited upstream update feed. The menu now opens this
  repository’s Releases page on request.
- Minimum supported system is macOS 15 on Apple Silicon.

### Packaging

- Added a self-contained `MacTR.app` build with a pinned, source-built libusb 1.0.30
  dynamic library and bundled LGPL notices.
- Added ad-hoc signed DMG and ZIP release artifacts plus SHA-256 checksums.
- Removed Homebrew, SwiftPM cache, and developer-toolchain runtime paths from the
  packaged app.

### Known limitation

- The community release has no Apple Developer ID and cannot be notarized. The first
  launch therefore requires Control-click/right-click → Open.

## [1.3.11] - 2026-07-24

- Matched Finder’s disk capacity accounting by including purgeable space.
- Used memory pressure for memory severity and throttled disk polling.

[1.4.1]: https://github.com/luckykong/mac-thermalright-ai-monitor/releases/tag/v1.4.1
[1.4.0]: https://github.com/luckykong/mac-thermalright-ai-monitor/releases/tag/v1.4.0
