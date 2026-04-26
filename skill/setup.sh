#!/bin/bash
set -e
cd "$(dirname "$0")/bridge"
echo "Installing Agent Watch bridge dependencies..."
npm install
cd ..

if ./setup-cloudflared.sh; then
  echo "cloudflared check complete."
else
  echo "cloudflared auto-install failed. You can install it manually and enable tunnel later."
fi

echo "Setup complete."
