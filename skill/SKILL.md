---
name: claude-watch
description: Bridge your Claude Code session to the Agent Watch app on Apple Watch
author: shobhit
version: 0.1.0
---

# Agent Watch Bridge

Starts a local bridge server that connects your active Claude Code session
to the Agent Watch iOS/watchOS app.

## What it does
- Runs a Node.js bridge server on your LAN
- 可选启用 Cloudflare Tunnel（Quick / Token）
- Registers HTTP hooks for real-time event forwarding
- Generates a 6-digit pairing code for the iPhone app
- Enables voice commands from your Apple Watch

## Usage
Run `/claude-watch` to start the bridge.
Enter the pairing code in the Agent Watch iPhone app.

## Setup
The bridge requires Node.js 18+ and the `node-pty` package.
Run the setup script: `cd skill/bridge && npm install`
如需远程连接，可运行：`./skill/setup-cloudflared.sh`
