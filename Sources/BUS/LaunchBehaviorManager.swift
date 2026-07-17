import Foundation

@MainActor
final class LaunchBehaviorManager: ObservableObject {
    static let shared = LaunchBehaviorManager()

    @Published var startHiddenAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(
                startHiddenAtLogin,
                forKey: Self.startHiddenKey
            )
        }
    }

    private static let startHiddenKey = "BUS.startHiddenAtLogin"

    private init() {
        startHiddenAtLogin = UserDefaults.standard.bool(
            forKey: Self.startHiddenKey
        )
    }
}

