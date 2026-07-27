# MacTR v1.4.0

MacTR is now a self-contained macOS menu-bar app: download, move it to Applications,
and run it without Homebrew, Swift, Xcode, or a separate libusb installation.

## Highlights

- New GPU, live network, and built-in fan monitoring alongside CPU and memory.
- Redesigned 1920×480 layout keeps the full dual-column Claude/Codex agent view.
- Persistent menu-bar settings, native Launch at Login, and quiet background operation.
- Daily pause/resume schedules with overnight ranges and sleep/wake handling.
- Optional scheduled full-app quit, plus immediate pause/resume from the menu.
- Bundled source-built libusb 1.0.30, App icon, DMG, ZIP, and SHA-256 checksums.

## 下载 / Install

**中文**

1. Apple Silicon Mac 需运行 macOS 15 或更新版本。
2. 推荐下载 DMG，打开后把 `MacTR.app` 拖入“应用程序”。
3. 本版本没有 Apple Developer ID 公证。首次运行请右键或按住 Control 点击
   `MacTR.app`，选择“打开”并确认；之后可以正常双击启动。
4. App 驻留菜单栏，可在那里设置开机自启、每日关闭/开启时间和关闭动作。

**English**

1. Requires an Apple Silicon Mac running macOS 15 or newer.
2. Download the DMG (recommended), open it, and drag `MacTR.app` to Applications.
3. This build is not Developer ID notarized. On first launch, Control-click or
   right-click the app and choose **Open**; normal double-click launch works afterward.
4. Use the menu-bar display icon for Launch at Login, daily schedule, and output controls.

## Assets

- `MacTR-v1.4.0-macos-arm64.dmg`
- `MacTR-v1.4.0-macos-arm64.zip`
- `SHA256SUMS.txt`

## SHA-256

```text
8ce125659b339745ee8c5fb82ab8f94ff06f98d1e06d22096a3a53faed3a4cb8  MacTR-v1.4.0-macos-arm64.dmg
3f022c2bad0be8338b7a53f1958f1e70d2c2b1739a4a87cc7e67f05110c4afa2  MacTR-v1.4.0-macos-arm64.zip
```

The same values are included in the attached `SHA256SUMS.txt`.

## Notes

- Fanless Macs show `FANLESS`; an inaccessible SMC shows `N/A`.
- GPU and SMC telemetry depends on what the current Mac exposes.
- Scheduled auto-resume is available for “Pause display output.” If the close action
  quits MacTR, reopen it manually or use Launch at Login.
- The packaged app is ad-hoc signed and intentionally contains no Sparkle update feed.
