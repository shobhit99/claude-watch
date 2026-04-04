<p align="center">
  <img src="logo.png" width="140" alt="Claude Logo" />
</p>

<h1 align="center"><strong>Agent Watch</strong></h1>

<p align="center">
  Control Claude Code from your Apple Watch.<br/>
  See terminal output, approve permissions, and send voice commands — all from your wrist.
</p>

https://github.com/user-attachments/assets/5f478c28-2086-4696-9d76-e43dda853201

---

```
                    WCSession
 Apple Watch  <===============>  iPhone  <=======>  Mac
  (SwiftUI)     sendMessage       (Relay)   HTTP    Bridge Server
                transferUserInfo           SSE     (Node.js)
                                                      |
                                            HTTP Hooks | PTY stdin
                                                      v
                                              Claude Code Session
```

## What It Does

- **Live terminal output** on your Apple Watch — see what Claude is doing in real-time
- **Permission prompts** — approve or deny Claude's actions from your wrist (Edit file? Run command?)
- **Dynamic questions** — answer `AskUserQuestion` prompts with all options displayed
- **Voice commands** — dictate commands to Claude via watchOS dictation
- **iPhone companion** — pairing UI, connection status, terminal preview, permission approvals
- **Bridge server** — Node.js server on your Mac that connects Claude Code to the watch via HTTP hooks + SSE
- **Cloudflare Tunnel (可选)** — 支持 Quick Tunnel 随机公网地址，或使用 Token 连接你自己的域名

## Architecture

The system has three components:

### 1. Bridge Server (Mac)
A Node.js HTTP server (`skill/bridge/server.js`) that:
- Receives events from Claude Code via [HTTP hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) (`PostToolUse`, `PermissionRequest`, `Stop`, etc.)
- Streams events to connected clients via Server-Sent Events (SSE)
- Handles pairing with a 6-digit code + session token
- Advertises itself on the local network via Bonjour/mDNS
- 可选启动 Cloudflare Tunnel（Quick / Token）
- Blocks on `PermissionRequest` hooks — waits for watch/phone approval, then returns the decision to Claude Code

### 2. iPhone App
A SwiftUI iOS app that:
- Discovers the bridge via Bonjour (or localhost fallback)
- Pairs using the 6-digit code
- Shows connection status + terminal output
- Displays interactive permission prompts (Yes / Yes all / No)
- Relays events to the Apple Watch via WCSession

### 3. watchOS App
A SwiftUI watchOS app that:
- Connects directly to the bridge over Wi-Fi (Bonjour or manual IP entry)
- Shows live terminal output (Read, Edit, Bash, Grep operations)
- Displays permission prompts with all options as scrollable buttons
- Supports voice command input via watchOS dictation
- Haptic feedback for task completion, approvals, and errors

## Quick Start

### Prerequisites
- macOS with Node.js 18+
- Xcode 16+ with watchOS SDK
- Apple Watch on the same Wi-Fi as your Mac
- Claude Code CLI installed

### Apple Watch Wi-Fi Setup
1. Make sure your Apple Watch is connected to the **same Wi-Fi network** as the Mac running your Claude Code session
2. On your Apple Watch, go to **Settings > Wi-Fi > your network** and turn **Private Wi-Fi Address** to **Off** — this is required for Bonjour/mDNS discovery to work reliably on the local network

### 1. Install the bridge

```bash
cd skill/bridge
npm install
```

可选：自动安装 cloudflared（用于远程 tunnel）

```bash
./skill/setup-cloudflared.sh
```

### 2. Install Claude Code hooks

This configures all Claude Code sessions to stream events to the bridge:

```bash
./skill/setup-hooks.sh
```

To remove hooks later: `./skill/setup-hooks.sh --remove`

### 3. Start the bridge server

```bash
cd skill/bridge
node server.js
```

You'll see:
```
╔═══════════════════════════════════════╗
║        AGENT WATCH BRIDGE             ║
╠═══════════════════════════════════════╣
║  Pairing Code:  648505                ║
║  IP Address:    192.168.1.4           ║
║  Port:          7860                  ║
╚═══════════════════════════════════════╝
```

