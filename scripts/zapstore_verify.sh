#!/usr/bin/env bash
export LD_LIBRARY_PATH="$HOME/sqlite_extract/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
PK=ab6dc1fcd5659b406d3e0512e05e8afde3b9bfc776e0a9657f57eae9ef069a2e
RELAY=wss://relay.zapstore.dev
FMT=/mnt/c/Users/produ/Documents/GitHub/bro_app/scripts/zapstore_fmt.py
for K in 32267 30063 3063 1063; do
  echo "================ kind $K ================"
  "$HOME/bin/nak" req -k "$K" -a "$PK" -l 3 "$RELAY" 2>/dev/null | python3 "$FMT"
done
