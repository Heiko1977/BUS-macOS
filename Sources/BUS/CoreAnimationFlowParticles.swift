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
        root.mask = nil
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
        let endX = bounds.width - (compact ? 62 : 59) - nodeSize / 2
        let splitX = startX + (endX - startX) * (compact ? 0.42 : 0.44)
        let batteryY = bounds.height * (compact ? 0.27 : 0.25)
        let systemY = bounds.height * (compact ? 0.73 : 0.75)
        let trunkHeight: CGFloat = compact ? 17 : 32
        let chargeShare = CGFloat(max(0.18, min(0.98, CGFloat(configuration.chargeShare) / 50)))
        let dividerY = (centerY - trunkHeight / 2) + trunkHeight * chargeShare
        let topY = centerY - trunkHeight / 2
        let bottomY = centerY + trunkHeight / 2
        let upperBranchStartY = (centerY - trunkHeight / 2) + trunkHeight * chargeShare * 0.5
        let lowerBranchStartY = (dividerY + (centerY + trunkHeight / 2)) * 0.5
        let globalBegin = CACurrentMediaTime()
        let trunkLength = max(1, splitX - startX)

        // Clip every animated halo to the exact filled flow channels. This
        // permits a brighter, soft effect without spilling into the card.
        let endExpansion: CGFloat = compact ? 1.22 : 1.34
        let chargeStartHeight = max(0, dividerY - topY)
        let systemStartHeight = max(0, bottomY - dividerY)
        let channelMaskPath = CGMutablePath()
        let seamOverlap: CGFloat = configuration.hasChargeFlow
            && configuration.hasSystemFlow ? 0.45 : 0
        if configuration.hasChargeFlow {
            let endHeight = chargeStartHeight * endExpansion
            addChannelShape(
                to: channelMaskPath,
                startX: startX,
                splitX: splitX,
                endX: endX,
                sourceTop: topY,
                sourceBottom: dividerY + seamOverlap,
                endTop: batteryY - endHeight / 2,
                endBottom: batteryY + endHeight / 2
            )
        }
        if configuration.hasSystemFlow {
            let endHeight = systemStartHeight * endExpansion
            addChannelShape(
                to: channelMaskPath,
                startX: startX,
                splitX: splitX,
                endX: endX,
                sourceTop: dividerY - seamOverlap,
                sourceBottom: bottomY,
                endTop: systemY - endHeight / 2,
                endBottom: systemY + endHeight / 2
            )
        }
        let channelMask = CAShapeLayer()
        channelMask.frame = bounds
        channelMask.path = channelMaskPath
        channelMask.fillColor = NSColor.black.cgColor
        channelMask.fillRule = .nonZero
        root.mask = channelMask

        let trunk = CGMutablePath()
        trunk.move(to: CGPoint(x: startX, y: centerY))
        trunk.addCurve(
            to: CGPoint(x: splitX, y: centerY),
            control1: CGPoint(x: startX + (splitX - startX) * 0.34, y: centerY),
            control2: CGPoint(x: startX + (splitX - startX) * 0.82, y: centerY)
        )
        let chargeLength = hypot(endX - splitX, batteryY - upperBranchStartY) * 1.08
        let systemLength = hypot(endX - splitX, systemY - lowerBranchStartY) * 1.08
        let flowSpeed: CGFloat = compact ? 135 : 175
        let trunkDuration = max(0.65, CFTimeInterval(trunkLength / flowSpeed))
        let cycleDuration = max(
            2.9,
            trunkDuration + max(chargeLength, systemLength) / flowSpeed + 0.65
        )
        // Branch pulses begin while the trunk pulse is still at the split.
        // That overlap makes the transition visibly divide instead of jump.
        // Let the pulse reach the junction before the two outgoing pulses
        // appear; this prevents the three hard, parallel streaks at the fork.
        let branchDelay = trunkDuration * 0.94

        addFlowPulse(
            path: trunk,
            travelDuration: trunkDuration,
            cycleDuration: cycleDuration,
            startDelay: 0,
            color: .white,
            compact: compact,
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
            addFlowPulse(
                path: path,
                travelDuration: max(0.7, CFTimeInterval(chargeLength / flowSpeed)),
                cycleDuration: cycleDuration,
                startDelay: branchDelay,
                color: .white,
                compact: compact,
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
            addFlowPulse(
                path: path,
                travelDuration: max(0.7, CFTimeInterval(systemLength / flowSpeed)),
                cycleDuration: cycleDuration,
                startDelay: branchDelay,
                color: .white,
                compact: compact,
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

    private func addChannelShape(
        to path: CGMutablePath,
        startX: CGFloat,
        splitX: CGFloat,
        endX: CGFloat,
        sourceTop: CGFloat,
        sourceBottom: CGFloat,
        endTop: CGFloat,
        endBottom: CGFloat
    ) {
        let branchLength = endX - splitX
        let control1X = splitX + branchLength * 0.24
        let control2X = splitX + branchLength * 0.72
        path.move(to: CGPoint(x: startX, y: sourceTop))
        path.addLine(to: CGPoint(x: splitX, y: sourceTop))
        path.addCurve(
            to: CGPoint(x: endX, y: endTop),
            control1: CGPoint(x: control1X, y: sourceTop),
            control2: CGPoint(x: control2X, y: endTop)
        )
        path.addLine(to: CGPoint(x: endX, y: endBottom))
        path.addCurve(
            to: CGPoint(x: splitX, y: sourceBottom),
            control1: CGPoint(x: control2X, y: endBottom),
            control2: CGPoint(x: control1X, y: sourceBottom)
        )
        path.addLine(to: CGPoint(x: startX, y: sourceBottom))
        path.closeSubpath()
    }

    private func addFlowPulse(
        path: CGPath,
        travelDuration: CFTimeInterval,
        cycleDuration: CFTimeInterval,
        startDelay: CFTimeInterval,
        color: NSColor,
        compact: Bool,
        beginTime: CFTimeInterval,
        to root: CALayer
    ) {
        let start = max(0, min(0.94, startDelay / cycleDuration))
        let end = max(start + 0.04, min(0.99, (startDelay + travelDuration) / cycleDuration))
        // Hold a substantial, constant-length highlight while it travels.
        // This avoids the visually shrinking streak at the end of a path.
        let pulseFraction: CGFloat = compact ? 0.24 : 0.21

        // Two broad, low-opacity halos create a diffuse energy shimmer.
        // There is deliberately no narrow white core, so the moving effect
        // reads as light travelling through the existing flow rather than
        // a visible line being drawn over it.
        addPulseLayer(
            path: path,
            strokeColor: color.withAlphaComponent(0.13).cgColor,
            lineWidth: compact ? 14 : 24,
            shadowRadius: compact ? 16 : 24,
            start: start,
            end: end,
            pulseFraction: pulseFraction,
            cycleDuration: cycleDuration,
            beginTime: beginTime,
            to: root
        )
        addPulseLayer(
            path: path,
            strokeColor: color.withAlphaComponent(0.22).cgColor,
            lineWidth: compact ? 8 : 13,
            shadowRadius: compact ? 10 : 15,
            start: start,
            end: end,
            pulseFraction: pulseFraction,
            cycleDuration: cycleDuration,
            beginTime: beginTime,
            to: root
        )
    }

    private func addPulseLayer(
        path: CGPath,
        strokeColor: CGColor,
        lineWidth: CGFloat,
        shadowRadius: CGFloat,
        start: CFTimeInterval,
        end: CFTimeInterval,
        pulseFraction: CGFloat,
        cycleDuration: CFTimeInterval,
        beginTime: CFTimeInterval,
        to root: CALayer
    ) {
        let pulse = CAShapeLayer()
        pulse.frame = bounds
        pulse.path = path
        pulse.strokeColor = strokeColor
        pulse.fillColor = nil
        pulse.lineWidth = lineWidth
        pulse.lineCap = .round
        pulse.strokeStart = 0
        pulse.strokeEnd = 0
        pulse.shadowColor = strokeColor
        pulse.shadowOpacity = 1
        pulse.shadowRadius = shadowRadius
        pulse.shadowOffset = .zero

        let progress = CAKeyframeAnimation(keyPath: "strokeEnd")
        progress.values = [0, 0, 1, 1]
        progress.keyTimes = [0, NSNumber(value: start), NSNumber(value: end), 1]
        progress.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .linear)
        ]

        let tail = CAKeyframeAnimation(keyPath: "strokeStart")
        tail.values = [0, 0, 0, 1 - pulseFraction, 1 - pulseFraction]
        tail.keyTimes = [
            0,
            NSNumber(value: start),
            NSNumber(value: min(end, start + (end - start) * Double(pulseFraction))),
            NSNumber(value: end),
            1
        ]
        tail.timingFunctions = [
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .linear)
        ]

        let visibility = CAKeyframeAnimation(keyPath: "opacity")
        let fade = min(0.07, (end - start) * 0.30)
        visibility.values = [0, 0, 1, 1, 0, 0]
        visibility.keyTimes = [
            0,
            NSNumber(value: start),
            NSNumber(value: min(end, start + fade)),
            NSNumber(value: max(start, end - fade)),
            NSNumber(value: end),
            1
        ]
        visibility.timingFunctions = [
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .linear)
        ]

        let animation = CAAnimationGroup()
        animation.animations = [progress, tail, visibility]
        animation.duration = cycleDuration
        animation.repeatCount = .infinity
        animation.beginTime = beginTime
        animation.isRemovedOnCompletion = false
        pulse.add(animation, forKey: "flowPulse")
        root.addSublayer(pulse)
    }
}
