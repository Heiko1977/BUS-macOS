import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var l: Localizer

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DashboardTileLayout.spacing) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l.t("history"))
                            .font(.system(size: 27, weight: .bold))
                        Text(l.t("lastHours"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if proxy.size.width >= 980 {
                        HStack(alignment: .top, spacing: DashboardTileLayout.spacing) {
                            BatteryChartCard(compact: false)
                            PowerChartCard(compact: false)
                        }
                    } else {
                        VStack(spacing: DashboardTileLayout.spacing) {
                            BatteryChartCard(compact: false)
                            PowerChartCard(compact: false)
                        }
                    }

                    if proxy.size.width >= 820 {
                        HStack(alignment: .top, spacing: DashboardTileLayout.spacing) {
                            RuntimeStatisticsCard()
                            ScoreBreakdownCard()
                        }
                    } else {
                        VStack(spacing: DashboardTileLayout.spacing) {
                            RuntimeStatisticsCard()
                            ScoreBreakdownCard()
                        }
                    }

                    RuntimeSessionsView()
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                // History is informational. Let the enclosing NSScrollView
                // receive trackpad events without traversing every label,
                // divider and chart in the SwiftUI responder tree.
                .allowsHitTesting(false)
            }
        }
    }
}
