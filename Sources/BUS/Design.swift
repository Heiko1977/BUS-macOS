import SwiftUI

enum DashboardTileLayout {
    static let spacing: CGFloat = 14
    static let metricSpacing: CGFloat = 12
    // Includes the 16pt GlassCard inset so the score tile aligns exactly
    // with the two-row metric grid beside it.
    static let scoreContentHeight: CGFloat = 238
    static let metricContentHeight: CGFloat = 97
    static let compactBatteryChartHeight: CGFloat = 220
    static let compactPowerChartHeight: CGFloat = 220
    static let regularBatteryChartHeight: CGFloat = 264
    static let regularPowerChartHeight: CGFloat = 264
    // The power chart has a legend below the plot; both chart cards use the
    // same outer height so their borders always meet on one horizontal line.
    static let compactChartCardHeight: CGFloat = 322
    static let regularChartCardHeight: CGFloat = 374
    static let analysisContentHeight: CGFloat = 220
    static let topConsumersContentHeight: CGFloat = 190
    static let privacyContentHeight: CGFloat = 190
}

/// A compositor-friendly Liquid Glass surface for scrolling content.
///
/// SwiftUI's live `Material` backdrop has to sample and blur the window behind
/// every card while it moves. A dashboard with many cards therefore becomes
/// expensive during trackpad scrolling. This surface preserves the layered
/// glass appearance with static, color-scheme-aware gradients that the window
/// compositor can move without rebuilding a backdrop filter.
struct StaticLiquidGlassSurface: View {
    @Environment(\.colorScheme) private var colorScheme

    let cornerRadius: CGFloat
    var accent: Color = .mint
    var intensity: Double = 1

    private var baseColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.105, green: 0.125, blue: 0.145)
                    .opacity(0.94),
                Color(red: 0.070, green: 0.085, blue: 0.105)
                    .opacity(0.92),
                accent.opacity(0.045 * intensity)
            ]
        }

        return [
            Color.white.opacity(0.92),
            Color(red: 0.91, green: 0.94, blue: 0.96).opacity(0.86),
            accent.opacity(0.055 * intensity)
        ]
    }

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: cornerRadius,
            style: .continuous
        )

        shape
            .fill(
                LinearGradient(
                    colors: baseColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                shape.fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.13 * intensity),
                            .clear,
                            accent.opacity(0.018 * intensity)
                        ],
                        startPoint: .top,
                        endPoint: .bottomTrailing
                    )
                )
            }
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: [
                            .white.opacity(colorScheme == .dark ? 0.28 : 0.72),
                            .white.opacity(0.06),
                            accent.opacity(0.14 * intensity)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .allowsHitTesting(false)
    }
}

struct GlassCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(
                maxWidth: .infinity,
                alignment: .topLeading
            )
            .background {
                StaticLiquidGlassSurface(cornerRadius: 20)
            }
            .overlay(alignment: .top) {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                .white.opacity(0.27),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 180, height: 1)
                    .padding(.top, 1)
                    .allowsHitTesting(false)
            }
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 20,
                    style: .continuous
                )
            )
    }
}

struct MetricCard: View {
    let icon: String
    let title: String
    let value: String
    var detail: String? = nil

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Color.green)

                Text(value)
                    .font(.title2.bold())
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(
                maxWidth: .infinity,
                minHeight: DashboardTileLayout.metricContentHeight,
                alignment: .topLeading
            )
        }
        .allowsHitTesting(false)
    }
}

struct ScoreRing: View {
    let score: Int
    let label: String
    var diameter: CGFloat = 184

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 15)

            Circle()
                .trim(from: 0, to: Double(score) / 100)
                .stroke(
                    AngularGradient(
                        colors: [.green, .mint, .green],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 15, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            VStack(spacing: 2) {
                Text("BUS")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                Text("\(score)")
                    .font(.system(size: diameter * 0.25, weight: .bold, design: .rounded))
                    .monospacedDigit()

                Text(label)
                    .font(.subheadline.bold())
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
    }
}