如果开启 tunnel，还会额外看到类似输出：

```text
Tunnel Mode: quick
Tunnel URL:  https://random-words.trycloudflare.com
```

### 4. Build the iOS + watchOS apps

```bash
cd ios/ClaudeWatch
xcodegen generate    # Generates the .xcodeproj
open ClaudeWatch.xcodeproj
```

In Xcode:
1. Set your **Development Team** on both targets (ClaudeWatch + ClaudeWatchWatch)
2. Select the **ClaudeWatch** scheme for the iPhone, or **ClaudeWatchWatch** for the watch
3. Build and run (Cmd+R)

### 5. Pair

**iPhone:** Enter the 6-digit pairing code from the bridge banner.

**Apple Watch:** The app auto-discovers the bridge via Bonjour. If that fails, enter IP 或完整 endpoint URL（例如 `https://xxx.trycloudflare.com`）。

### 6. Use Claude Code normally

Start any Claude Code session in a terminal. Every tool use (Read, Edit, Bash, Grep) streams to the watch and phone in real-time. Permission prompts appear as interactive cards.

## Project Structure

```
claude-watch/
├── skill/
│   ├── bridge/
│   │   ├── server.js          # Bridge server (HTTP + SSE + Bonjour)
│   │   └── package.json       # Node.js dependencies
│   ├── setup.sh               # Install bridge dependencies
│   ├── setup-hooks.sh         # Install/remove Claude Code hooks
│   └── SKILL.md               # Claude Code skill definition
│
├── ios/ClaudeWatch/
│   ├── project.yml            # XcodeGen project spec
│   │
│   ├── Shared/                # Shared between iOS + watchOS
│   │   ├── Models/
│   │   │   ├── SessionState.swift
│   │   │   ├── TerminalLine.swift
│   │   │   ├── ApprovalRequest.swift
│   │   │   ├── WatchMessage.swift
│   │   │   └── OutputRingBuffer.swift
│   │   ├── Connectivity/
│   │   │   └── WatchSessionManager.swift
│   │   └── Extensions/
│   │       ├── Color+Hex.swift
│   │       └── ClaudeMascot.swift     # Official Claude logo as SwiftUI Shape
│   │
│   ├── ClaudeWatch iOS/       # iPhone app
│   │   ├── App/ClaudeWatchApp.swift
│   │   ├── Views/
│   │   │   ├── PairingView.swift      # 6-digit code entry
│   │   │   ├── ConnectionStatusView.swift  # Terminal + status
│   │   │   └── SettingsView.swift
│   │   ├── Networking/
│   │   │   ├── BonjourDiscovery.swift # LAN bridge discovery
│   │   │   ├── BridgeClient.swift     # HTTP client
│   │   │   └── SSEClient.swift        # Server-Sent Events
│   │   └── Services/
│   │       ├── RelayService.swift     # Coordinates bridge <-> watch
│   │       └── NotificationService.swift
│   │
│   └── ClaudeWatch watchOS/   # Apple Watch app
│       ├── App/ClaudeWatchWatchApp.swift
│       ├── Views/
│       │   ├── OnboardingView.swift   # Pairing (Bonjour + manual IP)
│       │   ├── SessionView.swift      # Terminal output + mic FAB
│       │   ├── ApprovalView.swift     # Dynamic permission prompts
│       │   ├── VoiceInputView.swift   # Dictation input
│       │   └── StatusDashboard.swift
│       ├── Services/
│       │   ├── WatchViewState.swift   # Watch-specific state + SSE
│       │   ├── WatchBridgeClient.swift # Direct HTTP to bridge
│       │   ├── HapticManager.swift
│       │   └── SpeechService.swift
│       └── Complications/
│           └── ComplicationProvider.swift
│
└── .claude/skills/claude-watch/
    └── SKILL.md               # /claude-watch skill for Claude Code
```

## How It Works

### Event Flow (Mac -> Watch)

1. Claude Code runs a tool (e.g., Edit a file)
2. The `PostToolUse` HTTP hook fires, POSTing to the bridge server
3. Bridge pushes the event to all connected SSE clients
4. The watch/phone receives the SSE event and renders it as a terminal line

