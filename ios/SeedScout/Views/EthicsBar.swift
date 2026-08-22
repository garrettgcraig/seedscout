import SwiftUI

/// Collection guidance, shown as a dismissible bar above the content.
///
/// Dismissal is remembered. That is only acceptable because the same guidance is
/// repeated in the log sheet at the moment you actually record a collection, and
/// rare species carry their own inline warning on the species page - so hiding
/// this does not remove the warning from the path that matters.
struct EthicsBar: View {
    @AppStorage("ethicsBarDismissed") private var dismissed = false

    private static let message: LocalizedStringKey = "**Before you collect.** Take from populations of **30+ plants**, never more than **30% of the available seed**, and get landowner or agency permission first — collecting is prohibited in most parks and preserves without a permit. Species flagged **rare** should not be collected at all." 

    var body: some View {
        if !dismissed {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .padding(.top, 1)

                // One literal, deliberately. Text only parses markdown when given a
                // LocalizedStringKey, and concatenating with + selects the plain
                // String initialiser instead - which renders the asterisks.
                Text(Self.message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    withAnimation(.easeOut(duration: 0.18)) { dismissed = true }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss collection guidance")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.orange.opacity(0.12))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.orange.opacity(0.35)).frame(height: 0.5)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
