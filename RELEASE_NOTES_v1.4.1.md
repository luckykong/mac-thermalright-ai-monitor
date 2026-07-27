# MacTR v1.4.1

> **Source-only distribution notice (2026-07-27):** Prebuilt DMG, ZIP, and checksum
> attachments have been removed. This release now provides GitHub-generated source
> archives only because the UI contains third-party decorative artwork. Build locally
> for personal use by following the README; replace or remove those assets before any
> public redistribution.

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

## Build locally / 本地构建

No executable attachment is available from this Release. Clone the repository and run:

```bash
brew install pkg-config
./packaging/build-release.sh
```

See `README.md` or `README.en.md` for prerequisites, output paths, signature and
dependency checks, and first-launch instructions.

本 Release 不再提供可执行附件。请克隆仓库后按中英文 README 的“从源码打包
独立 App”章节在本机生成私用安装包。

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
