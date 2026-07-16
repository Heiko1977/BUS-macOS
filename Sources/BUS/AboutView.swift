import AppKit
import SwiftUI

struct AboutView: View {
    @EnvironmentObject private var l: Localizer

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 150, height: 150)
                .shadow(radius: 18)
            Text("BUS").font(.system(size: 52, weight: .bold, design: .rounded))
            Text("Battery Usage Score").font(.title2).foregroundStyle(.secondary)
            Text("\(AppMetadata.license) · \(AppMetadata.versionLabel)").font(.headline).foregroundStyle(.green)
            Text(AppMetadata.creditLine).font(.title3).multilineTextAlignment(.center)
            Label(l.t("privacyTitle"), systemImage: "lock.shield.fill")
                .foregroundStyle(.green).font(.headline)
            Text(l.t("privacyText"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
