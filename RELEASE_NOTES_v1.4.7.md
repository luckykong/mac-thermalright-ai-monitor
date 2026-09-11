# MacTR v1.4.7

> **Source-only distribution notice:** Prebuilt DMG, ZIP, and checksum attachments are
> not provided. This release offers GitHub-generated source archives only, because the
> UI contains third-party decorative artwork. Build locally for personal use by
> following the README; replace or remove those assets before any public
> redistribution.

One fix: the Codex quota bar shows the real number again, and it shows the windows
your plan actually has.

## Why

The Codex card sat at **5h 100% / 7d 100%** while the account was 38% into its weekly
limit. Two things conspired, both visible in `~/.codex/sessions` on Codex CLI 0.153+:

| session | `limit_id` | `plan_type` | windows |
|---|---|---|---|
| the user's own session, started a week earlier, still active | `codex` | `prolite` | 7d **38%** used, no 5h |
| a guardian subagent started today | `codex_bengalfox` ("GPT-5.3-Codex-Spark") | `null` | 5h **0%**, 7d **0%** |

- Codex now tags every `rate_limits` reading with the pool it describes. The guardian
  subagent draws on a model-specific side pool that reports its own two windows at a
  permanent 0% used. "Newest reading wins" let it displace the account pool.
- Rollouts are filed under the day their session *started*, and the quota scan only
  visited the four most recent day directories — so the week-old rollout holding the
  real reading was never read at all.

## Highlights

- **Only the account pool counts** (`limit_id` `codex`, or no field at all in older
  Codex versions). Side pools are ignored; if a side pool is the only thing on disk the
  bar is blank rather than a confident 100%.
- **Pro shows the weekly window alone.** Plans whose `plan_type` starts with `pro`
  (`pro`, `prolite`) have no 5-hour cap, so any shorter block is dropped for them; `plus`
  keeps 5h and 7d side by side; a reading without a plan name is shown as it is.
- **The scan follows modification time, not directory date**: 45 day directories,
  files modified in the last three days, so a long-running session is found wherever it
  was filed.
- Two end-to-end tests lay out a fake `~/.codex/sessions` tree for both failure modes,
  and five parser tests pin the pool and plan rules.

## Also

- **Command Line Tools for Xcode 27.0** ship the macOS 27 SDK, in which SwiftUI's
  `@State` is a macro implemented by a `SwiftUIMacros` plugin — and ship no such plugin,
  so every SwiftUI file failed with "plugin for module 'SwiftUIMacros' not found".
  `scripts/sdk-env.sh`, sourced by `scripts/test.sh` and the packaging script, builds
  against the newest 26.x SDK still on disk when the plugin is absent. A full Xcode
  install or an explicit `SDKROOT` is left alone. `source scripts/sdk-env.sh` before
  building by hand.

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

- Verified with `--snapshot` against the real session tree: 7d 62% remaining, three
  days to reset, matching the 38% `used_percent` on disk; the 1.4.6 build rendered
  5h 100% / 7d 100% from the same data.
- Tests run with `./scripts/test.sh` (69 tests in 10 suites). A bare `swift test` fails
  without a full Xcode install because SwiftPM does not add swift-testing's framework
  paths.
