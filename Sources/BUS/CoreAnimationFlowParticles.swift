import AppKit
import QuartzCore
import SwiftUI

/// Compositor-owned particle animation. Core Animation advances these layers
/// at the display's native refresh rate without rebuilding a SwiftUI display
/// list for every frame.
struct CoreAnimationFlowParticles: NSViewRepresentable {
    let chargeShare: Double
    let systemShare: Double
    let hasChargeFlow: Bool
    let hasSystemFlow: Bool
    let compact: Bool
    let isAnimating: Bool

    func makeNSView(context: Context) -> FlowParticleNSView {
        let view = FlowParticleNSView()
        view.configure(
            chargeShare: chargeShare,
            systemShare: systemShare,
            hasChargeFlow: hasChargeFlow,
            hasSystemFlow: hasSystemFlow,
            compact: compact,
            isAnimating: isAnimating
        )
        return view
    }

    func updateNSView(_ view: FlowParticleNSView, context: Context) {
        view.configure(
            chargeShare: chargeShare,
            systemShare: systemShare,
            hasChargeFlow: hasChargeFlow,
            hasSystemFlow: hasSystemFlow,
            compact: compact,
            isAnimating: isAnimating
        )
    }
}

private struct ParticleConfiguration: Equatable {
    let chargeShare: Int
    let systemShare: Int
    let hasChargeFlow: Bool
    let hasSystemFlow: Bool
    let compact: Bool
    let isAnimating: Bool
}

final class FlowParticleNSView: NSView {
    private var configuration = ParticleConfiguration(
        chargeShare: 0,
        systemShare: 0,
        hasChargeFlow: false,
        hasSystemFlow: false,
        compact: false,
        isAnimating: false
    )
    private var renderedSize = CGSize.zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        prepareLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        prepareLayer()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func prepareLayer() {
        wantsLayer = true
        layer = CALayer()
        layer?.isGeometryFlipped = true
        layer?.masksToBounds = true
        layerContentsRedrawPolicy = .never
    }

    func configure(
        chargeShare: Double,
        systemShare: Double,
        hasChargeFlow: Bool,
        hasSystemFlow: Bool,
        compact: Bool,
        isAnimating: Bool
    ) {
        // Two-percent buckets avoid restarting compositor animations for tiny
        // sensor noise while preserving the proportional visual split.
        let next = ParticleConfiguration(
            chargeShare: Int((max(0, min(1, chargeShare)) * 50).rounded()),
            systemShare: Int((max(0, min(1, systemShare)) * 50).rounded()),
            hasChargeFlow: hasChargeFlow,
            hasSystemFlow: hasSystemFlow,
            compact: compact,
            isAnimating: isAnimating
        )
        guard next != configuration else { return }
        configuration = next
        rebuildLayers()
    }

    override func layout() {
        super.layout()
        guard abs(bounds.width - renderedSize.width) > 0.5
            || abs(bounds.height - renderedSize.height) > 0.5 else { return }
        rebuildLayers()
    }

