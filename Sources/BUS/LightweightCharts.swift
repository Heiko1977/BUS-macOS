import AppKit
import SwiftUI

/// Charts are rendered by one layer-backed AppKit view. Unlike SwiftUI Canvas,
/// the finished backing surface is merely moved by NSScrollView and is not
/// rebuilt for display-link or scroll updates.
struct LightweightBatteryChart: View {
    let points: [BatteryHistoryPoint]
    let lowerBound: Double

    var body: some View {
        RasterChartRepresentable(
            points: points,
            domain: lowerBound...100,
            mode: .battery
        )
        .accessibilityLabel("Battery history")
    }
}

struct LightweightPowerChart: View {
    let points: [BatteryHistoryPoint]
    let domain: ClosedRange<Double>

    var body: some View {
        RasterChartRepresentable(
            points: points,
            domain: domain,
            mode: .power
        )
        .accessibilityLabel("Power balance")
    }
}

private enum RasterChartMode: Int {
    case battery
    case power
}

private struct RasterChartRepresentable: NSViewRepresentable {
    let points: [BatteryHistoryPoint]
    let domain: ClosedRange<Double>
    let mode: RasterChartMode

    func makeNSView(context: Context) -> RasterChartNSView {
        let view = RasterChartNSView()
        view.update(points: points, domain: domain, mode: mode)
        return view
    }

    func updateNSView(_ view: RasterChartNSView, context: Context) {
        view.update(points: points, domain: domain, mode: mode)
    }
}

