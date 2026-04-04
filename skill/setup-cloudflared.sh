#!/bin/bash
set -euo pipefail

if command -v cloudflared >/dev/null 2>&1; then
  echo "cloudflared 已安装：$(command -v cloudflared)"
  cloudflared --version || true
  exit 0
fi

echo "未检测到 cloudflared，开始安装..."

ARCH="$(uname -m)"
OS="$(uname -s)"
if [ "$OS" != "Darwin" ]; then
  echo "当前脚本仅支持 macOS 自动安装，请手动安装 cloudflared。"
  exit 1
fi

case "$ARCH" in
  arm64)
    PKG_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-arm64.tgz"
    ;;
  x86_64)
    PKG_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-amd64.tgz"
    ;;
  *)
    echo "不支持的架构：$ARCH，请手动安装 cloudflared。"
    exit 1
    ;;
esac

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "下载 cloudflared: $PKG_URL"
curl -fsSL "$PKG_URL" -o "$TMP_DIR/cloudflared.tgz"
tar -xzf "$TMP_DIR/cloudflared.tgz" -C "$TMP_DIR"

INSTALL_DIR="$HOME/.local/bin"
mkdir -p "$INSTALL_DIR"
cp "$TMP_DIR/cloudflared" "$INSTALL_DIR/cloudflared"
chmod +x "$INSTALL_DIR/cloudflared"

echo "cloudflared 安装完成：$INSTALL_DIR/cloudflared"
echo "请确保 $INSTALL_DIR 在 PATH 中。"
