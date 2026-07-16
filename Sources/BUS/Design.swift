import SwiftUI

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
                ZStack {
                    RoundedRectangle(
                        cornerRadius: 20,
                        style: .continuous
                    )
                    .fill(.ultraThinMaterial)

                    LinearGradient(
                        colors: [
                            .white.opacity(0.105),
                            .white.opacity(0.024),
                            .mint.opacity(0.032)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: 20,
                            style: .continuous
                        )
                    )
                }
            }
            .overlay {
                RoundedRectangle(
                    cornerRadius: 20,
                    style: .continuous
                )
                .stroke(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.31),
                            .white.opacity(0.065),
                            .mint.opacity(0.115)
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
                                .white.opacity(0.27),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 180, height: 1)
                    .padding(.top, 1)
            }
            .shadow(
                color: .black.opacity(0.18),
                radius: 16,
                y: 8
            )
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
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        }
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
        .animation(.easeInOut(duration: 0.45), value: score)
    }
}
