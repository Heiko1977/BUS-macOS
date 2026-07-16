#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$ROOT_DIR/Sources/BUS"
ERRORS=0

fail() {
  printf '❌ %s\n' "$1" >&2
  ERRORS=$((ERRORS + 1))
}

require_file() {
  [[ -f "$1" ]] || fail "Datei fehlt: $1"
}

require_text() {
  local file="$1"
  local text="$2"
  local message="$3"
  grep -Fq "$text" "$file" || fail "$message"
}

require_file "$ROOT_DIR/Package.swift"
require_file "$SOURCE_DIR/EnergyMonitor.swift"
require_file "$SOURCE_DIR/DashboardPresentationStore.swift"
require_file "$SOURCE_DIR/OverviewView.swift"
require_file "$SOURCE_DIR/ChargingFlowView.swift"
require_file "$SOURCE_DIR/BUSApp.swift"

PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Info.plist" 2>/dev/null || true)"
PLIST_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT_DIR/Info.plist" 2>/dev/null || true)"
[[ "$PLIST_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
  fail 'CFBundleShortVersionString ist ungültig.'
[[ "$PLIST_BUILD" =~ ^[0-9]+$ ]] || \
  fail 'CFBundleVersion ist ungültig.'

if ! plutil -lint "$ROOT_DIR/Info.plist" >/dev/null 2>&1; then
  fail 'Info.plist ist syntaktisch ungültig.'
fi

require_text "$SOURCE_DIR/DashboardPresentationStore.swift" \
  'struct DashboardPresentationFrame: Equatable' \
  'Der Präsentations-Snapshot fehlt.'

require_text "$SOURCE_DIR/DashboardPresentationStore.swift" \
  '@MainActor' \
  'Die Main-Actor-Isolation des Präsentations-Snapshots fehlt.'

require_text "$SOURCE_DIR/DashboardPresentationStore.swift" \
  '.debounce(for: .milliseconds(20)' \
  'Die ereignisgesteuerte UI-Zusammenfassung fehlt.'

if grep -Fq 'refreshTimer' "$SOURCE_DIR/DashboardPresentationStore.swift"; then
  fail 'Der dauerhafte UI-Polling-Timer ist noch aktiv.'
fi

require_text "$SOURCE_DIR/DashboardPresentationStore.swift" \
  'guard next != frame else { return }' \
  'Unveränderte UI-Snapshots werden nicht unterdrückt.'

require_text "$SOURCE_DIR/OverviewView.swift" \
  'DashboardPresentationStore' \
  'Die Hauptübersicht verwendet den Präsentations-Store nicht.'

require_text "$SOURCE_DIR/ChargingFlowView.swift" \
  'DashboardPresentationStore' \
  'Das Ladedashboard verwendet den Präsentations-Store nicht.'

if grep -Fq 'ScrollPerformanceController' \
  "$SOURCE_DIR/ChargingFlowView.swift" \
  "$SOURCE_DIR/OverviewView.swift" \
  "$SOURCE_DIR/BUSApp.swift"; then
  fail 'Der alte Scroll-Controller ist noch eingebunden.'
fi

if grep -Fq '.drawingGroup(' "$SOURCE_DIR/ChargingFlowView.swift"; then
  fail 'Die teure Rasterisierung ist noch aktiv.'
fi

require_text "$SOURCE_DIR/ChargingFlowView.swift" \
  'private func drawStaticLayer' \
  'Die statische Render-Ebene fehlt.'

require_text "$SOURCE_DIR/ChargingFlowView.swift" \
  'private func drawParticleLayer' \
  'Die getrennte Partikel-Ebene fehlt.'

require_text "$SOURCE_DIR/BUSApp.swift" \
  '.environmentObject(presentation)' \
  'Der Präsentations-Store wird nicht injiziert.'

require_text "$SOURCE_DIR/EnergyMonitor.swift" \
  'label: "de.heikogrosse.bus.sampling"' \
  'Die serielle Hintergrunderfassung fehlt.'

require_text "$SOURCE_DIR/EnergyMonitor.swift" \
  'guard isRunning, !collectionIsInFlight else { return }' \
  'Der Schutz vor überlappenden Messungen fehlt.'

require_text "$SOURCE_DIR/ChargingFlowView.swift" \
  'Canvas(rendersAsynchronously: true)' \
  'Der asynchrone Canvas-Renderer fehlt.'

if grep -R -nE 'URLSession|NWConnection|import Network|WKWebView' \
  "$SOURCE_DIR" >/dev/null 2>&1; then
  fail 'Eine unerwünschte Netzwerk-API wurde gefunden.'
fi

if [[ "$ERRORS" -gt 0 ]]; then
  printf '\n❌ Vorabprüfung mit %d Fehler(n) beendet.\n' "$ERRORS" >&2
  exit 1
fi

printf '✅ SwiftUI-, Architektur- und Datenschutz-Vorabprüfung bestanden.\n'
