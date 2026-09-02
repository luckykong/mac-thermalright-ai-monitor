# MacTR v1.4.6

> **Source-only distribution notice:** Prebuilt DMG, ZIP, and checksum attachments are
> not provided. This release offers GitHub-generated source archives only, because the
> UI contains third-party decorative artwork. Build locally for personal use by
> following the README; replace or remove those assets before any public
> redistribution.

1.4.5 was prepared on 2026-07-30 but never tagged or released, so this is the first
release since v1.4.4 and carries both sets of changes. The headline is that MacTR no
longer gets slower the longer it runs.

## Why

A copy that had been up for 2 days 17 hours was at roughly 30% CPU (45% instantaneous)
and 800 MB. `heap` on the live process explained it:

| Object | Count |
|---|---|
| `SwiftUI.TagIndexProjection<SettingsTab>` | 81,302 |
| tab labels / tab images | 325,199 / 325,213 (= 81,302 × 4) |
| observation registrar state | 162,606 (= 81,302 × 2) |
| `NSHostingView<SettingsView>` | **1** |

One settings window — opened once, closed days earlier, but retained — had its
`TabView` rebuilt about once a second, and AppKit's tab implementation leaked a set of
tab items each time. The tick reached the TabView because the Device tab read the frame
counter from a computed property on `SettingsView` itself, so Observation invalidated the
whole body. The window kept doing this off-screen because closing only hid it.

## Highlights

- **The settings window no longer leaks or runs hidden.** Every tab is its own view, so
  the once-a-second status update re-evaluates the Device tab's form alone, and closing
  the settings or schedule window releases it. Measured with the window open against the
  LCD for 60 s: before, +56 tab-index projections, +224 tab images and +112 observation
  registrars at 13.9% CPU; after, none at 7.3%. After a full open/close cycle nothing of
  the window remains in the heap.
- **The menu-bar icon is redrawn only on a state change** instead of once a second.
- **Codex shows its 5-hour quota window beside the 7-day one**, ordered by each
  window's own length rather than by Codex's `primary`/`secondary` keys, and the 5-hour
  bar stays visible through idle stretches by projecting a stale reading forward at
  zero until Codex next runs.
- **Network speed is right under a VPN/proxy tunnel.** Only physical `en<N>`
  interfaces are summed, so bytes that cross `utun` and are re-emitted on Wi-Fi are
  counted once.
- **Uptime, process count and fan RPM are readable** at 16–17 pt on the 1920×480
  panel.

## Also in this release (prepared as 1.4.5)

- CPU and GPU temperature come from the SMC's die sensors — the hottest one — with
  IOHID as fallback. The old `PMU tdie*` reading understated the peak by up to 37 °C,
  and the hardcoded SMC key lists were largely wrong; keys are enumerated once and
  filtered by prefix instead (112 CPU and 22 GPU sensors on the reference machine).
- Temperature colour bands move to 70/90 °C to match a hottest-core reading.
- The CPU/GPU/Memory gauge rings no longer look frozen: the track is neutral and the
  ring thicker, so a partial sweep reads as one.
- Reading three times as many sensors costs less than before because each key's size
  and type is captured during the one-time scan.

## Fixed

- The daily schedule's executed-boundary set kept every key it had ever inserted; it
  keeps the current day's only.

## Build locally / 本地构建

No executable attachment is available from this Release. Clone the repository and run:

```bash
brew install pkg-config
./packaging/build-release.sh
```

See `README.md` or `README.en.md` for prerequisites, output paths, signature and
dependency checks, and first-launch instructions.

本 Release 不再提供可执行附件。请克隆仓库后按中英文 README 的「从源码打包
独立 App」章节在本机生成私用安装包。

## Notes

- Healthy steady state on the reference machine, LCD connected, `balanced` mode: about
  18% of one core and a 210 MB footprint, flat — all of it the 4 fps frame pipeline.
  `eco` roughly halves it. CPU or memory that climbs with uptime is a bug; please report
  it with `sample <pid> 5` and `heap <pid>` output.
- `--open-settings` opens the settings window at launch, alongside `--open-menu`, so the
  window's steady-state cost can be measured with `heap` and `sample` without driving
  the menu by hand.
- Tests run with `./scripts/test.sh` (60 tests in 9 suites). A bare `swift test` fails without a
  full Xcode install because SwiftPM does not add swift-testing's framework paths.
