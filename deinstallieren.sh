#!/bin/bash
set -Eeuo pipefail
osascript -e 'tell application "BUS" to quit' >/dev/null 2>&1 || true
pkill -x BUS >/dev/null 2>&1 || true
sudo rm -rf /Applications/BUS.app
echo "✅ BUS wurde deinstalliert. Lokale Messdaten bleiben unter ~/Library/Application Support/BUS erhalten."


echo "▶ BUS Hardware Helper entfernen …"
sudo launchctl bootout system/de.heikogrosse.bus.hardware \
  >/dev/null 2>&1 || true
sudo rm -f /Library/LaunchDaemons/de.heikogrosse.bus.hardware.plist
sudo rm -f /Library/PrivilegedHelperTools/de.heikogrosse.bus.hardware
sudo rm -rf "/Library/Application Support/BUS"
sudo rm -f /Library/Logs/BUSHardwareHelper.log
