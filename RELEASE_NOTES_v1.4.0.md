# MacTR v1.4.0

> **Source-only distribution notice (2026-07-27):** Prebuilt DMG, ZIP, and checksum
> attachments have been removed. This release now provides GitHub-generated source
> archives only because the UI contains third-party decorative artwork. Build locally
> for personal use by following the README; replace or remove those assets before any
> public redistribution.

MacTR can be built as a self-contained macOS menu-bar app that runs on the target Mac
without Homebrew, Swift, Xcode, or a separate libusb installation.

## Highlights

- New GPU, live network, and built-in fan monitoring alongside CPU and memory.
- Redesigned 1920×480 layout keeps the full dual-column Claude/Codex agent view.
- Persistent menu-bar settings, native Launch at Login, and quiet background operation.
- Daily pause/resume schedules with overnight ranges and sleep/wake handling.
- Optional scheduled full-app quit, plus immediate pause/resume from the menu.
- Local packaging script for bundled source-built libusb 1.0.30, App icon, DMG, ZIP,
  and SHA-256 checksums.

## 本地构建 / Build locally

**中文**

本 Release 不再提供可执行附件。请克隆仓库后按 `README.md` 的“从源码打包
独立 App”章节在本机生成私用安装包。

**English**

No executable attachment is available from this Release. Follow “Build a standalone
app from source” in `README.en.md` to create a private local package.

## Notes

- Fanless Macs show `FANLESS`; an inaccessible SMC shows `N/A`.
- GPU and SMC telemetry depends on what the current Mac exposes.
- Scheduled auto-resume is available for “Pause display output.” If the close action
  quits MacTR, reopen it manually or use Launch at Login.
- The packaged app is ad-hoc signed and intentionally contains no Sparkle update feed.
