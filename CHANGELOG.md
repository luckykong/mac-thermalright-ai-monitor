# Changelog

All notable changes to MacTR are documented here.

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

[1.4.0]: https://github.com/luckykong/mac-thermalright-ai-monitor/releases/tag/v1.4.0
