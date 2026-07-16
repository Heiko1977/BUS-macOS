import SwiftUI

struct ChargingDashboardCard: View {
    @EnvironmentObject private var presentation:
        DashboardPresentationStore
    @EnvironmentObject private var l: Localizer

    private var frame: DashboardPresentationFrame {
        presentation.frame
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Label(
                        chargingStatus,
                        systemImage: frame.isCharging
                            ? "bolt.fill"
                            : "battery.100percent"
                    )
                    .font(.title3.bold())
                    .foregroundStyle(.green)

                    Spacer()

                    Text(
                        frame.batteryPercent.map {
                            String(format: "%.0f %%", $0)
                        } ?? "–"
                    )
                    .font(.title2.bold())
                    .monospacedDigit()
                }

                AnimatedChargingFlow()

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ],
                    spacing: 12
                ) {
                    chargingMetric(
                        icon: "powerplug.fill",
                        title: l.t("currentInputPower"),
                        value: watts(frame.displayedAdapterPowerWatts),
                        estimated: frame.adapterInputIsEstimated,
                        detail: inputPowerDetail
                    )

                    chargingMetric(
                        icon: "laptopcomputer",
                        title: l.t("systemConsumption"),
                        value: watts(
                            frame.estimatedSystemPowerWatts
                        ),
                        estimated: true
                    )

                    chargingMetric(
                        icon: "battery.75percent",
                        title: l.t("batteryChargingPower"),
                        value: watts(frame.batteryChargingPowerWatts),
                        estimated: false
                    )
                }

                Divider()

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 16),
                        GridItem(.flexible(), spacing: 16)
                    ],
                    spacing: 12
                ) {
                    timeMetric(
                        title: l.t("timeTo80"),
                        hours: frame.estimatedChargeTimeTo80Hours
                    )

                    timeMetric(
                        title: l.t("timeToFull"),
                        hours: frame.estimatedChargeTimeToFullHours
                    )

                    timeMetric(
                        title: l.t("runtimeCurrentCharge"),
                        hours: frame.estimatedRuntimeAtCurrentChargeHours
                    )

                    timeMetric(
                        title: l.t("runtimeFullCharge"),
                        hours: frame.estimatedRuntimeAtFullChargeHours
                    )
                }

                if let rate = frame.chargeRatePercentPerHour {
                    HStack {
                        Label(
                            l.t("chargeSpeed"),
                            systemImage: "gauge.with.dots.needle.67percent"
                        )
                        Spacer()
                        Text(String(format: "%.1f %%/h", rate))
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Text(l.t("chargingEstimateInfo"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var inputPowerDetail: String? {
        var parts: [String] = [
            l.t(frame.powerMeasurementQualityKey)
        ]

        if let maximum = frame.adapterRatedPowerWatts {
            parts.append(
                String(
                    format: "%@ %.0f W",
                    l.t("adapterMaximum"),
                    maximum
                )
            )
        }

        return parts.joined(separator: " · ")
    }

    private var chargingStatus: String {
        guard let percent = frame.batteryPercent else {
            return l.t("charging")
        }

        if frame.isCharging {
            return l.t("chargingActive")
        }

        if percent >= 99 {
            return l.t("fullyCharged")
        }

        return l.t("chargeHolding")
    }

    private func chargingMetric(
        icon: String,
        title: String,
        value: String,
        estimated: Bool,
        detail: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.title3.bold())
                .monospacedDigit()

            if estimated || detail != nil {
                HStack(spacing: 5) {
                    if estimated {
                        Text(l.t("estimated"))
                    }
                    if estimated, detail != nil {
                        Text("·")
                    }
                    if let detail {
                        Text(detail)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
        .padding(12)
        .background {
            StaticLiquidGlassSurface(
                cornerRadius: 14,
                accent: .mint,
                intensity: 0.8
            )
        }
        .allowsHitTesting(false)
    }

    private func timeMetric(
        title: String,
        hours: Double?
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.fill")
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(formatHours(hours))
                    .font(.headline)
                    .monospacedDigit()
            }

            Spacer()
        }
        .padding(10)
        .background {
            StaticLiquidGlassSurface(
                cornerRadius: 12,
                accent: .green,
                intensity: 0.7
            )
        }
        .allowsHitTesting(false)
    }

    private func watts(_ value: Double) -> String {
        String(format: "%.1f W", max(0, value))
    }

    private func formatHours(_ hours: Double?) -> String {
        guard let hours,
              hours.isFinite,
              hours > 0 else {
            return l.t("calculating")
        }

        let totalMinutes = max(1, Int((hours * 60).rounded()))
        return "\(totalMinutes / 60) h \(totalMinutes % 60) min"
    }
}

final class ChargingFlowAnimationState: ObservableObject {
    private(set) var displayedInput = 0.0
    private(set) var displayedCharge = 0.0
    private(set) var displayedSystem = 0.0

    private var targetInput = 0.0
    private var targetCharge = 0.0
    private var targetSystem = 0.0
    private var lastFrameTime: TimeInterval?

    func setTargets(
        input: Double,
        charge: Double,
        system: Double,
        immediate: Bool = false
    ) {
        targetInput = max(0, input)
        targetCharge = max(0, charge)
        targetSystem = max(0, system)

        if immediate {
            displayedInput = targetInput
            displayedCharge = targetCharge
            displayedSystem = targetSystem
        }
    }

    func step(at time: TimeInterval, reduceMotion: Bool) {
        guard !reduceMotion else {
            displayedInput = targetInput
            displayedCharge = targetCharge
            displayedSystem = targetSystem
            lastFrameTime = time
            return
        }

        let delta = min(
            0.20,
            max(0, time - (lastFrameTime ?? time))
        )
        lastFrameTime = time

        // Exponential smoothing is independent of the actual frame rate.
        let response = 1 - exp(-delta * 3.2)
        displayedInput += (targetInput - displayedInput) * response
        displayedCharge += (targetCharge - displayedCharge) * response
        displayedSystem += (targetSystem - displayedSystem) * response
    }
}

struct AnimatedChargingFlow: View {
    @EnvironmentObject private var presentation:
        DashboardPresentationStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var compact = false

    private var frame: DashboardPresentationFrame {
        presentation.frame
    }

    private var hasVisibleEnergyFlow: Bool {
        let threshold = 0.05
        let chargeFlow = frame.isCharging
            && frame.batteryChargingPowerWatts >= threshold
        let systemFlow =
            frame.estimatedSystemPowerWatts >= threshold
        return chargeFlow || systemFlow
    }

    private var shouldAnimate: Bool {
        !reduceMotion
            && scenePhase == .active
            && frame.isRunning
            && hasVisibleEnergyFlow
    }

    var body: some View {
        ZStack {
            // Static layer: gradients, paths, symbols and labels are only
            // redrawn when size or measured values change.
            Canvas(rendersAsynchronously: true) { context, size in
                let layout = makeLayout(size: size)
                drawStaticLayer(
                    context: &context,
                    layout: layout
                )
            }

            CoreAnimationFlowParticles(
                chargeShare: particleChargeShare,
                systemShare: particleSystemShare,
                hasChargeFlow: particleHasChargeFlow,
                hasSystemFlow: particleHasSystemFlow,
                compact: compact,
                isAnimating: shouldAnimate
            )
            .allowsHitTesting(false)
        }
        .frame(height: compact ? 94 : 198)
        .background {
            ZStack {
                StaticLiquidGlassSurface(
                    cornerRadius: compact ? 18 : 24,
                    accent: .cyan,
                    intensity: 1.15
                )

                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.105), location: 0),
                        .init(color: .mint.opacity(0.050), location: 0.33),
                        .init(color: .cyan.opacity(0.030), location: 0.70),
                        .init(color: .blue.opacity(0.042), location: 1)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: compact ? 18 : 24,
                        style: .continuous
                    )
                )

                RadialGradient(
                    colors: [
                        .white.opacity(0.075),
                        .clear
                    ],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: compact ? 110 : 260
                )
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: compact ? 18 : 24,
                        style: .continuous
                    )
                )
            }
        }
        .overlay {
            RoundedRectangle(
                cornerRadius: compact ? 18 : 24,
                style: .continuous
            )
            .stroke(
                LinearGradient(
                    colors: [
                        .white.opacity(0.34),
                        .white.opacity(0.075),
                        .mint.opacity(0.12),
                        .white.opacity(0.035)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        }
        .overlay(alignment: .top) {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            .clear,
                            .white.opacity(0.31),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: compact ? 190 : 460, height: 1.3)
                .padding(.top, 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 20, y: 10)
        .clipShape(
            RoundedRectangle(
                cornerRadius: compact ? 18 : 24,
                style: .continuous
            )
        )
        .accessibilityLabel("Animierter proportionaler Ladefluss")
        // The flow is purely informational. This also prevents its continuously
        // refreshed particle layer from participating in scroll hit testing.
        .allowsHitTesting(false)
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var particleHasChargeFlow: Bool {
        frame.isCharging && frame.batteryChargingPowerWatts >= 0.05
    }

    private var particleHasSystemFlow: Bool {
        frame.estimatedSystemPowerWatts >= 0.05
    }

    private var particleBranchTotal: Double {
        max(
            0.1,
            (particleHasChargeFlow ? frame.batteryChargingPowerWatts : 0)
                + (particleHasSystemFlow ? frame.estimatedSystemPowerWatts : 0)
        )
    }

    private var particleChargeShare: Double {
        particleHasChargeFlow
            ? frame.batteryChargingPowerWatts / particleBranchTotal
            : 0
    }

    private var particleSystemShare: Double {
        particleHasSystemFlow
            ? frame.estimatedSystemPowerWatts / particleBranchTotal
            : 0
    }

    private struct FlowLayout {
        let inputPower: Double
        let chargePower: Double
        let systemPower: Double
        let chargeShare: Double
        let systemShare: Double
        let hasChargeFlow: Bool
        let hasSystemFlow: Bool

        let leftNodeCenterX: CGFloat
        let rightNodeCenterX: CGFloat
        let centerY: CGFloat
        let nodeSize: CGFloat
        let nodeRadius: CGFloat

        let flowStartX: CGFloat
        let flowEndX: CGFloat
        let splitX: CGFloat
        let topY: CGFloat
        let bottomY: CGFloat
        let dividerY: CGFloat

        let batteryEndCenterY: CGFloat
        let systemEndCenterY: CGFloat
        let batteryEndTop: CGFloat
        let batteryEndBottom: CGFloat
        let systemEndTop: CGFloat
        let systemEndBottom: CGFloat

        let upperChannel: Path?
        let lowerChannel: Path?
        let trunkCurve: CubicCurve
        let batteryCurve: CubicCurve
        let systemCurve: CubicCurve
    }

    private func makeLayout(size: CGSize) -> FlowLayout {
        let centerY = size.height * 0.5
        let nodeSize: CGFloat = compact ? 38 : 64
        let nodeRadius = nodeSize / 2

        let leftNodeCenterX: CGFloat = compact ? 25 : 58
        let rightNodeCenterX = size.width - (compact ? 26 : 59)

        let flowStartX = leftNodeCenterX + nodeRadius
        let flowEndX = rightNodeCenterX - nodeRadius
        let splitX = flowStartX
            + (flowEndX - flowStartX) * (compact ? 0.42 : 0.44)

        let inputPower = max(0.1, frame.displayedAdapterPowerWatts)
        let chargePower = max(0, frame.batteryChargingPowerWatts)
        let systemPower = max(
            0,
            frame.estimatedSystemPowerWatts
        )

        let threshold = 0.05
        let hasChargeFlow = frame.isCharging
            && chargePower >= threshold
        let hasSystemFlow = systemPower >= threshold

        let visibleCharge = hasChargeFlow ? chargePower : 0
        let visibleSystem = hasSystemFlow ? systemPower : 0
        let branchTotal = max(0.1, visibleCharge + visibleSystem)

        let chargeShare = hasChargeFlow
            ? min(1, max(0, visibleCharge / branchTotal))
            : 0
        let systemShare = hasSystemFlow
            ? min(1, max(0, visibleSystem / branchTotal))
            : 0

        let trunkHeight: CGFloat = compact ? 17 : 32
        let topY = centerY - trunkHeight / 2
        let bottomY = centerY + trunkHeight / 2
        let dividerY = topY
            + trunkHeight * CGFloat(chargeShare)

        let batteryEndCenterY =
            size.height * (compact ? 0.27 : 0.25)
        let systemEndCenterY =
            size.height * (compact ? 0.73 : 0.75)

        let endExpansion: CGFloat = compact ? 1.22 : 1.34
        let batteryStartHeight = max(0, dividerY - topY)
        let systemStartHeight = max(0, bottomY - dividerY)
        let batteryEndHeight = batteryStartHeight * endExpansion
        let systemEndHeight = systemStartHeight * endExpansion

        let batteryEndTop =
            batteryEndCenterY - batteryEndHeight / 2
        let batteryEndBottom =
            batteryEndCenterY + batteryEndHeight / 2
        let systemEndTop =
            systemEndCenterY - systemEndHeight / 2
        let systemEndBottom =
            systemEndCenterY + systemEndHeight / 2

        let seamOverlap: CGFloat =
            hasChargeFlow && hasSystemFlow ? 0.45 : 0

        let upperChannel = hasChargeFlow
            ? continuousChannelShape(
                flowStartX: flowStartX,
                splitX: splitX,
                flowEndX: flowEndX,
                sourceTop: topY,
                sourceBottom: dividerY + seamOverlap,
                endTop: batteryEndTop,
                endBottom: batteryEndBottom
            )
            : nil

        let lowerChannel = hasSystemFlow
            ? continuousChannelShape(
                flowStartX: flowStartX,
                splitX: splitX,
                flowEndX: flowEndX,
                sourceTop: dividerY - seamOverlap,
                sourceBottom: bottomY,
                endTop: systemEndTop,
                endBottom: systemEndBottom
            )
            : nil

        let trunkCurve = CubicCurve(
            start: CGPoint(x: flowStartX, y: centerY),
            control1: CGPoint(
                x: flowStartX + (splitX - flowStartX) * 0.34,
                y: centerY
            ),
            control2: CGPoint(
                x: flowStartX + (splitX - flowStartX) * 0.82,
                y: centerY
            ),
            end: CGPoint(x: splitX, y: centerY)
        )

        let batteryCurve = CubicCurve(
            start: CGPoint(
                x: splitX,
                y: (topY + dividerY) / 2
            ),
            control1: CGPoint(
                x: splitX + (flowEndX - splitX) * 0.22,
                y: (topY + dividerY) / 2
            ),
            control2: CGPoint(
                x: splitX + (flowEndX - splitX) * 0.72,
                y: batteryEndCenterY
            ),
            end: CGPoint(
                x: flowEndX,
                y: batteryEndCenterY
            )
        )

        let systemCurve = CubicCurve(
            start: CGPoint(
                x: splitX,
                y: (dividerY + bottomY) / 2
            ),
            control1: CGPoint(
                x: splitX + (flowEndX - splitX) * 0.22,
                y: (dividerY + bottomY) / 2
            ),
            control2: CGPoint(
                x: splitX + (flowEndX - splitX) * 0.72,
                y: systemEndCenterY
            ),
            end: CGPoint(
                x: flowEndX,
                y: systemEndCenterY
            )
        )

        return FlowLayout(
            inputPower: inputPower,
            chargePower: chargePower,
            systemPower: systemPower,
            chargeShare: chargeShare,
            systemShare: systemShare,
            hasChargeFlow: hasChargeFlow,
            hasSystemFlow: hasSystemFlow,
            leftNodeCenterX: leftNodeCenterX,
            rightNodeCenterX: rightNodeCenterX,
            centerY: centerY,
            nodeSize: nodeSize,
            nodeRadius: nodeRadius,
            flowStartX: flowStartX,
            flowEndX: flowEndX,
            splitX: splitX,
            topY: topY,
            bottomY: bottomY,
            dividerY: dividerY,
            batteryEndCenterY: batteryEndCenterY,
            systemEndCenterY: systemEndCenterY,
            batteryEndTop: batteryEndTop,
            batteryEndBottom: batteryEndBottom,
            systemEndTop: systemEndTop,
            systemEndBottom: systemEndBottom,
            upperChannel: upperChannel,
            lowerChannel: lowerChannel,
            trunkCurve: trunkCurve,
            batteryCurve: batteryCurve,
            systemCurve: systemCurve
        )
    }

    private func drawStaticLayer(
        context: inout GraphicsContext,
        layout: FlowLayout
    ) {
        drawLiquidChannels(
            context: &context,
            upperChannel: layout.upperChannel,
            lowerChannel: layout.lowerChannel,
            flowStartX: layout.flowStartX,
            splitX: layout.splitX,
            flowEndX: layout.flowEndX,
            topY: layout.topY,
            bottomY: layout.bottomY,
            dividerY: layout.dividerY,
            chargeShare: layout.chargeShare,
            compact: compact
        )

        drawGlassNode(
            context: &context,
            center: CGPoint(
                x: layout.leftNodeCenterX,
                y: layout.centerY
            ),
            size: layout.nodeSize,
            symbol: "powerplug.fill",
            color: .green,
            compact: compact
        )

        drawGlassNode(
            context: &context,
            center: CGPoint(
                x: layout.rightNodeCenterX,
                y: layout.batteryEndCenterY
            ),
            size: layout.nodeSize,
            symbol: frame.isCharging
                ? "battery.75percent"
                : "battery.100percent",
            color: .green,
            compact: compact
        )

        drawGlassNode(
            context: &context,
            center: CGPoint(
                x: layout.rightNodeCenterX,
                y: layout.systemEndCenterY
            ),
            size: layout.nodeSize,
            symbol: "laptopcomputer",
            color: .blue,
            compact: compact
        )

        if !compact {
            drawLabel(
                context: &context,
                text: String(
                    format: "%.1f W",
                    layout.inputPower
                ),
                point: CGPoint(
                    x: layout.leftNodeCenterX,
                    y: layout.centerY
                        + layout.nodeRadius
                        + 18
                )
            )

            drawLabel(
                context: &context,
                text: String(
                    format: "%.1f W · %.0f %%",
                    layout.chargePower,
                    layout.chargeShare * 100
                ),
                point: CGPoint(
                    x: layout.flowEndX - 64,
                    y: layout.batteryEndTop - 16
                )
            )

            drawLabel(
                context: &context,
                text: String(
                    format: "%.1f W · %.0f %%",
                    layout.systemPower,
                    layout.systemShare * 100
                ),
                point: CGPoint(
                    x: layout.flowEndX - 64,
                    y: layout.systemEndBottom + 16
                )
            )
        }
    }

    private func drawParticleLayer(
        context: inout GraphicsContext,
        layout: FlowLayout,
        time: TimeInterval
    ) {
        let lookupSamples = compact ? 16 : 24
        let trunkLookup = CurveLengthLookup(
            curve: layout.trunkCurve,
            samples: lookupSamples
        )
        let batteryLookup = CurveLengthLookup(
            curve: layout.batteryCurve,
            samples: lookupSamples
        )
        let systemLookup = CurveLengthLookup(
            curve: layout.systemCurve,
            samples: lookupSamples
        )

        let speed: CGFloat = compact ? 58 : 64
        let spacing: CGFloat = compact ? 88 : 100
        let globalDistance = CGFloat(time) * speed

        drawGlobalSegmentParticles(
            context: &context,
            curve: layout.trunkCurve,
            lookup: trunkLookup,
            globalDistance: globalDistance,
            globalOffset: 0,
            spacing: spacing,
            startColor: .green,
            endColor: .mint,
            intensity: 0.86,
            compact: compact
        )

        if layout.hasChargeFlow {
            drawGlobalSegmentParticles(
                context: &context,
                curve: layout.batteryCurve,
                lookup: batteryLookup,
                globalDistance: globalDistance,
                globalOffset: trunkLookup.totalLength,
                spacing: spacing,
                startColor: .mint,
                endColor: .green,
                intensity: max(0.16, layout.chargeShare),
                compact: compact
            )
        }

        if layout.hasSystemFlow {
            drawGlobalSegmentParticles(
                context: &context,
                curve: layout.systemCurve,
                lookup: systemLookup,
                globalDistance: globalDistance,
                globalOffset: trunkLookup.totalLength,
                spacing: spacing,
                startColor: .mint,
                endColor: .blue,
                intensity: max(0.16, layout.systemShare),
                compact: compact
            )
        }
    }

    private func continuousChannelShape(
        flowStartX: CGFloat,
        splitX: CGFloat,
        flowEndX: CGFloat,
        sourceTop: CGFloat,
        sourceBottom: CGFloat,
        endTop: CGFloat,
        endBottom: CGFloat
    ) -> Path {
        let branchLength = flowEndX - splitX
        let control1X = splitX + branchLength * 0.24
        let control2X = splitX + branchLength * 0.72

        var path = Path()
        path.move(
            to: CGPoint(
                x: flowStartX,
                y: sourceTop
            )
        )
        path.addLine(
            to: CGPoint(
                x: splitX,
                y: sourceTop
            )
        )
        path.addCurve(
            to: CGPoint(
                x: flowEndX,
                y: endTop
            ),
            control1: CGPoint(
                x: control1X,
                y: sourceTop
            ),
            control2: CGPoint(
                x: control2X,
                y: endTop
            )
        )
        path.addLine(
            to: CGPoint(
                x: flowEndX,
                y: endBottom
            )
        )
        path.addCurve(
            to: CGPoint(
                x: splitX,
                y: sourceBottom
            ),
            control1: CGPoint(
                x: control2X,
                y: endBottom
            ),
            control2: CGPoint(
                x: control1X,
                y: sourceBottom
            )
        )
        path.addLine(
            to: CGPoint(
                x: flowStartX,
                y: sourceBottom
            )
        )
        path.closeSubpath()
        return path
    }

    private func drawLiquidChannels(
        context: inout GraphicsContext,
        upperChannel: Path?,
        lowerChannel: Path?,
        flowStartX: CGFloat,
        splitX: CGFloat,
        flowEndX: CGFloat,
        topY: CGFloat,
        bottomY: CGFloat,
        dividerY: CGFloat,
        chargeShare: Double,
        compact: Bool
    ) {
        let start = CGPoint(
            x: flowStartX,
            y: (topY + bottomY) / 2
        )
        let end = CGPoint(
            x: flowEndX,
            y: (topY + bottomY) / 2
        )

        // Large, low-opacity bloom gives depth without a hard edge.
        if let upperChannel {
            context.fill(
                upperChannel,
                with: .color(.green.opacity(0.075))
            )
            context.fill(
                upperChannel,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .green.opacity(0.78), location: 0),
                        .init(color: .mint.opacity(0.84), location: 0.43),
                        .init(color: .mint.opacity(0.74), location: 0.57),
                        .init(color: .green.opacity(0.86), location: 1)
                    ]),
                    startPoint: start,
                    endPoint: end
                )
            )
        }

        if let lowerChannel {
            context.fill(
                lowerChannel,
                with: .color(.blue.opacity(0.068))
            )
            context.fill(
                lowerChannel,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .green.opacity(0.78), location: 0),
                        .init(color: .mint.opacity(0.84), location: 0.43),
                        .init(color: .cyan.opacity(0.76), location: 0.62),
                        .init(color: .blue.opacity(0.84), location: 1)
                    ]),
                    startPoint: start,
                    endPoint: end
                )
            )
        }

        // Shared glass veil visually fuses both channels before the split.
        let sourceGlass = Path(
            CGRect(
                x: flowStartX,
                y: topY,
                width: splitX - flowStartX + 1.2,
                height: bottomY - topY
            )
        )
        context.fill(
            sourceGlass,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: .white.opacity(0.035), location: 0),
                    .init(color: .white.opacity(0.16), location: 0.46),
                    .init(color: .mint.opacity(0.05), location: 1)
                ]),
                startPoint: CGPoint(
                    x: flowStartX,
                    y: topY
                ),
                endPoint: CGPoint(
                    x: splitX,
                    y: bottomY
                )
            )
        )

        // Upper reflection follows the whole source section.
        let reflectionHeight: CGFloat = compact ? 1.0 : 1.4
        let reflectionRect = CGRect(
            x: flowStartX + 5,
            y: topY + 2,
            width: max(0, splitX - flowStartX - 8),
            height: reflectionHeight
        )
        context.fill(
            Path(reflectionRect),
            with: .linearGradient(
                Gradient(colors: [
                    .white.opacity(0.04),
                    .white.opacity(0.34),
                    .white.opacity(0.08)
                ]),
                startPoint: CGPoint(
                    x: reflectionRect.minX,
                    y: reflectionRect.midY
                ),
                endPoint: CGPoint(
                    x: reflectionRect.maxX,
                    y: reflectionRect.midY
                )
            )
        )

        // Only outer contour accents are drawn. No vertical split edge exists.
        var topAccent = Path()
        topAccent.move(
            to: CGPoint(
                x: flowStartX,
                y: topY
            )
        )
        topAccent.addLine(
            to: CGPoint(
                x: splitX,
                y: topY
            )
        )
        context.stroke(
            topAccent,
            with: .color(.white.opacity(0.17)),
            lineWidth: compact ? 0.55 : 0.8
        )

        var bottomAccent = Path()
        bottomAccent.move(
            to: CGPoint(
                x: flowStartX,
                y: bottomY
            )
        )
        bottomAccent.addLine(
            to: CGPoint(
                x: splitX,
                y: bottomY
            )
        )
        context.stroke(
            bottomAccent,
            with: .color(.white.opacity(0.07)),
            lineWidth: compact ? 0.45 : 0.65
        )

        // Divider begins beyond the split and fades in, never creating a knot.
        if chargeShare > 0.006 && chargeShare < 0.994 {
            let fadeLength: CGFloat = compact ? 25 : 40
            let dividerStart = splitX + (compact ? 4 : 6)
            let dividerEnd = min(
                flowEndX,
                dividerStart + fadeLength
            )

            var divider = Path()
            divider.move(
                to: CGPoint(
                    x: dividerStart,
                    y: dividerY
                )
            )
            divider.addLine(
                to: CGPoint(
                    x: dividerEnd,
                    y: dividerY
                )
            )
            context.stroke(
                divider,
                with: .linearGradient(
                    Gradient(colors: [
                        .clear,
                        .black.opacity(0.28)
                    ]),
                    startPoint: CGPoint(
                        x: dividerStart,
                        y: dividerY
                    ),
                    endPoint: CGPoint(
                        x: dividerEnd,
                        y: dividerY
                    )
                ),
                style: StrokeStyle(
                    lineWidth: compact ? 0.55 : 0.8,
                    lineCap: .round
                )
            )
        }
    }

    private func drawGlobalSegmentParticles(
        context: inout GraphicsContext,
        curve: CubicCurve,
        lookup: CurveLengthLookup,
        globalDistance: CGFloat,
        globalOffset: CGFloat,
        spacing: CGFloat,
        startColor: Color,
        endColor: Color,
        intensity: Double,
        compact: Bool
    ) {
        guard lookup.totalLength > 1,
              spacing > 1 else {
            return
        }

        let clampedIntensity = min(1, max(0.12, intensity))
        let phase = globalDistance.truncatingRemainder(
            dividingBy: spacing
        )

        let segmentStart = globalOffset
        let segmentEnd = globalOffset + lookup.totalLength
        let firstIndex = Int(
            floor((segmentStart - phase) / spacing)
        ) - 1
        let lastIndex = Int(
            ceil((segmentEnd - phase) / spacing)
        ) + 1

        for index in firstIndex...lastIndex {
            let globalParticleDistance =
                phase + CGFloat(index) * spacing

            guard globalParticleDistance >= segmentStart,
                  globalParticleDistance <= segmentEnd else {
                continue
            }

            let localDistance =
                globalParticleDistance - segmentStart
            let t = lookup.parameter(
                forDistance: localDistance
            )
            let point = curve.point(at: t)
            let progress =
                localDistance / lookup.totalLength
            let color = progress < 0.45
                ? startColor
                : endColor

            let baseRadius: CGFloat = compact ? 1.35 : 2.0
            let radius =
                baseRadius * CGFloat(
                    0.76 + clampedIntensity * 0.24
                )

            // Two simple solid circles are considerably cheaper than a
            // radial gradient generated for every particle and every frame.
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: point.x - radius * 1.75,
                        y: point.y - radius * 1.75,
                        width: radius * 3.5,
                        height: radius * 3.5
                    )
                ),
                with: .color(
                    color.opacity(
                        0.035 + clampedIntensity * 0.050
                    )
                )
            )

            let coreRadius = radius * 0.72
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: point.x - coreRadius,
                        y: point.y - coreRadius,
                        width: coreRadius * 2,
                        height: coreRadius * 2
                    )
                ),
                with: .color(
                    Color.white.opacity(
                        0.58 + clampedIntensity * 0.28
                    )
                )
            )
        }
    }

    private func drawGlassNode(
        context: inout GraphicsContext,
        center: CGPoint,
        size: CGFloat,
        symbol: String,
        color: Color,
        compact: Bool
    ) {
        let rect = CGRect(
            x: center.x - size / 2,
            y: center.y - size / 2,
            width: size,
            height: size
        )
        let shape = Path(
            roundedRect: rect,
            cornerRadius: compact ? 14 : 21
        )

        context.fill(
            shape,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: .white.opacity(0.19), location: 0),
                    .init(color: color.opacity(0.15), location: 0.44),
                    .init(color: .black.opacity(0.22), location: 1)
                ]),
                startPoint: CGPoint(
                    x: rect.minX,
                    y: rect.minY
                ),
                endPoint: CGPoint(
                    x: rect.maxX,
                    y: rect.maxY
                )
            )
        )

        context.stroke(
            shape,
            with: .linearGradient(
                Gradient(colors: [
                    .white.opacity(0.38),
                    color.opacity(0.62),
                    .white.opacity(0.07)
                ]),
                startPoint: CGPoint(
                    x: rect.minX,
                    y: rect.minY
                ),
                endPoint: CGPoint(
                    x: rect.maxX,
                    y: rect.maxY
                )
            ),
            lineWidth: compact ? 1.0 : 1.35
        )

        var image = context.resolve(
            Image(systemName: symbol)
        )
        image.shading = .color(color.opacity(0.98))

        let maximumSymbolSide = size * (compact ? 0.46 : 0.43)
        let naturalSize = image.size
        let naturalWidth = max(1, naturalSize.width)
        let naturalHeight = max(1, naturalSize.height)
        let fitScale = min(
            maximumSymbolSide / naturalWidth,
            maximumSymbolSide / naturalHeight
        )
        let fittedSize = CGSize(
            width: naturalWidth * fitScale,
            height: naturalHeight * fitScale
        )
        let symbolRect = CGRect(
            x: center.x - fittedSize.width / 2,
            y: center.y - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
        context.draw(image, in: symbolRect)
    }

    private func drawLabel(
        context: inout GraphicsContext,
        text: String,
        point: CGPoint
    ) {
        let resolved = context.resolve(
            Text(text)
                .font(.caption.bold())
                .foregroundStyle(.primary)
        )
        context.draw(
            resolved,
            at: point,
            anchor: .center
        )
    }
}

