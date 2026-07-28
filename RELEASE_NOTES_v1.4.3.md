# MacTR v1.4.3

> **Source-only distribution notice:** Prebuilt DMG, ZIP, and checksum attachments are
> not provided. This release offers GitHub-generated source archives only, because the
> UI contains third-party decorative artwork. Build locally for personal use by
> following the README; replace or remove those assets before any public
> redistribution.

1.4.2 was prepared but never tagged, so this release carries both. It is the result of
a full architecture review of the codebase, verified against the physical panel
throughout — including a sixteen-cycle unplug/replug regression run.

Two things matter most: the always-on renderer now costs roughly half the CPU it did,
and several reliability defects that could leave the panel dark until you intervened
are gone.

## Highlights

- **Renderer CPU roughly halved.** Text measurement dominated the cost and nearly all
  of it was repeated work. Render fell from 11.4 ms to 6.7 ms per frame, and the whole
  app from about 26% to 14% of one core.
- **Claude rate-limit windows** beside Codex's in the AI Agents panel, showing the
  5-hour and 7-day quotas.
- **Reconnect is dependable.** It no longer grows the call stack, no longer leaks
  IOKit notification iterators, and now recovers on its own when another application
  releases the panel.
- **Colour is no longer washed out on the LCD.** The brightness pass clipped each
  channel independently, so vivid colours slid toward white — visible only on the
  panel, never in the preview window.
- Both mascots are drawn large enough to read, and the app and dashboard switch
  between Simplified Chinese and English at runtime.

## Reliability

- Reconnect used to build an unbounded call stack: `connectAndRun` and `runFrameLoop`
  called each other, so every cycle pushed two frames that never unwound. It is now a
  loop with 5–60 s exponential backoff.
- `USBHotplug` leaked IOKit notification iterators — both product IDs shared one pair
  of variables, so every registration but the last leaked and could not be
  deregistered.
- A device owned by another application left the engine disconnected indefinitely.
  Releasing a USB interface raises no event, so nothing ever woke it. It now retries.
- An exclusive-access conflict reports "device in use by another application" instead
  of `Failed to set configuration (code -4)`. On macOS the conflict surfaces during
  configuration, not interface claim, so the friendly message was unreachable.
- A data race on the engine's `enabled`/`running` flags, written from three different
  queues, is fixed.
- A frame the protocol rejects is no longer mistaken for a dead device.

## Privacy

- A custom script's stderr is no longer written to the system log. It is arbitrary
  content that routinely carries credentials, and the log persists for days. Only its
  size is recorded now.
- Custom-card output no longer carries the script's stderr onto the panel; the two
  streams used to share one pipe.
- The Claude quota request is the only network request MacTR makes. It is documented
  in both READMEs, along with how to opt out. Nothing else leaves the machine.

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

- Tests run with `./scripts/test.sh`. A bare `swift test` fails without a full Xcode
  install because SwiftPM does not add swift-testing's framework paths.
- The Claude quota is read from Claude Code's own keychain item and the token is never
  refreshed — the refresh token is shared with Claude Code, and rotating it would sign
  it out. An expired token simply hides the bars until Claude Code renews it.
- A script runs with the same access as the signed-in user. Select only a trusted path.
- `FANLESS` means the Mac reports zero built-in fans; `N/A` means SMC telemetry could
  not be accessed.

See `CHANGELOG.md` for the complete list.
