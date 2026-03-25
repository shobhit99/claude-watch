#!/bin/bash
set -e
cd "$(dirname "$0")/bridge"
echo "Installing Claude Watch bridge dependencies..."
npm install
echo "Setup complete."
