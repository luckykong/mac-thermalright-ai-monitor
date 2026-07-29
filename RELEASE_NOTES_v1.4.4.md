# MacTR v1.4.4

> **Source-only distribution notice:** Prebuilt DMG, ZIP, and checksum attachments are
> not provided. This release offers GitHub-generated source archives only, because the
> UI contains third-party decorative artwork. Build locally for personal use by
> following the README; replace or remove those assets before any public
> redistribution.

A single, focused change: you now decide whether prompt-cache reads count toward the
AGENTS card's token totals, and the panel says which accounting it is showing.

## Why

The card folded cache reads into today's input total. In a long agent session those are
the overwhelming majority of it — over 90% in the case that prompted this — so the card
read an order of magnitude larger than the numbers Claude Code and Codex report for
themselves:

| | tokens | shown as |
|---|---|---|
| raw `input_tokens` | 105 | — |
| `cache_creation` | 294,556 | — |
| `cache_read` | 2,477,524 | — |
| `output` | 70,444 | — |
| **total, cache included** | **2,842,629** | 284.3万 |
| **total, cache excluded** | **294,661** | 29.5万 |

Neither figure is wrong. They answer different questions, so it is a setting rather
than a decision baked into the collector.

## Highlights

- **Settings → Display → Agent Token Usage → "Count cached-read tokens"**. Defaults to
  on, which is byte-for-byte the previous behaviour — an upgrade does not silently
  redefine the number you have been watching.
- **The panel states its unit.** With cache reads excluded, a `不含缓存` / `NO CACHE`
  pill appears beside "Tokens Today" in that column's own accent. Only the non-default
  mode is marked, so an unbadged card means exactly what it always did.
- **Toggling is instant.** The collector accumulates the fresh and cached halves
  separately, so the switch lands on the next metrics tick without re-reading a single
  transcript.

## What counts

| | On (default) | Off |
|---|---|---|
| Answers | how many tokens were sent to the model today | how much genuinely new content there was today |
| Claude | `input_tokens + cache_creation + cache_read` | `input_tokens + cache_creation` |
| Codex | `input_tokens + cache_write` | `input_tokens - cached_input + cache_write` |

Cache **writes** count either way — they are content sent for the first time that
merely happens to be retained.

Codex needs the mirror image of Claude's arithmetic: its `input_tokens` already
*contains* `cached_input_tokens`, while Claude's excludes both cache fields.

## Fixed

- The cached-token flag is read once per snapshot rather than per column and per field.
  It is written from the settings thread, so a toggle landing mid-read could produce a
  frame whose badge named a different accounting than the number beside it, or one
  where Claude was badged and Codex was not.

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

- Upgrading changes nothing on screen until you change the setting. The default is the
  1.4.3 accounting.
- Tests run with `./scripts/test.sh`. A bare `swift test` fails without a full Xcode
  install because SwiftPM does not add swift-testing's framework paths.
- `--snapshot` accepts `--no-cached-tokens`, and `--settings-snapshot` accepts
  `--settings-display`, for capturing either accounting and the new settings section.

See `CHANGELOG.md` for the complete list.
