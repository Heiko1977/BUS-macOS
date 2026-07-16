#!/bin/bash
set -u
APP="/Applications/BUS.app"
echo "=== BUS Diagnose ==="
sw_vers
swift --version 2>&1 || true
bash "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/privacy-audit.sh" || true
echo "--- App ---"
ls -la "$APP/Contents" 2>&1 || true
codesign -dv --verbose=4 "$APP" 2>&1 || true
codesign --verify --strict --verbose=4 "$APP" 2>&1 || true
xattr -lr "$APP" 2>/dev/null || true
echo "--- Prozess ---"
pgrep -alf BUS || true
echo "--- Logs ---"
log show --last 10m --style compact --predicate 'process == "BUS" OR eventMessage CONTAINS[c] "Battery Usage Score"' 2>/dev/null | tail -n 150


echo
echo "============================================================"
echo " BUS Hardware Helper"
echo "============================================================"
sudo launchctl print system/de.heikogrosse.bus.hardware 2>&1 \
  | head -80 || true
echo
if [[ -f "/Library/Application Support/BUS/hardware.json" ]]; then
  cat "/Library/Application Support/BUS/hardware.json"
else
  echo "Keine Hardware-Messdatei vorhanden."
fi
