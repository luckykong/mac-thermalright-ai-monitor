# MacTR —— 利民 LCD 上的 AI Agent & 系统监控

[中文](README.md) · [English](README.en.md)

<p align="center">
  <img src="img/app-icon-v1.4.0.png" width="112" alt="MacTR App 图标">
</p>

把利民 CPU 散热器上的 1920×480 LCD 变成一块实时仪表盘,既显示 Mac 的系统状态,**又能看到你的 AI 编程助手此刻在干什么** —— 全部原生运行于 macOS,无需 Windows。

![真机实拍](img/photo.jpg)

<sub>装在利民 Trofeo Vision 9.16 散热器上的实拍效果。</sub>

![仪表盘](img/dashboard.gif)

<sub>实时演示(假数据)。左侧显示 CPU、GPU、内存、网速与风扇；两个 agent 都在"工作"→ 面板呼吸、Bongo Cat 敲键盘、皮卡丘随 CPU 负载蹦跳放电。</sub>

> 基于 [beret21/MacTR](https://github.com/beret21/MacTR) 改造,核心是一块实时追踪
> [Claude Code](https://claude.com/claude-code) 与 [Codex](https://openai.com/codex)
> 会话的 **AI Agents** 面板。

## 亮点

### 🤖 AI Agents 面板
读取**本地**的 Claude Code 和 Codex 会话日志(只读、不联网),左右并排显示每个 agent 的:

- **当前项目**和**它最后说的话** —— 消息里的 Markdown 表格会被渲染成对齐的表格,而不是原始的 `| … |` 文本。
- **计划 / 步骤进度** —— `步骤 4/6` 徽章 + 分段进度条,从 Codex 的 `update_plan` 和 Claude 的 `TodoWrite` 解析而来。上一轮已完成的旧计划会自动消失。
- **今日 Token 用量** —— 总量 + In/Out,用简洁的 `万 / 亿` 格式。
- **Codex 剩余额度** —— 剩余百分比 + 重置倒计时,跨所有近期会话取最新读数。
- **实时状态** —— agent 工作时该栏**缓慢呼吸**,完成一轮或需要你输入时**闪烁**约 10 秒提醒。

### 🖥️ 系统面板
- **CPU** —— 占用率环形表、紧凑每核 P/E 柱状条、温度(经 IOHIDEventSystemClient,无需 sudo)、1 分钟负载。
- **GPU** —— 设备、Renderer 与 Tiler 利用率、温度和显存占用。
- **内存** —— 按内存压力着色的占用环，以及 Active/Wired/Compressed/Available 明细。
- **网速** —— 所有非回环接口的实时下载/上传速度与 30 秒趋势图。
- **风扇** —— Mac 内置风扇的实时 RPM 和最高转速占比；无风扇机型与 SMC 不可用会分别显示。
- 底部系统卡同时保留日期、时钟、开机时长和进程数。

### 🐱⚡ 会互动的桌宠
- **Bongo Cat**:agent 工作时在键盘上啪嗒啪嗒敲字,空闲时打盹。
- **皮卡丘**:CPU 负载越高电弧越猛;agent 运行时它还会蹦跳、左右转身。

### ⚙️ 底层
- **自适应帧率** —— 只有在有动画时(agent 工作、CPU 高负载)LCD 才跑约 15fps,其余时间降到 2fps 省电。
- **USB 热插拔** —— 插拔、睡眠/唤醒后自动重连。
- **本机预览** —— 可随时从菜单栏打开；也可选择在 LCD 断开时自动显示。
- **菜单栏应用** —— 后台运行、无 Dock 图标，关闭预览和设置窗口不会退出。

### 🕘 菜单栏、开机自启与定时

- 在菜单栏直接暂停/恢复 LCD、重连设备、打开预览和设置。
- 使用 macOS 原生 `SMAppService` 设置登录时自动启动，无需手写 LaunchAgent。
- 每日计划可在指定时间暂停 LCD，并在另一时间自动恢复；支持跨午夜时段。
- 关闭动作也可以选择“退出整个 App”。退出后进程无法自行定时恢复，只能手动启动或等待下次登录自启。
- 亮度、旋转、刷新率、预览行为和定时设置都会持久保存。

<table>
  <tr>
    <td width="36%"><img src="img/menu-bar-v1.4.0.png" alt="MacTR 菜单栏控制"></td>
    <td width="64%"><img src="img/settings-v1.4.0.png" alt="MacTR 设置与每日计划"></td>
  </tr>
</table>

## 下载与安装

从 [GitHub Releases](https://github.com/luckykong/mac-thermalright-ai-monitor/releases/tag/v1.4.0)
下载以下任一文件：

- `MacTR-v1.4.0-macos-arm64.dmg` —— 推荐，打开后拖入“应用程序”。
- `MacTR-v1.4.0-macos-arm64.zip` —— 解压后把 `MacTR.app` 放入“应用程序”。

发布包已内置 libusb，普通用户**不需要 Homebrew、Swift、Xcode 或其他程序**。

> 当前发布采用 ad-hoc 签名，没有 Apple Developer ID，无法完成 Apple 公证。
> 第一次运行请按住 Control 点击或右键点击 `MacTR.app`，选择“打开”，再确认一次；
> 此后可以正常双击启动。不要用关闭 Gatekeeper 的命令。

## 硬件

| | |
|---|---|
| **产品** | [利民 Trofeo Vision 9.16 LCD](https://www.thermalright.com/product/trofeo-vision-9-16-lcd-black/) |
| **屏幕** | 9.16" IPS,1920 × 480 |
| **接口** | USB Type-C(USB 2.0) |
| **设备** | `0416:5408`(LY Bulk 协议) |

## 运行要求

- Apple Silicon Mac(M1–M5)
- macOS 15(Sequoia)或更新
- 利民 Trofeo Vision 9.16 LCD（不连接硬件时仍可手动打开本机预览）

## 从源码构建

只有开发者从源码构建时才需要 Swift 工具链、pkg-config 和 libusb：

```bash
brew install libusb pkg-config

git clone https://github.com/luckykong/mac-thermalright-ai-monitor.git
cd mac-thermalright-ai-monitor
swift build -c release

.build/release/MacTR          # 菜单栏应用；没接 LCD 时保持后台，可手动开预览
```

> 如果系统的 Command Line Tools 损坏、`swift build` 在解析包清单时报错,
> 装 Homebrew 的 Swift 工具链(`brew install swift`),改用
> `/opt/homebrew/opt/swift/bin/swift build -c release`。

```bash
./packaging/build-release.sh
```

该脚本会校验并从源码构建固定版本的 libusb 1.0.30，生成自包含 App、
ad-hoc 签名、DMG、ZIP 和 `SHA256SUMS.txt`，输出到 `dist/v1.4.0/`。

## 运行模式

```bash
.build/release/MacTR                 # 菜单栏应用(有 LCD 走 LCD,没有则安静驻留后台)
.build/release/MacTR --preview       # 强制打开本机预览窗口
.build/release/MacTR --demo          # 用精美假数据驱动 LCD(方便拍照 / 展示)
.build/release/MacTR --snapshot x.png --cores 10        # 渲染一帧假数据到 PNG
.build/release/MacTR --gif x.gif --frames 48 --fps 12 --scale 2   # 生成演示 GIF
.build/release/MacTR --benchmark 120 # 测量 LCD 可达帧率
```

同一时刻只能有一个进程占用 USB 设备 —— 用 `--demo` / `--benchmark` 前先停掉正在运行的实例。

## Agent 数据怎么读取

MacTR 从不访问任何网络或 API,只读取这些 CLI 本来就写到本地磁盘的会话记录:

| Agent | 来源 | 解析内容 |
|---|---|---|
| Claude Code | `~/.claude/projects/*/*.jsonl` | 助手消息、`usage` token、`TodoWrite` |
| Codex | `~/.codex/sessions/YYYY/MM/DD/*.jsonl` | agent 消息、`token_count`、`rate_limits`、`update_plan` |

Token 总量按本地自然日统计;某个 agent 今天还没跑过时,面板会优雅地显示它上一次会话的上下文。

## 隐私

指标与 Agent 会话读取全部在本地、只读。无遥测，也不会上传任何数据；
“查看最新版本”只会按你的操作在默认浏览器中打开本仓库 Releases 页面。

## 致谢

- [beret21/MacTR](https://github.com/beret21/MacTR) —— 本项目所基于的原版 macOS 驱动
- [thermalright-trcc-linux](https://github.com/Lexonight1/thermalright-trcc-linux) —— LY Bulk 协议逆向
- [fermion-star/apple_sensors](https://github.com/fermion-star/apple_sensors) —— IOHIDEventSystemClient 温度读取
- [kuroni/bongocat-osu](https://github.com/kuroni/bongocat-osu) —— Bongo Cat 精灵图
- 皮卡丘立绘来自 [PokeAPI/sprites](https://github.com/PokeAPI/sprites) —— 宝可梦版权归 © 任天堂 / Creatures / GAME FREAK 所有,此处仅作装饰性致敬

> Bongo Cat 与皮卡丘纯属装饰。若你要分发构建产物,请注意它们的美术版权归各自所有者;
> 需要的话可替换或删除内嵌的 `BongoCatAsset.swift` / `PikachuAsset.swift`。

## 许可证

MacTR 使用 [MIT License](LICENSE)。发布包动态链接 libusb 1.0.30
（LGPL-2.1-or-later），完整许可和来源信息已包含在 App 内。
第三方素材各自遵循其自身条款。

---

用 Swift + libusb 构建。与 [Claude Code](https://claude.com/claude-code) 协作开发。
