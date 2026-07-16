#!/bin/bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PATTERN='(^|[^A-Za-z])(URLSession|NWConnection|NWPathMonitor|WebSocket|CFStreamCreatePairWithSocket|import Network|import WebKit|import CFNetwork)'
if grep -RInE "$PATTERN" "$ROOT/Sources/BUS" --include='*.swift' --include='*.m' --include='*.c'; then
  echo "❌ Netzwerkfähiger Quellcode gefunden. BUS wird nicht gebaut."
  exit 1
fi
echo "✅ Datenschutzprüfung bestanden: keine bekannten Netzwerk-APIs im BUS-Quellcode."
