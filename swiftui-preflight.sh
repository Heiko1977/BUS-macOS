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
require_file "$SOURCE_DIR/Design.swift"
require_file "$SOURCE_DIR/HistoryView.swift"

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

require_text "$SOURCE_DIR/DashboardPresentationStore.swift" \
  'final class DashboardChartStore: ObservableObject' \
  'Der getrennte Diagramm-Datenbereich fehlt.'

require_text "$SOURCE_DIR/DashboardPresentationStore.swift" \
  'timeIntervalSince(lastChartRefresh) >= 5' \
  'Die fünfsekündige Diagrammaktualisierung fehlt.'

if grep -Fq '@Published private(set) var chartHistory' \
  "$SOURCE_DIR/DashboardPresentationStore.swift"; then
  fail 'Live-Dashboard und Diagrammdaten sind noch gekoppelt.'
fi

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

require_file "$SOURCE_DIR/CoreAnimationFlowParticles.swift"
require_text "$SOURCE_DIR/ChargingFlowView.swift" \
  'CoreAnimationFlowParticles(' \
  'Die compositor-gestützte Partikel-Ebene fehlt.'

require_text "$SOURCE_DIR/CoreAnimationFlowParticles.swift" \
  'CAReplicatorLayer()' \
  'Die Core-Animation-Partikelreplikation fehlt.'

if grep -Fq 'TimelineView(' "$SOURCE_DIR/ChargingFlowView.swift"; then
  fail 'Die Flussanimation invalidiert weiterhin SwiftUI pro Frame.'
fi

require_text "$SOURCE_DIR/BUSApp.swift" \
  '.environmentObject(presentation)' \
  'Der Präsentations-Store wird nicht injiziert.'

require_text "$SOURCE_DIR/EnergyMonitor.swift" \
  'label: "de.heikogrosse.bus.sampling"' \
  'Die serielle Hintergrunderfassung fehlt.'

require_text "$SOURCE_DIR/EnergyMonitor.swift" \
  'guard isRunning, !collectionIsInFlight else { return }' \
  'Der Schutz vor überlappenden Messungen fehlt.'

require_text "$SOURCE_DIR/EnergyMonitor.swift" \
  'objectWillChange.send()' \
  'Die atomare Messzyklus-Invalidierung fehlt.'

if grep -Eq '@Published private\(set\) var (session|battery|runtimeStatistics)' \
  "$SOURCE_DIR/EnergyMonitor.swift"; then
  fail 'Hochfrequente Modellwerte verwenden noch direkte @Published-Mutationen.'
fi

require_text "$SOURCE_DIR/EnergyMonitor.swift" \
  'label: "de.heikogrosse.bus.persistence"' \
  'Die Hintergrund-Persistenz fehlt.'

require_text "$SOURCE_DIR/EnergyMonitor.swift" \
  'profileDetection: profileDetection' \
  'Die Profilerkennung wird nicht außerhalb des Main Threads vorbereitet.'

if grep -Fq '@EnvironmentObject private var monitor: EnergyMonitor' \
  "$SOURCE_DIR/RootView.swift"; then
  fail 'RootView beobachtet weiterhin den gesamten EnergyMonitor.'
fi

if grep -Fq '@StateObject private var monitor' "$SOURCE_DIR/BUSApp.swift"; then
  fail 'Die App-Szene beobachtet weiterhin den gesamten EnergyMonitor.'
fi

if grep -Fq '@StateObject private var presentation' \
  "$SOURCE_DIR/BUSApp.swift"; then
  fail 'Die App-Szene beobachtet weiterhin alle Dashboard-Frames.'
fi

require_text "$SOURCE_DIR/ChargingFlowView.swift" \
  'Canvas(rendersAsynchronously: true)' \
  'Der asynchrone Canvas-Renderer fehlt.'

require_text "$SOURCE_DIR/EnergyMonitor.swift" \
  'detectedUsageProfileSnapshot' \
  'Die gecachte Profilerkennung fehlt.'

if sed -n '/struct ActiveProfileCard/,/^}/p' \
  "$SOURCE_DIR/ProfilesView.swift" | grep -Fq 'EnergyMonitor'; then
  fail 'ActiveProfileCard greift noch direkt auf EnergyMonitor zu.'
