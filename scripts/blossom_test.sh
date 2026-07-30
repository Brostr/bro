#!/usr/bin/env bash
# Test which Blossom server accepts a large (~135MB) file using a THROWAWAY key.
# Never uses the real Bro nsec.
set -u

mkdir -p "$HOME/bin"

# 1) Ensure nak is installed
if [ ! -x "$HOME/bin/nak" ]; then
  echo "==> Resolving latest nak linux-amd64 download URL..."
  URL=$(curl -sL https://api.github.com/repos/fiatjaf/nak/releases/latest \
    | grep -oE 'https://[^"]*linux-amd64' | head -1)
  echo "    URL=$URL"
  if [ -z "$URL" ]; then echo "Could not resolve nak URL"; exit 2; fi
  curl -sL "$URL" -o "$HOME/bin/nak"
  chmod +x "$HOME/bin/nak"
fi
"$HOME/bin/nak" --version || { echo "nak not working"; exit 2; }

# 2) Generate a throwaway key
THROW=$("$HOME/bin/nak" key generate)
echo "==> throwaway sec generated (not shown)"

# 3) Create a ~135MB dummy file
DUMMY="$HOME/blossom_dummy.bin"
if [ ! -f "$DUMMY" ] || [ "$(stat -c%s "$DUMMY")" -lt 141557760 ]; then
  echo "==> creating 135MB dummy file..."
  head -c 141557760 /dev/urandom > "$DUMMY"
fi
echo "    dummy size: $(stat -c%s "$DUMMY") bytes"

# 4) Test each candidate server
for SRV in \
  "https://cdn.zapstore.dev" \
  "https://blossom.primal.net" \
  "https://nostr.download" \
  "https://blossom.band" \
  "https://cdn.satellite.earth" \
  "https://blossom.nostr.hu" \
  "https://nostrcheck.me" ; do
  echo ""
  echo "================ $SRV ================"
  OUT=$("$HOME/bin/nak" blossom --server "$SRV" --sec "$THROW" upload "$DUMMY" 2>&1)
  RC=$?
  echo "$OUT" | head -8
  if [ $RC -eq 0 ] && echo "$OUT" | grep -q '"url"'; then
    echo ">>> SUCCESS on $SRV"
  else
    echo ">>> FAIL on $SRV (rc=$RC)"
  fi
done

echo ""
echo "==> done"