    private func rebuildLayers() {
        guard let root = layer else { return }
        root.sublayers = nil
        renderedSize = bounds.size
        guard configuration.isAnimating,
              bounds.width > 120,
              bounds.height > 60,
              configuration.hasChargeFlow || configuration.hasSystemFlow else {
            return
        }

        let compact = configuration.compact
        let centerY = bounds.height * 0.5
        let nodeSize: CGFloat = compact ? 38 : 64
        let startX = (compact ? 25 : 58) + nodeSize / 2
        let endX = bounds.width - (compact ? 26 : 59) - nodeSize / 2
        let splitX = startX + (endX - startX) * (compact ? 0.42 : 0.44)
        let batteryY = bounds.height * (compact ? 0.27 : 0.25)
        let systemY = bounds.height * (compact ? 0.73 : 0.75)
        let trunkHeight: CGFloat = compact ? 17 : 32
        let chargeShare = CGFloat(max(0.18, min(0.98, CGFloat(configuration.chargeShare) / 50)))
        let dividerY = (centerY - trunkHeight / 2) + trunkHeight * chargeShare
        let upperBranchStartY = (centerY - trunkHeight / 2) + trunkHeight * chargeShare * 0.5
        let lowerBranchStartY = (dividerY + (centerY + trunkHeight / 2)) * 0.5
        let speed: CGFloat = compact ? 58 : 64
        let spacing: CGFloat = compact ? 88 : 100
        let dotSize: CGFloat = compact ? 3.0 : 4.0
        let globalBegin = CACurrentMediaTime()

        let trunk = CGMutablePath()
        trunk.move(to: CGPoint(x: startX, y: centerY))
        trunk.addCurve(
            to: CGPoint(x: splitX, y: centerY),
            control1: CGPoint(x: startX + (splitX - startX) * 0.34, y: centerY),
            control2: CGPoint(x: startX + (splitX - startX) * 0.82, y: centerY)
        )
        addParticles(
            path: trunk,
            approximateLength: max(1, splitX - startX),
            speed: speed,
            spacing: spacing,
            share: 1,
            dotSize: dotSize,
            color: NSColor.white.withAlphaComponent(0.86).cgColor,
            beginTime: globalBegin,
            to: root
        )

        if configuration.hasChargeFlow {
            let path = branchPath(
                splitX: splitX,
                endX: endX,
                startY: upperBranchStartY,
                endY: batteryY
            )
            addParticles(
                path: path,
                approximateLength: hypot(endX - splitX, batteryY - upperBranchStartY) * 1.08,
                speed: speed,
                spacing: spacing,
                share: CGFloat(configuration.chargeShare) / 50,
                dotSize: dotSize,
                color: NSColor.systemGreen.withAlphaComponent(0.92).cgColor,
                beginTime: globalBegin,
                to: root
            )
        }

        if configuration.hasSystemFlow {
            let path = branchPath(
                splitX: splitX,
                endX: endX,
                startY: lowerBranchStartY,
                endY: systemY
            )
            addParticles(
                path: path,
                approximateLength: hypot(endX - splitX, systemY - lowerBranchStartY) * 1.08,
                speed: speed,
                spacing: spacing,
                share: CGFloat(configuration.systemShare) / 50,
                dotSize: dotSize,
                color: NSColor.systemCyan.withAlphaComponent(0.90).cgColor,
                beginTime: globalBegin,
                to: root
            )
        }
    }

    private func branchPath(
        splitX: CGFloat,
        endX: CGFloat,
        startY: CGFloat,
        endY: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: splitX, y: startY))
        path.addCurve(
            to: CGPoint(x: endX, y: endY),
            control1: CGPoint(x: splitX + (endX - splitX) * 0.22, y: startY),
            control2: CGPoint(x: splitX + (endX - splitX) * 0.72, y: endY)
        )
        return path
    }

    private func addParticles(
        path: CGPath,
        approximateLength: CGFloat,
        speed: CGFloat,
        spacing: CGFloat,
        share: CGFloat,
        dotSize: CGFloat,
        color: CGColor,
        beginTime: CFTimeInterval,
        to root: CALayer
    ) {
        let duration = max(0.6, CFTimeInterval(approximateLength / speed))
        let baseCount = max(1, Int(ceil(approximateLength / spacing)))
        let count = max(1, Int((CGFloat(baseCount) * max(0.18, share)).rounded()))

        let replicator = CAReplicatorLayer()
        replicator.frame = bounds
        replicator.instanceCount = count
        replicator.instanceDelay = -duration / CFTimeInterval(count)

        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
        dot.cornerRadius = dotSize / 2
        dot.backgroundColor = color
        dot.opacity = Float(0.58 + 0.34 * max(0.18, share))

        let movement = CAKeyframeAnimation(keyPath: "position")
        movement.path = path
        movement.calculationMode = .paced
        movement.duration = duration
        movement.repeatCount = .infinity
        movement.beginTime = beginTime
        movement.isRemovedOnCompletion = false
        dot.add(movement, forKey: "flow")
        replicator.addSublayer(dot)
        root.addSublayer(replicator)
    }
}
