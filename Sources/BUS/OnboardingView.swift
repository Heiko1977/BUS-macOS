import AppKit
import SwiftUI

struct LanguageOnboardingView: View {
    @EnvironmentObject private var l: Localizer

    var body: some View {
        VStack(spacing: 24) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 120, height: 120)
            Text(l.t("welcome")).font(.largeTitle.bold())
            Text(l.t("chooseLanguage")).font(.title3).foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(AppLanguage.allCases) { language in
                    Button {
                        l.language = language
                    } label: {
                        HStack {
                            Text(language.symbol).font(.title2)
                            Text(language.label)
                            Spacer()
                            if l.language == language { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        }
                        .padding(12)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }

            Label(l.t("privacyText"), systemImage: "lock.shield.fill")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(l.t("continue")) { l.hasCompletedLanguageSelection = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(32)
        .frame(width: 560)
    }
}
