import SwiftUI

/// A species' year at a glance: when it flowers, when fruit is present, when
/// seed is likely ripe, and where today falls.
///
/// Drawn in a single `Canvas` rather than as stacked shapes. A results list can
/// hold sixty of these, and one draw call per row keeps scrolling smooth where
/// a dozen overlapping views per row would not.
struct TimelineBar: View {
    let fit: Fit
    let day: Int

    private let trackHeight: CGFloat = 7
    private let gap: CGFloat = 3

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            let w = size.width
            func x(_ doy: Int) -> CGFloat { CGFloat(doy - 1) / CGFloat(DOY.year) * w }

            /// Draw a span that may wrap past 31 December as one or two bars.
            func span(_ start: Int, _ end: Int, y: CGFloat, h: CGFloat, color: Color) {
                let a = x(start), b = x(end)
                var rects: [CGRect] = []
                if b >= a {
                    rects.append(CGRect(x: a, y: y, width: max(b - a, 2), height: h))
                } else {
                    rects.append(CGRect(x: a, y: y, width: w - a, height: h))
                    rects.append(CGRect(x: 0, y: y, width: b, height: h))
                }
                for r in rects {
                    ctx.fill(Path(roundedRect: r, cornerRadius: h / 2), with: .color(color))
                }
            }

            // Month gridlines, faint, purely for orientation.
            var grid = Path()
            for m in 1..<12 {
                let gx = CGFloat(m) / 12 * w
                grid.move(to: CGPoint(x: gx, y: 0))
                grid.addLine(to: CGPoint(x: gx, y: size.height))
            }
            ctx.stroke(grid, with: .color(.secondary.opacity(0.18)), lineWidth: 0.5)

            var y: CGFloat = 0
            if let fs = fit.flowerStart, let fe = fit.flowerEnd {
                span(fs, fe, y: y, h: trackHeight, color: .flowerTint)
            }
            y += trackHeight + gap
            if let fs = fit.fruitStart, let fe = fit.fruitEnd {
                span(fs, fe, y: y, h: trackHeight, color: .fruitTint)
            }
            y += trackHeight + gap
            span(fit.ripeStart, fit.ripeEnd, y: y, h: trackHeight + 2, color: .ripeTint)

            // Today, drawn last so it sits above every band.
            let tx = x(day)
            ctx.fill(
                Path(CGRect(x: tx - 1, y: -1, width: 2, height: size.height + 2)),
                with: .color(.primary.opacity(0.75))
            )
        }
        .frame(height: trackHeight * 3 + gap * 2 + 2)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        "Seed likely ripe \(DOY.label(fit.ripeStart)) to \(DOY.label(fit.ripeEnd)), "
        + "peak \(DOY.label(fit.ripePeak))"
    }
}

extension Color {
    static let flowerTint = Color(red: 0.79, green: 0.66, blue: 0.82)
    static let fruitTint = Color(red: 0.72, green: 0.82, blue: 0.66)
    static let ripeTint = Color(red: 0.25, green: 0.42, blue: 0.18)
    static let seedAccent = Color(red: 0.25, green: 0.42, blue: 0.18)
}