### Permission Flow (Mac -> Watch -> Mac)

1. Claude Code hits a permission prompt (e.g., "Do you want to edit this file?")
2. The `PermissionRequest` HTTP hook fires — bridge **blocks** the response
3. Bridge pushes a `permission-request` SSE event with the question + options
4. Watch shows the approval sheet with all options as tappable buttons
5. User taps an option — watch sends the decision back to the bridge via HTTP
6. Bridge returns the decision to Claude Code's hook — Claude continues or stops

### AskUserQuestion Flow

Same as permission flow, but the hook data includes `tool_input.questions` with dynamic options (label + description). The watch renders these as a scrollable list matching the terminal's numbered choices.

## Claude Code Hooks

The `setup-hooks.sh` script installs these HTTP hooks globally in `~/.claude/settings.json`:

| Hook Event | Purpose | Blocking? |
|-----------|---------|-----------|
| `PostToolUse` | Capture tool output (file reads, edits, commands) | No (async) |
| `PreToolUse` | Capture tool invocations | No (async) |
| `PermissionRequest` | Forward permission prompts to watch | **Yes** (up to 10 min) |
| `Stop` | Detect when Claude finishes responding | No (async) |
| `PostToolUseFailure` | Capture errors | No (async) |
| `StopFailure` | Capture API errors | No (async) |
| `Notification` | Idle/permission notifications | No (async) |

## Configuration

### Bridge Server

| Env Var | Default | Description |
|---------|---------|-------------|
| `PORT` | 7860 | Starting port (tries 7860-7869) |

### Cloudflare Tunnel 配置（可选）

复制 `skill/bridge/bridge.config.example.json` 为 `skill/bridge/bridge.config.json`，并按需修改：

```json
{
  "tunnel": {
    "enabled": true,
    "mode": "quick",
    "token": "",
    "publicUrl": ""
  }
}
```

- `mode=quick`：自动申请 `trycloudflare.com` 随机地址  
- `mode=token`：使用 `token` 启动命名隧道（自定义域名由 Cloudflare 侧配置）

也可用环境变量/CLI 覆盖：

```bash
CLAUDE_WATCH_TUNNEL_ENABLED=true \
CLAUDE_WATCH_TUNNEL_MODE=quick \
node server.js
```

```bash
node server.js \
  --tunnel-enabled true \
  --tunnel-mode token \
  --cf-token 'YOUR_TUNNEL_TOKEN'
```

### Removing Hooks

```bash
./skill/setup-hooks.sh --remove
```

### Unpairing

- **iPhone:** Settings > Forget Mac
- **Watch:** Restart the app (credentials clear when bridge restarts)

## Requirements

| Component | Minimum Version |
|-----------|----------------|
| macOS | 13.0+ |
| Node.js | 18+ |
| Xcode | 16+ |
| iOS | 17.0 |
| watchOS | 10.0 |
| Claude Code | 2.1+ |

## Troubleshooting

### Watch shows "Bridge not found"
- Ensure `node server.js` is running on your Mac
- Check that your watch is on the same Wi-Fi network
- Use the "Enter IP manually" option with the IP shown in the bridge banner

### Watch shows "unsupported architecture"
- Clean build folder in Xcode (Cmd+Shift+Option+K)
- Select the correct scheme: **ClaudeWatchWatch** (not ClaudeWatch)
- Deploy via paired iPhone destination if direct watch deployment fails

### iPhone shows "Connection failed"
- Check that the bridge is running (`curl http://127.0.0.1:7860/status`)
- The bridge must be on the same LAN as the iPhone

### Permission prompts don't appear on watch
- Verify hooks are installed: check `~/.claude/settings.json` for hook entries
- Check bridge logs for "Hook: PermissionRequest received"
- Ensure the watch is connected to the bridge (green status dot)

### Bridge exits immediately
- The bridge no longer auto-spawns Claude. It waits for events from hooks.
- Start Claude Code in a separate terminal — hooks will forward events automatically.

## License

MIT
