# DSH Notch Notifier

A native **macOS menu-bar companion** for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (DSH). It watches DSH's local WebSocket event streams from the menu bar and alerts you when the agent **runs a tool, finishes a task, hits an error, requests approval, asks a question, or completes a background job** — no open browser required, and DSH itself is never modified.

- **No browser dependency** — connects directly to DSH's local event streams; works whether the web UI is open or closed
- **Native app** — single-file Swift + AppKit, compiled with `swiftc`, zero third-party dependencies
- **Zero changes to DSH** — read-only listener; no plugin install, no config changes
- **One-click DSH launch** — after a first successful `npx @deepseek-ai/dsh web` in the terminal, you can start DSH from the menu bar

## Menu bar icon

| Icon | Meaning |
| --- | --- |
| ⚪ white (template) | Disconnected from DSH (auto-reconnecting) |
| 🟢 green dot | Connected, all sessions idle |
| 🔵 blue hammer | At least one session is running |
| 🟠 orange triangle | Needs your attention (approval or question pending) |

## Notifications

| DSH event | You'll see |
| --- | --- |
| Tool call (action executing) | `🛠️ DSH 正在执行动作 — bash · 第1轮/step47: …` |
| Task complete (turn ended) | `✅ DSH 任务完成 — reply summary` |
| Execution error | `❌ DSH 执行出错` |
| Token limit / aborted / blocked | `⚠️ / ⏹️ / 🚧` |
| Approval requested (dangerous command, file deletion…) | `🔔 DSH 需要你批准` |
| Question waiting for your answer | `❓ DSH 在等你回答` |
| Background job finished/failed | `📦 DSH 后台任务完成/失败` |
| Agent crashed | `💥 DSH Agent 错误` |

- Every category can be toggled individually from the menu.
- Tool-call notifications are throttled (max 1 per session per 5 s, default) and are always silent to avoid noise.
- Completion/error/approval/question/job/agent-error notifications play a sound **directly from the app** (`NSSound`), independent of macOS's notification sound channel — it rings even if "Play user interface sound effects" is off. Master sound switch: menu → 通知设置 → 🔊 播放提示音.

## How it works

DSH's web server (default `http://127.0.0.1:3080`) exposes two loopback-only WebSocket event streams (no auth needed):

- `ws://127.0.0.1:3080/api/events.mux` — real-time events from all sessions
- `ws://127.0.0.1:3080/api/events.host` — host-level events (session lifecycle, agent errors)

The app consumes `tool/call`, `turn/end` (with `reason.kind`), `approval/requested`, `question/requested`, `session/jobs`, `host/session-status`, and `host/agent-error`. See `Sources/main.swift` for details.

## Requirements

- macOS 13+
- Xcode Command Line Tools (`xcode-select --install`)
- DSH (already used via `npx @deepseek-ai/dsh web`)

## Install from Releases (recommended for end users)

1. Download `DSHNotch-v0.1.0-macos-arm64.zip` from the [Releases page](https://github.com/lacemou/dsh-macos-notifier/releases)
2. Unzip it, drag `DSHNotch.app` into Applications (or run it directly)
3. First launch may show "cannot verify the developer": **right-click (or Control-click) the app → Open → Open**
4. Or run once in the terminal: `xattr -d com.apple.quarantine "/Applications/DSHNotch.app"`

> ⚠️ This build supports **Apple Silicon (M-series) only**. Intel Mac users should build from source (below).

## Build & run (developers)

```bash
cd dsh-notch-notifier
./build.sh          # produces dist/DSHNotch.app
open dist/DSHNotch.app
```

On first launch the app asks for notification permission: **Allow** uses the system notification banner; without permission it falls back to `osascript` banners automatically. Sound is independent of permission (played directly by the app).

## Quick start

1. **First, run DSH once from the terminal** (required one-time prerequisite):
   ```bash
   npx @deepseek-ai/dsh web
   ```
   This initializes the npx cache and DSH config.
2. Build and launch the app (above). A white `wifi.slash` icon appears in the menu bar while DSH is not running; it turns green when connected.
3. Click the menu bar icon → **测试通知** to verify the notification link (banner + sound).
4. Open 通知设置 and adjust which events should notify you.

## Starting DSH from the app (no terminal)

- DSH not running → menu shows **▶ 启动 DSH**: the app launches `npx @deepseek-ai/dsh web` in the background, waits until the service is ready, then opens the web UI.
- DSH running → the same item shows **打开 DSH 网页** (opens the page directly; it never starts a duplicate instance).
- Launch logs: `~/Library/Logs/DSHNotch-dsh.log`.
- The launch command is configurable in the server dialog (default `npx @deepseek-ai/dsh web`).

## Menu reference

- **▶ 启动 DSH / 打开 DSH 网页** — start or open DSH
- **测试通知** — send a test notification
- **🔍 通知诊断** — read the app's real notification settings from the system (authorization / banner / sound / active channel)
- **重新连接** — reconnect the WebSocket streams
- **通知设置** — checkboxes for every notification category + sound
- **服务器：host:port** — change the DSH address and the launch command
- **最近事件** — last 200 events (full log: `~/Library/Logs/DSHNotch.log`)

## Notification settings (8 switches)

| Switch | Default | Effect |
| --- | --- | --- |
| 🛠️ 执行动作时通知（工具调用） | on | Notify on tool calls (throttled 5 s) |
| ✅ 任务完成时通知 | on | Notify when a turn completes |
| ❌ 出错 / 中止 / 超限时通知 | on | Notify on errors, aborts, token-limit |
| 🔔 需要批准时通知 | on | Notify when approval is requested |
| ❓ 提问等待回答时通知 | on | Notify when a question awaits your answer |
| 📦 后台任务完成/失败时通知 | on | Notify on background job completion/failure |
| 💥 Agent 错误时通知 | on | Notify on agent-level errors |
| 🔊 播放提示音 | on | Master sound switch (app plays it directly) |

## Troubleshooting

- **Icon is ⚪ white**: DSH is not running or the port is wrong → use ▶ 启动 DSH or fix the address in the server dialog.
- **No notifications**: check `~/Library/Logs/DSHNotch.log` for `已连接 /api/events.mux`, then check the relevant switch.
- **No sound**: check 🔊 播放提示音; use 🔍 通知诊断 to see the active channel. Sound is played by the app directly and does not depend on system notification sound settings.
- **Too many notifications**: turn off 执行动作时通知 or raise `toolCallMinInterval` (default 5 s).

## Compatibility & privacy

- Tested against DSH `0.1.0-rc.6`. The event endpoints are internal DSH interfaces; if they change after a DSH upgrade, re-check the endpoint paths.
- The app connects only to the loopback address (default `127.0.0.1:3080`), reads event streams only, and **collects or uploads nothing**. The only files it writes are local logs: `~/Library/Logs/DSHNotch.log` and `~/Library/Logs/DSHNotch-dsh.log`.

## License

MIT
