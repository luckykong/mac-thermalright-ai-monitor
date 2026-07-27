# MacTR v1.4.1

This update makes the 1920×480 layout denser and more useful on a one-fan Mac mini,
adds a scheduled custom-script card, fixes Apple Silicon fan reads, and substantially
reduces the cost of the always-on renderer.

## Highlights

- Large clock with fan RPM and a rotor above Bongo Cat that accelerates with fan speed.
- DOWN and UP speeds on one line, with both values labeled in the mirrored trend graph.
- New custom plain-text card: choose a script, title, and 5-second to 24-hour interval.
- Narrower Claude/Codex columns without losing messages, steps, tokens, or quota.
- Eco / Balanced / Smooth modes and a rewritten memory-safe brightness pipeline.
- Real renderer, native menu-bar, and Settings captures in the documentation.

## Custom script rules

- `.sh`, `.zsh`, and `.command` files run through the system `/bin/zsh`.
- Other files must be executable and contain a valid shebang.
- MacTR passes the selected path directly; it never evaluates a command string.
- Runs use the current user, never overlap, time out automatically, and cap combined
  stdout/stderr at 8 KB. Select only scripts you trust.

## Download / 下载

1. Requires an Apple Silicon Mac running macOS 15 or newer.
2. Download the DMG (recommended), open it, and drag `MacTR.app` to Applications.
3. The community build is ad-hoc signed and not Developer ID notarized. On first launch,
   Control-click or right-click `MacTR.app`, choose **Open**, and confirm once.
4. No Homebrew, Swift, Xcode, or separate libusb installation is required.

中文：下载 DMG 后把 `MacTR.app` 拖入“应用程序”。本版本无 Apple Developer ID
公证，首次启动请右键或按住 Control 点击 App，选择“打开”并确认一次。无需安装
Homebrew、Swift、Xcode 或独立的 libusb。

## Assets

- `MacTR-v1.4.1-macos-arm64.dmg`
- `MacTR-v1.4.1-macos-arm64.zip`
- `SHA256SUMS.txt`

## SHA-256

```text
8e09efe6f0ca25bd40c75c6b9afb94ba3668e87ca68998ee038aedfc862d5c0f  MacTR-v1.4.1-macos-arm64.dmg
82067b2c49ee22ba0b69ea3ad46bf52d33259afe606186f6559a8c2a9bbc8b72  MacTR-v1.4.1-macos-arm64.zip
```

From the directory containing the downloads, verify with:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

## Resource profile

On the connected development Mac, the default Balanced mode settled around 47–54 MB
physical memory, 10 threads, and roughly 8% CPU while an agent was active. Results vary
with hardware and workload. Eco reduces animation and collection cadence further;
Smooth raises the active animation ceiling from 4 to 10 fps.

## Notes

- `FANLESS` means the Mac reports zero built-in fans; `N/A` means SMC telemetry could
  not be accessed.
- GPU, temperature, and SMC details depend on what the current Mac exposes.
- A script runs with the same access as the signed-in user. Select only a trusted path.
- Scheduled auto-resume applies to “Pause display output.” A fully quit app cannot
  restart itself until it is opened manually or launched at the next login.
