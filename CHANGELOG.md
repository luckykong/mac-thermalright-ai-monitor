# Changelog

All notable changes to MacTR are documented here.

## [1.4.5] - 2026-07-30

### Fixed

- The CPU temperature was read from the wrong sensors. It came from IOHID's
  `PMU tdie*`, which is not the hot spot: measured idle versus eight busy
  threads, the SMC's `Tp*` sensors went 65.2 → 111.8 °C while HID reported
  54.1 → 74.4. The peak was understated by up to 37 °C. SMC is now the primary
  source, HID the fallback.
- The SMC key names were hardcoded per chip generation and largely wrong on
  this machine — `Tp01`, `Tp05`, `Tp0D`, `Tp1h`, `Tp0V`, `Te0L`, `Tg0U` and
  `Tg0g` do not exist, while real sensors including `Te04`, `Te06`, `Tex0…3`,
  `Tg04`, `Tg0y` and `Tg1l` were never read. The key table is enumerated once
  and filtered by prefix instead: 112 CPU and 22 GPU sensors here, against
  roughly 21 guessed at with about half absent. No new hardcoded list is needed
  for future silicon.
- CPU and GPU disagreed on how to aggregate — max versus mean — so the two
  numbers on the panel meant different things. Both now report the hottest
  sensor, which also makes an idle core's placeholder reading harmless.
- Temperature colour bands move to 70/90 °C, matched to a hottest-core reading
  and Apple Silicon's ~110 °C throttle point. The old 50/65 split was written
  for a cooler averaged value and would now sit on red permanently.
- The CPU/GPU/Memory gauge rings looked frozen. The sweep was correct all
  along, but the track was drawn in a dark shade of the fill colour, so a
  partial ring read as one solid circle. The track is now neutral — the same
  one the bar gauges use — and the ring is thicker, with the outer edge and
  card layout unchanged.

### Notes

Reading three times as many temperature sensors costs less than the old path,
not more: each key's size and type is captured during the one-time scan so
steady-state reads skip the `kSMCGetKeyInfo` round trip (55.5 → 23.7 ms), and
the sweep is throttled to 4 s. Amortised at the fastest cadence that is 0.67%
of one core, against roughly 0.85% before.

## [1.4.4] - 2026-07-29

### Added

- Settings → Display → Agent Token Usage → "Count cached-read tokens", deciding
  whether the AGENTS card's token totals include context re-read from the prompt
  cache. In a long session cache reads are the overwhelming majority of the
  input side — over 90% in the case that prompted this — so folding them in
  produces a number an order of magnitude larger than the ones Claude Code and
  Codex report for themselves. Neither reading is wrong, so it is now a choice.
  Defaults to on, which is exactly the previous behaviour.

  The collector accumulates the fresh and cached halves separately for both
  agents, so toggling the setting lands on the next metrics tick without
  re-reading a single transcript. Cache *writes* count either way: they are
  content sent for the first time that merely happens to be retained. Codex
  needs the mirror-image arithmetic of Claude's, because its `input_tokens`
  already contains `cached_input_tokens` while Claude's excludes both cache
  fields.
- A `不含缓存` / `NO CACHE` badge beside "Tokens Today" whenever cache reads are
  excluded, drawn in the column's own accent. Both modes otherwise print the
  same label over numbers an order of magnitude apart, which makes the panel
  unreadable without knowing the setting. The default accounting stays
  unmarked, so an unbadged card means what it always did.

## [1.4.3] - 2026-07-28

1.4.2 was prepared but never tagged or released, so its entries below ship here
for the first time. This section covers what came after it.

### Changed

- Halved the renderer's CPU cost by memoizing text measurement and the custom
  card's font-size search. Measuring strings was the dominant cost and nearly
  all of it was repeated work: the dashboard redraws 2-4 times a second while
  its data changes every couple of seconds. The worst offender walked up to
  fourteen candidate font sizes measuring once per character, every frame, for
  text produced by a script on a five-minute timer. Render fell from 11.4 ms to
  6.7 ms per frame and the whole app from roughly 26% to 14% of one core.
- Split `MonitorRenderer`'s 1776 lines by panel region into the class plus four
  extensions. The extracted bodies are byte-identical to the lines they
  replaced.
- `Fonts` no longer caches into an unsynchronised dictionary mutated from
  whichever thread is drawing, and `Fonts.mono` is cached at all — it was not,
  despite being called once per candidate size inside that search.

### Fixed

- Fixed a busy device leaving the engine disconnected indefinitely. A panel
  owned by another process and a panel that is simply absent returned the same
  "nothing to do", but only the absent case is woken by a hotplug event —
  releasing a USB interface announces nothing. Quitting whatever held the panel
  now recovers on the existing 5-60 s backoff instead of waiting for the user to
  replug.
- Stopped logging a custom script's stderr verbatim. It is arbitrary user
  content that routinely carries credentials, and `log` persists at `.notice`
  with public privacy, so splitting stderr away from the card in 1.4.2 kept
  secrets off the LCD only to write them somewhere they lasted longer. Only the
  byte count is logged now; the text reaches an attached terminal and no
  further.
- Fixed a rejected frame being reported as a dead device. `frameTooLarge` shared
  a catch with genuine USB errors, so a local encoding problem closed a healthy
  panel and reconnected into the same oversized frame forever. It could reach
  the wire at all because the encoder's quality ladder returned its lowest rung
  without re-checking the size.
- Finished bounding both agent transcript scans. The Claude cap covered only the
  file reads, leaving the per-file stat and the candidate array unbounded, and
  Codex had no cap at all.
- The handshake now refuses a panel that does not accept JPEG instead of sending
  it anyway, which would paint garbage. This also covers the CLI paths, which
  never checked.
- The frame size limit has a single definition rather than one per file.

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

### Fixed

- Fixed the brightness pass draining colour from the LCD. It scaled each channel
  independently and clipped at 255, so any channel already above 255/factor stopped at
  the ceiling while the darker channels kept climbing — every vivid colour slid toward
  white. At the default factor of 2.2 the accent red (239,68,68) rendered as a washed
  (255,152,128) and Bongo Cat's pink paws became pure white. Gain is now capped per
  pixel so the brightest channel lands exactly on 255, preserving the ratios between
  channels and therefore hue and saturation; dark pixels still get the full factor. The
  preview window never ran this pass, which is why only the panel looked faded.
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
- Made `--cli`, `--demo`, `--benchmark` and the `--cli --test` pattern honour the
  panel's own `needsRotation` instead of assuming every panel needs rotating.
  All of them already performed the handshake and discarded the result, so only
  the menu-bar engine read it. Every profile currently reports `true`, which is
  what the hardcoded behaviour assumed, so this changes nothing on today's
  panels — it removes a divergence that would appear the moment one reports
  `false`. The test pattern also ignored `-b`, and no longer does.
- Bounded the Claude agent scan, which read every session file modified today
  with no upper limit, and moved the quota fetcher's result behind a lock. The
  result was a plain `var` written from the URLSession callback; the semaphore
  already ordered that write before the read, but not in a way the compiler
  could see, so it emitted six concurrency warnings.
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
