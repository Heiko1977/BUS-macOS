import AppKit
import SwiftUI

@main
struct BUSApp: App {
    @NSApplicationDelegateAdaptor(BUSAppDelegate.self) private var appDelegate
    @StateObject private var localizer = Localizer.shared
    private let monitor = EnergyMonitor.shared
    private let presentation = DashboardPresentationStore.shared
    private let chartPresentation = DashboardChartStore.shared

    var body: some Scene {
        Window(AppMetadata.windowTitle, id: "main") {
            RootView()
                .environmentObject(monitor)
                .environmentObject(localizer)
                .environmentObject(presentation)
                .environmentObject(chartPresentation)
                .localizedEnvironment(localizer)
                .frame(minWidth: 760, minHeight: 620)
        }
        .defaultSize(width: 1280, height: 820)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(monitor)
                .environmentObject(localizer)
                .environmentObject(presentation)
                .environmentObject(chartPresentation)
                .localizedEnvironment(localizer)
        } label: {
            MenuBarStatusLabel()
                .environmentObject(presentation)
        }
        .menuBarExtraStyle(.window)

        Settings {
            BUSSettingsView()
                .environmentObject(monitor)
                .environmentObject(localizer)
                .environmentObject(presentation)
                .environmentObject(chartPresentation)
                .localizedEnvironment(localizer)
                .frame(width: 620)
        }
    }
}

private struct MenuBarStatusLabel: View {
    @EnvironmentObject private var presentation: DashboardPresentationStore
    @AppStorage(MenuBarPreferenceKey.batteryDisplayMode)
    private var batteryDisplayModeRaw =
        MenuBarBatteryDisplayMode.iconWithPercent.rawValue
    @AppStorage(MenuBarPreferenceKey.colorizeBatteryIcon)
    private var colorizeBatteryIcon = true
    @AppStorage(MenuBarPreferenceKey.showRemainingTime)
    private var showRemainingTime = true

    var body: some View {
        let frame = presentation.frame
        let mode = MenuBarBatteryDisplayMode(
            rawValue: batteryDisplayModeRaw
        ) ?? .iconWithPercent
        let remainingText = showRemainingTime
            ? remainingTimeText(for: frame)
            : nil
        let statusImage = MenuBarBatteryImageRenderer.image(
            percent: frame.batteryPercent,
            isCharging: frame.isChargingSession,
            showsLowPowerMode: frame.lowPowerModeIsEnabled,
            isColorized: colorizeBatteryIcon,
            showsPercentInside: mode == .iconWithPercent,
            remainingTimeText: remainingText
        )

        Image(nsImage: statusImage)
            .resizable()
            .interpolation(.high)
            .frame(
                width: statusImage.size.width,
                height: statusImage.size.height
            )
    }

    private func remainingTimeText(
        for frame: DashboardPresentationFrame
    ) -> String? {
        let hours = frame.isChargingSession
            ? frame.estimatedChargeTimeToFullHours
            : frame.currentRemainingRuntimeHours
        guard let hours,
              hours.isFinite,
              hours > 0 else {
            return nil
        }
        let minutes = max(1, Int((hours * 60).rounded()))
        return "\(minutes / 60) h \(minutes % 60) m"
    }
}

private enum MenuBarBatteryImageRenderer {
    static func image(
        percent: Double?,
        isCharging: Bool,
        showsLowPowerMode: Bool,
        isColorized: Bool,
        showsPercentInside: Bool,
        remainingTimeText: String?
    ) -> NSImage {
        let timeAttributes = remainingTimeAttributes()
        let timeWidth = remainingTimeText.map {
            ceil(($0 as NSString).size(withAttributes: timeAttributes).width)
        } ?? 0
        let lowPowerWidth: CGFloat = showsLowPowerMode ? 11 : 0
        let pointSize = NSSize(
            width: 27
                + lowPowerWidth
                + (remainingTimeText == nil ? 0 : 4 + timeWidth),
            height: 16
        )
        let image = NSImage(size: pointSize)
        image.lockFocus()
        defer {
            image.unlockFocus()
            image.isTemplate = false
        }

        NSGraphicsContext.current?.imageInterpolation = .high
        draw(
            in: CGRect(x: 0, y: 0, width: 27, height: 16),
            percent: percent,
            isCharging: isCharging,
            isColorized: isColorized,
            showsPercentInside: showsPercentInside
        )
        var nextX: CGFloat = 27
        if showsLowPowerMode {
            drawLowPowerGlyph(in: CGRect(x: 26, y: 2.2, width: 10, height: 11.6))
            nextX = 37
        }
        if let remainingTimeText {
            remainingTimeText.draw(
                with: CGRect(
                    x: nextX + 4,
                    y: 1.75,
                    width: timeWidth,
                    height: 13
                ),
                options: [.usesLineFragmentOrigin],
                attributes: timeAttributes
            )
        }

        return image
    }

