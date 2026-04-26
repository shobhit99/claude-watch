#!/bin/bash
set -euo pipefail

if command -v cloudflared >/dev/null 2>&1; then
  echo "cloudflared is already installed: $(command -v cloudflared)"
  cloudflared --version || true
  exit 0
fi

echo "cloudflared not found, starting installation..."

ARCH="$(uname -m)"
OS="$(uname -s)"
if [ "$OS" != "Darwin" ]; then
  echo "This script currently supports macOS only. Please install cloudflared manually."
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
    echo "Unsupported architecture: $ARCH. Please install cloudflared manually."
    exit 1
    ;;
esac

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Downloading cloudflared: $PKG_URL"
curl -fsSL "$PKG_URL" -o "$TMP_DIR/cloudflared.tgz"
tar -xzf "$TMP_DIR/cloudflared.tgz" -C "$TMP_DIR"

INSTALL_DIR="$HOME/.local/bin"
mkdir -p "$INSTALL_DIR"
cp "$TMP_DIR/cloudflared" "$INSTALL_DIR/cloudflared"
chmod +x "$INSTALL_DIR/cloudflared"

echo "cloudflared installed: $INSTALL_DIR/cloudflared"
echo "Make sure $INSTALL_DIR is in your PATH."
