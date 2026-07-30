#!/usr/bin/env bash
# Reads a secret key from the IDKEY env var (nsec1... or 64-hex), prints ONLY
# the PUBLIC pubkey (hex + npub). The secret never touches argv (nak reads stdin).
set -uo pipefail
NAK="$HOME/bin/nak"
if [ -z "${IDKEY:-}" ]; then echo "NOKEY"; exit 1; fi
HEXPUB=$(printf '%s' "$IDKEY" | "$NAK" key public 2>/dev/null | tr -d '[:space:]')
if [ -z "$HEXPUB" ]; then echo "BADKEY"; exit 2; fi
NPUB=$("$NAK" encode npub "$HEXPUB" 2>/dev/null)
echo "HEX=$HEXPUB"
echo "NPUB=$NPUB"