    private static func remainingTimeAttributes()
        -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedDigitSystemFont(
                ofSize: 11,
                weight: .regular
            ),
            .foregroundColor: NSColor.labelColor
        ]
    }

    private static func drawLowPowerGlyph(in rect: CGRect) {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: 9,
            weight: .semibold
        )
        .applying(NSImage.SymbolConfiguration(paletteColors: [.systemGreen]))
        let symbol = NSImage(
            systemSymbolName: "leaf.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration)
        symbol?.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    private static func draw(
        in rect: CGRect,
        percent: Double?,
        isCharging: Bool,
        isColorized: Bool,
        showsPercentInside: Bool
    ) {
        let percentValue = max(0, min(percent ?? 0, 100))
        let color = nsColor(
            percent: percent,
            isCharging: isCharging,
            isColorized: isColorized
        )
        if showsPercentInside {
            let bodyRect = CGRect(
                x: 0.5,
                y: 1.5,
                width: 23.5,
                height: 13
            )
            let capRect = CGRect(
                x: 24.7,
                y: 5.2,
                width: 2.3,
                height: 5.6
            )
            let bodyPath = NSBezierPath(
                roundedRect: bodyRect,
                xRadius: 3.2,
                yRadius: 3.2
            )
            color.withAlphaComponent(0.30).setFill()
            bodyPath.fill()

            if percentValue > 0 {
                let fillRect = CGRect(
                    x: bodyRect.minX,
                    y: bodyRect.minY,
                    width: bodyRect.width
                        * CGFloat(percentValue / 100),
                    height: bodyRect.height
                )
                NSGraphicsContext.saveGraphicsState()
                bodyPath.addClip()
                color.setFill()
                NSBezierPath(rect: fillRect).fill()
                NSGraphicsContext.restoreGraphicsState()
            }

            let capColor = percentValue >= 99
                ? color
                : color.withAlphaComponent(0.30)
            capColor.setFill()
            NSBezierPath(
                roundedRect: capRect,
                xRadius: 1.1,
                yRadius: 1.1
            ).fill()
        } else {
            let symbolName = batterySymbolName(
                percent: percentValue,
                isCharging: isCharging
            )
            let sizeConfiguration = NSImage.SymbolConfiguration(
                pointSize: 14,
                weight: .regular
            )
            let colorConfiguration = NSImage.SymbolConfiguration(
                paletteColors: [color]
            )
            let configuration = sizeConfiguration.applying(colorConfiguration)
            let symbol = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: nil
            )?.withSymbolConfiguration(configuration)
                ?? NSImage(
                    systemSymbolName: "battery.0percent",
                    accessibilityDescription: nil
                )?.withSymbolConfiguration(configuration)

            symbol?.draw(
                in: rect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
        }

        if showsPercentInside,
           let percent {
            let text = "\(Int(percent.rounded()))"
            // At low charge the coloured fill is deliberately vivid.
            // Keep the number white instead of cutting it out, otherwise it
            // inherits the yellow/red fill and becomes hard to read.
            let usesWhitePercentText = isCharging
                || (isColorized && percent <= 25)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: percent >= 100 ? 7.4 : 10.4,
                    weight: .semibold
                ),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph
            ]
            let textHeight = ceil((text as NSString).size(withAttributes: attributes).height)
            let textRect = CGRect(
                x: 0.5,
                y: 8 - textHeight / 2 + 0.25,
                width: isCharging ? 17.5 : 23.5,
                height: textHeight
            )
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = usesWhitePercentText
                ? .sourceOver
                : .destinationOut
            text.draw(
                with: textRect,
                options: [.usesLineFragmentOrigin],
                attributes: attributes
            )
            if isCharging {
                let boltPath = NSBezierPath()
                boltPath.move(to: CGPoint(x: 20.6, y: 13.2))
                boltPath.line(to: CGPoint(x: 16.9, y: 8.1))
                boltPath.line(to: CGPoint(x: 19.4, y: 8.1))
                boltPath.line(to: CGPoint(x: 18.0, y: 2.9))
                boltPath.line(to: CGPoint(x: 23.0, y: 9.5))
                boltPath.line(to: CGPoint(x: 20.4, y: 9.5))
                boltPath.close()
                NSColor.white.setFill()
                boltPath.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private static func batterySymbolName(
        percent: Double,
        isCharging: Bool
    ) -> String {
        if isCharging {
            return "battery.100percent.bolt"
        }
        switch percent {
        case ..<13:
            return "battery.0percent"
        case ..<38:
            return "battery.25percent"
        case ..<63:
            return "battery.50percent"
        case ..<88:
            return "battery.75percent"
        default:
            return "battery.100percent"
        }
    }

    private static func nsColor(
        percent: Double?,
        isCharging: Bool,
        isColorized: Bool
    ) -> NSColor {
        guard isColorized else {
            return .labelColor
        }
        if isCharging {
            return .systemGreen
        }
        guard let percent else {
            return .secondaryLabelColor
        }
        if percent <= 12 {
            return .systemRed
        }
        if percent <= 25 {
            return .systemYellow
        }
        return .labelColor
    }
}