private final class RasterChartNSView: NSView {
    private var points: [BatteryHistoryPoint] = []
    private var domain: ClosedRange<Double> = 0...100
    private var mode: RasterChartMode = .battery
    private var contentSignature = 0
    private var lastDrawnSize = CGSize.zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.drawsAsynchronously = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.drawsAsynchronously = true
        layer?.masksToBounds = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(
        points: [BatteryHistoryPoint],
        domain: ClosedRange<Double>,
        mode: RasterChartMode
    ) {
        let signature = Self.signature(
            points: points,
            domain: domain,
            mode: mode
        )
        guard signature != contentSignature else { return }
        contentSignature = signature
        self.points = points
        self.domain = domain
        self.mode = mode
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(newSize.width - frame.size.width) > 0.5
            || abs(newSize.height - frame.size.height) > 0.5
        super.setFrameSize(newSize)
        if changed { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 100, bounds.height > 80 else { return }
        lastDrawnSize = bounds.size

        let plot = CGRect(
            x: 52,
            y: 12,
            width: max(1, bounds.width - 68),
            height: max(1, bounds.height - 48)
        )
        let background = NSBezierPath(
            roundedRect: plot,
            xRadius: 8,
            yRadius: 8
        )
        NSColor.black.withAlphaComponent(0.035).setFill()
        background.fill()

        drawGrid(in: plot)
        guard points.count > 1 else { return }
        switch mode {
        case .battery:
            drawBattery(in: plot)
        case .power:
            drawPower(in: plot)
        }
        drawTimeLabels(in: plot)
    }

    private func drawGrid(in plot: CGRect) {
        let count = mode == .battery ? 4 : 6
        for index in 0...count {
            let fraction = Double(index) / Double(count)
            let y = plot.maxY - plot.height * fraction
            let value = domain.lowerBound
                + (domain.upperBound - domain.lowerBound) * fraction
            let isZero = mode == .power && abs(value) < 0.001

            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: y))
            line.line(to: NSPoint(x: plot.maxX, y: y))
            line.lineWidth = isZero ? 1.2 : 0.6
            NSColor.secondaryLabelColor
                .withAlphaComponent(isZero ? 0.55 : 0.18)
                .setStroke()
            line.stroke()

            drawLabel(
                mode == .battery
                    ? String(format: "%.0f", value)
                    : String(format: "%.0f W", value),
                at: CGPoint(x: plot.minX - 8, y: y),
                alignment: .right
            )
        }
    }

    private func drawBattery(in plot: CGRect) {
        let mapped = points.map { chartPoint($0.percent, date: $0.date, plot: plot) }
        guard let first = mapped.first, let last = mapped.last else { return }
        let line = path(points: mapped)
        let area = line.copy() as! NSBezierPath
        area.line(to: NSPoint(x: last.x, y: plot.maxY))
        area.line(to: NSPoint(x: first.x, y: plot.maxY))
        area.close()
        NSColor.systemGreen.withAlphaComponent(0.16).setFill()
        area.fill()
        NSColor.systemGreen.setStroke()
        line.lineWidth = 2.2
        line.stroke()
    }

    private func drawPower(in plot: CGRect) {
        drawPowerRuns(in: plot, positive: true)
        drawPowerRuns(in: plot, positive: false)
    }

    private func drawPowerRuns(in plot: CGRect, positive: Bool) {
        let color = positive ? NSColor.systemOrange : NSColor.systemGreen
        let zeroY = yPosition(0, plot: plot)
        var run: [CGPoint] = []

        func render(_ values: [CGPoint]) {
            guard values.count > 1,
                  let first = values.first,
                  let last = values.last else { return }
            let line = path(points: values)
            let area = line.copy() as! NSBezierPath
            area.line(to: NSPoint(x: last.x, y: zeroY))
            area.line(to: NSPoint(x: first.x, y: zeroY))
            area.close()
            color.withAlphaComponent(0.16).setFill()
            area.fill()
            color.setStroke()
            line.lineWidth = 2.1
            line.stroke()
        }

        for item in points {
            guard let watts = signedPower(item) else {
                render(run)
                run.removeAll(keepingCapacity: true)
                continue
            }
            let included = positive ? watts >= 0 : watts < 0
            if included {
                run.append(chartPoint(watts, date: item.date, plot: plot))
            } else {
                render(run)
                run.removeAll(keepingCapacity: true)
            }
        }
        render(run)
    }

    private func drawTimeLabels(in plot: CGRect) {
        guard let start = points.first?.date,
              let end = points.last?.date else { return }
        for index in 0...4 {
            let fraction = Double(index) / 4
            let date = start.addingTimeInterval(
                end.timeIntervalSince(start) * fraction
            )
            drawLabel(
                Self.timeFormatter.string(from: date),
                at: CGPoint(
                    x: plot.minX + plot.width * fraction,
                    y: plot.maxY + 22
                ),
                alignment: .center
            )
        }
    }

    private func drawLabel(
        _ string: String,
        at point: CGPoint,
        alignment: NSTextAlignment
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        let measuredWidth = max(48, ceil((string as NSString).size(withAttributes: [.font: font]).width) + 4)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]
        let width: CGFloat = min(78, measuredWidth)
        let x: CGFloat
        switch alignment {
        case .right: x = point.x - width
        case .center: x = point.x - width / 2
        default: x = point.x
        }
        NSString(string: string).draw(
            in: CGRect(x: x, y: point.y - 6, width: width, height: 13),
            withAttributes: attributes
        )
    }

    private func path(points: [CGPoint]) -> NSBezierPath {
        let result = NSBezierPath()
        guard let first = points.first else { return result }
        result.move(to: first)
        for point in points.dropFirst() { result.line(to: point) }
        return result
    }

    private func chartPoint(
        _ value: Double,
        date: Date,
        plot: CGRect
    ) -> CGPoint {
        let start = points.first?.date.timeIntervalSinceReferenceDate ?? 0
        let end = points.last?.date.timeIntervalSinceReferenceDate ?? start + 1
        let span = max(1, end - start)
        return CGPoint(
            x: plot.minX + plot.width
                * ((date.timeIntervalSinceReferenceDate - start) / span),
            y: yPosition(value, plot: plot)
        )
    }

    private func yPosition(_ value: Double, plot: CGRect) -> CGFloat {
        let span = max(0.001, domain.upperBound - domain.lowerBound)
        let fraction = min(1, max(0, (value - domain.lowerBound) / span))
        return plot.maxY - plot.height * fraction
    }

    private func signedPower(_ point: BatteryHistoryPoint) -> Double? {
        if let signed = point.signedPowerWatts { return signed }
        guard let value = point.powerWatts else { return nil }
        return point.externalConnected ? -abs(value) : abs(value)
    }

    private static func signature(
        points: [BatteryHistoryPoint],
        domain: ClosedRange<Double>,
        mode: RasterChartMode
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(mode.rawValue)
        hasher.combine(points.count)
        hasher.combine(points.first?.id)
        hasher.combine(points.last?.id)
        hasher.combine(domain.lowerBound.bitPattern)
        hasher.combine(domain.upperBound.bitPattern)
        return hasher.finalize()
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
