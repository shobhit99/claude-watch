#!/bin/bash
set -e
cd "$(dirname "$0")/bridge"
echo "正在安装 Agent Watch bridge 依赖..."
npm install
cd ..

if ./setup-cloudflared.sh; then
  echo "cloudflared 检查完成。"
else
  echo "cloudflared 自动安装失败，你仍可手动安装后再启用隧道。"
fi

echo "安装完成。"
