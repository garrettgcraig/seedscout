import SwiftUI

struct SpeciesRow: View {
    let fit: Fit
    let day: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(fit.displayName)
                        .font(.headline)
                    Text(fit.name)
                        .font(.subheadline).italic()
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(statusText).font(.subheadline.weight(.semibold))
                        .foregroundStyle(statusColor)
                    Text("\(DOY.label(fit.ripeStart)) – \(DOY.label(fit.ripeEnd))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize()
            }

            TimelineBar(fit: fit, day: day)

            FlowRow(spacing: 5) {
                if fit.sensitive { Tag("rare — do not collect", .alert) }
                if fit.isIntroduced { Tag("non-native", .neutral) }
                if let f = fit.family { Tag(f, .family(f)) }
                Tag("\(fit.localRecords) record\(fit.localRecords == 1 ? "" : "s") nearby",
                    fit.localRecords >= 8 ? .accent : .neutral)
                if let lo = fit.elevLo, let hi = fit.elevHi { Tag("\(lo)–\(hi) m", .neutral) }
                if fit.confidence < 0.5 { Tag("low confidence", .warn) }
                if fit.readsLate { Tag("fruit persists — may read late", .warn) }
                if let p = fit.provenance { Tag(p, .neutral) }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        switch fit.readiness(on: day) {
        case .now(let peak, _, _): return peak > 0.55 ? "peak now" : "in window"
        case .soon(let d): return "in ~\(d) d"
        case .past(let d): return "\(d) d ago"
        }
    }

    private var statusColor: Color {
        switch fit.readiness(on: day) {
        case .now: return .seedAccent
        case .soon: return .orange
        case .past: return .secondary
        }
    }
}

// MARK: - Tags

struct Tag: View {
    enum Kind {
        case accent, neutral, warn, alert
        case family(String)
    }

    let text: String
    let kind: Kind
    init(_ text: String, _ kind: Kind) { self.text = text; self.kind = kind }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(background, in: Capsule())
            .foregroundStyle(foreground)
            .overlay(strokeOverlay)
    }

    @ViewBuilder private var strokeOverlay: some View {
        if case .family = kind { Capsule().strokeBorder(foreground.opacity(0.35), lineWidth: 1) }
    }

    private var background: Color {
        switch kind {
        case .accent: return .seedAccent.opacity(0.14)
        case .neutral: return .secondary.opacity(0.14)
        case .warn: return .orange.opacity(0.16)
        case .alert: return .red.opacity(0.14)
        case .family(let f): return Self.hue(for: f).opacity(0.16)
        }
    }

    private var foreground: Color {
        switch kind {
        case .accent: return .seedAccent
        case .neutral: return .secondary
        case .warn: return .orange
        case .alert: return .red
        case .family(let f): return Self.hue(for: f)
        }
    }

    /// Stable per-family colour. Hashing the name keeps a family the same colour
    /// everywhere without shipping a lookup table.
    static func hue(for family: String) -> Color {
        var h: UInt64 = 5381
        for b in family.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Color(hue: Double(h % 360) / 360, saturation: 0.55, brightness: 0.55)
    }
}

/// Wrapping tag layout. `Layout` avoids the nested-GeometryReader approach,
/// which measures badly inside a `List` row.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += lineHeight + spacing; lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += lineHeight + spacing; lineHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