private struct CubicCurve {
    let start: CGPoint
    let control1: CGPoint
    let control2: CGPoint
    let end: CGPoint

    func point(at t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * u * start.x
                + 3 * u * u * t * control1.x
                + 3 * u * t * t * control2.x
                + t * t * t * end.x,
            y: u * u * u * start.y
                + 3 * u * u * t * control1.y
                + 3 * u * t * t * control2.y
                + t * t * t * end.y
        )
    }
}

private struct CurveLengthLookup {
    private let parameters: [CGFloat]
    private let lengths: [CGFloat]
    let totalLength: CGFloat

    init(curve: CubicCurve, samples: Int) {
        let count = max(16, samples)
        var parameters: [CGFloat] = [0]
        var lengths: [CGFloat] = [0]
        parameters.reserveCapacity(count + 1)
        lengths.reserveCapacity(count + 1)

        var previous = curve.point(at: 0)
        var total: CGFloat = 0

        for index in 1...count {
            let t = CGFloat(index) / CGFloat(count)
            let point = curve.point(at: t)
            total += hypot(
                point.x - previous.x,
                point.y - previous.y
            )
            parameters.append(t)
            lengths.append(total)
            previous = point
        }

        self.parameters = parameters
        self.lengths = lengths
        totalLength = total
    }

    func parameter(
        forDistance distance: CGFloat
    ) -> CGFloat {
        guard totalLength > 0 else {
            return 0
        }

        let target = min(
            max(0, distance),
            totalLength
        )

        var low = 0
        var high = lengths.count - 1

        while low + 1 < high {
            let middle = (low + high) / 2
            if lengths[middle] < target {
                low = middle
            } else {
                high = middle
            }
        }

        let lowerLength = lengths[low]
        let upperLength = lengths[high]
        let segment = max(
            0.0001,
            upperLength - lowerLength
        )
        let fraction =
            (target - lowerLength) / segment

        return parameters[low]
            + (parameters[high] - parameters[low])
            * fraction
    }
}
