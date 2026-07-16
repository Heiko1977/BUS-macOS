import SwiftUI

/// A deliberately static surface for charts. Chart cards are informational
/// and do not need pointer handling. Removing their complete subtree from
/// SwiftUI hit testing avoids expensive responder-tree traversal while the
/// enclosing ScrollView processes trackpad events.
struct PerformanceChartCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.black.opacity(0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            // `drawingGroup` created an off-screen Metal surface which had to
            // be recomposited during every scroll frame. The Canvas already
            // draws as a single layer, so rasterizing the whole card adds cost.
            .allowsHitTesting(false)
    }
}