fi

if grep -Fq '@EnvironmentObject private var monitor' \
  "$SOURCE_DIR/OverviewView.swift"; then
  fail 'Eine Dashboard-Unteransicht abonniert EnergyMonitor direkt.'
fi

require_text "$SOURCE_DIR/OverviewView.swift" \
  'private func chartSamples(' \
  'Das Chart-Downsampling fehlt.'

require_file "$SOURCE_DIR/LightweightCharts.swift"
require_text "$SOURCE_DIR/LightweightCharts.swift" \
  'NSViewRepresentable' \
  'Der layer-gestützte AppKit-Diagrammrenderer fehlt.'

require_text "$SOURCE_DIR/Design.swift" \
  'struct StaticLiquidGlassSurface: View' \
  'Die statische Liquid-Glass-Fläche fehlt.'

require_text "$SOURCE_DIR/Design.swift" \
  'enum DashboardTileLayout' \
  'Die gemeinsamen Dashboard-Kachelmaße fehlen.'

require_text "$SOURCE_DIR/OverviewView.swift" \
  'metricGrid(columns: 2)' \
  'Die breite Übersicht verwendet kein ruhiges 2x2-Kennzahlenraster.'

require_text "$SOURCE_DIR/OverviewView.swift" \
  'DashboardTileLayout.compactBatteryChartHeight' \
  'Die einheitliche Diagrammkartenhöhe fehlt.'

require_text "$SOURCE_DIR/RuntimeViews.swift" \
  'DashboardTileLayout.analysisContentHeight' \
  'Die einheitliche Höhe der Analyse-Karten fehlt.'

if grep -Fq '.ultraThinMaterial' \
  "$SOURCE_DIR/Design.swift" \
  "$SOURCE_DIR/ChargingFlowView.swift"; then
  fail 'Scrollende Dashboard-Flächen verwenden noch teures Live-Material.'
fi

require_text "$SOURCE_DIR/HistoryView.swift" \
  '.allowsHitTesting(false)' \
  'Die rein informative Historie ist noch Teil des Responder-Baums.'

if grep -Fq '.animation(.easeInOut(duration: 0.45), value: score)' \
  "$SOURCE_DIR/Design.swift"; then
  fail 'Der Score-Ring startet weiterhin implizite Compositor-Animationen.'
fi

require_text "$ROOT_DIR/Sources/BUS/PerformanceChartCard.swift" \
  '.allowsHitTesting(false)' \
  'Die Diagrammkarten sind noch Teil des Scroll-Hit-Tests.'

if grep -Fq '.drawingGroup(' \
  "$ROOT_DIR/Sources/BUS/PerformanceChartCard.swift"; then
  fail 'Die teure Diagramm-Offscreen-Rasterisierung ist noch aktiv.'
fi

require_text "$SOURCE_DIR/LightweightCharts.swift" \
  'override func hitTest(_ point: NSPoint) -> NSView? { nil }' \
  'Die AppKit-Diagramme sind noch Teil des Scroll-Hit-Tests.'

if grep -Fq 'Canvas(' "$SOURCE_DIR/LightweightCharts.swift"; then
  fail 'Die Diagramme verwenden noch SwiftUI Canvas.'
fi

if grep -R -nE 'import Charts|LineMark|AreaMark|BarMark|RuleMark' \
  "$SOURCE_DIR" >/dev/null 2>&1; then
  fail 'Der schwere Swift-Charts-Renderer ist noch eingebunden.'
fi

if grep -R -nE 'URLSession|NWConnection|import Network|WKWebView' \
  "$SOURCE_DIR" >/dev/null 2>&1; then
  fail 'Eine unerwünschte Netzwerk-API wurde gefunden.'
fi

if [[ "$ERRORS" -gt 0 ]]; then
  printf '\n❌ Vorabprüfung mit %d Fehler(n) beendet.\n' "$ERRORS" >&2
  exit 1
fi

printf '✅ SwiftUI-, Architektur- und Datenschutz-Vorabprüfung bestanden.\n'
