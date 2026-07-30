#!/usr/bin/env bash
echo "=== nak key subcommands ==="
"$HOME/bin/nak" key 2>&1 | head -30
echo ""
echo "=== nak key encode help (mnemonic?) ==="
"$HOME/bin/nak" key encode --help 2>&1 | head -20 || true
echo ""
echo "=== python bip_utils ==="
python3 -c 'import bip_utils; print("bip_utils OK", bip_utils.__version__)' 2>&1 || echo "no bip_utils"
echo "=== python mnemonic ==="
python3 -c 'import mnemonic; print("mnemonic OK")' 2>&1 || echo "no mnemonic"
echo "=== python ecdsa/coincurve ==="
python3 -c 'import coincurve; print("coincurve OK")' 2>&1 || echo "no coincurve"
echo "=== node ==="
which node 2>&1 || echo "no node"
echo "=== pip available ==="
python3 -m pip --version 2>&1 || echo "no pip"
