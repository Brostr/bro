#!/usr/bin/env bash
set -e
cd "$HOME"
echo "REAL_HOME=$HOME"
echo "WHOAMI=$(whoami)"
mkdir -p "$HOME/bin"
if [ ! -x "$HOME/bin/zapstore" ]; then
  echo "Downloading zapstore-cli 0.2.4 (linux-amd64)..."
  curl -L -o "$HOME/bin/zapstore" \
    https://github.com/zapstore/zapstore-cli/releases/download/0.2.4/zapstore-cli-0.2.4-linux-amd64
  chmod +x "$HOME/bin/zapstore"
fi
echo "=== zapstore --version ==="
"$HOME/bin/zapstore" --version || true
echo "=== zapstore --help ==="
"$HOME/bin/zapstore" --help || true
echo "=== zapstore publish --help ==="
"$HOME/bin/zapstore" publish --help || true
