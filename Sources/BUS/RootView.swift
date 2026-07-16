import SwiftUI

enum MainSection: String, CaseIterable, Identifiable {
    case overview, history, consumers, profiles, settings, about
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "house.fill"
        case .history: return "chart.xyaxis.line"
        case .consumers: return "bolt.fill"
        case .profiles: return "person.crop.circle.badge.checkmark"
        case .settings: return "gearshape.fill"
        case .about: return "info.circle.fill"
        }
    }
}

final class RootViewState: ObservableObject {
    @Published var selection: MainSection = .overview
}

struct RootView: View {
    @EnvironmentObject private var localizer: Localizer
    @StateObject private var state = RootViewState()
    private let monitor = EnergyMonitor.shared

    var body: some View {
        NavigationSplitView {
            List(MainSection.allCases, selection: $state.selection) { section in
                Label(localizer.t(section.rawValue), systemImage: section.icon)
                    .tag(section)
            }
            .navigationTitle("BUS")
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Divider()
                    Label(localizer.t("offlineBadge"), systemImage: "lock.shield.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text(AppMetadata.versionLabel).font(.caption2).foregroundStyle(.secondary)
                }
                .padding()
            }
        } detail: {
            Group {
                switch state.selection {
                case .overview: OverviewView()
                case .history: HistoryView()
                case .consumers: ConsumersView()
                case .profiles: ProfilesView()
                case .settings: BUSSettingsView()
                case .about: AboutView()
                }
            }
            .environmentObject(monitor)
            .environmentObject(localizer)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .busOpenSection)
        ) { notification in
            guard let raw = notification.userInfo?["section"] as? String,
                  let section = MainSection(rawValue: raw) else {
                return
            }
            state.selection = section
        }
        .sheet(isPresented: Binding(
            get: { !localizer.hasCompletedLanguageSelection },
            set: { if !$0 { localizer.hasCompletedLanguageSelection = true } }
        )) {
            LanguageOnboardingView()
                .environmentObject(localizer)
                .interactiveDismissDisabled()
        }
    }
}
