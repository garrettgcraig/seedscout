import SwiftUI

struct SpeciesRow: View {
    let fit: Fit
    let day: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(fit.displayName)
                        .font(Typography.heading(17))
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

            // Two tiers, matching the web client: facts as one quiet line,
            // cautions on their own line in the caution color. As a row of pills
            // a rare-species warning carried the same weight as a family name.
            factsLine
            if !cautions.isEmpty {
                Label {
                    Text(cautions.joined(separator: " "))
                        .fontWeight(fit.sensitive ? .semibold : .regular)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.footnote)
                .foregroundStyle(fit.sensitive ? Color.red : Color.orange)
            }
        }
        .padding(.vertical, 4)
    }


    private var factsLine: some View {
        var parts: [Text] = []
        if let f = fit.family {
            parts.append(Text(f).foregroundStyle(FamilyColor.hue(for: f)).fontWeight(.semibold))
        }
        if fit.isIntroduced { parts.append(Text("non-native")) }
        parts.append(Text("\(fit.localRecords)\u{00A0}record\(fit.localRecords == 1 ? "" : "s")\u{00A0}nearby"))
        // Word joiner after the dash and a no-break space before the unit, so the
        // range never splits as "41– / 577 m".
        if let lo = fit.elevLo, let hi = fit.elevHi { parts.append(Text("\(lo)–\u{2060}\(hi)\u{00A0}m")) }
        parts.append(Text("\(Int((fit.confidence * 100).rounded()))%\u{00A0}confidence"))
        let joined = parts.dropFirst().reduce(parts.first ?? Text("")) { $0 + Text("  ·  ").foregroundStyle(.tertiary) + $1 }
        return joined.font(.footnote).foregroundStyle(.secondary).monospacedDigit()
    }

    private var cautions: [String] {
        var c: [String] = []
        if fit.sensitive { c.append("Rare — do not collect.") }
        if fit.confidence < 0.5 { c.append("Low confidence.") }
        if fit.readsLate { c.append("Fruit persists, so the window may read late.") }
        if let p = fit.provenance { c.append(p.prefix(1).uppercased() + p.dropFirst() + ".") }
        return c
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

// MARK: - Family color

/// Stable per-family color. Hashing the name keeps a family the same color
/// everywhere without shipping a lookup table.
enum FamilyColor {
    static func hue(for family: String) -> Color {
        var h: UInt64 = 5381
        for b in family.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Color(hue: Double(h % 360) / 360, saturation: 0.55, brightness: 0.55)
    }
}
