import Foundation

/// Day-of-year arithmetic.
///
/// Every date in the model is an integer day of year, 1...365, and windows
/// **wrap**: toyon ripens from day 301 to day 348, but a winter-fruiting species
/// can have `ripeEnd < ripeStart`. Comparing them directly is the single easiest
/// way to get this wrong, so all reasoning goes through `forward(from:to:)`.
enum DOY {
    static let year = 365

    /// Days from `a` forward to `b`, always in 0..<365.
    static func forward(from a: Int, to b: Int) -> Int {
        ((b - a) % year + year) % year
    }

    static func today(_ date: Date = Date(), calendar: Calendar = .current) -> Int {
        calendar.ordinality(of: .day, in: .year, for: date) ?? 1
    }

    /// Format a day of year for display, using a non-leap reference year so day
    /// 60 is always 1 March.
    static func label(_ doy: Int, calendar: Calendar = .current) -> String {
        var components = DateComponents()
        components.year = 2025
        components.day = doy
        guard let date = calendar.date(from: components) else { return "—" }
        return Self.formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()
}

/// Where a species sits relative to its collection window on a given day.
enum Readiness: Equatable {
    /// Inside the window. `peak` is 1 at the modelled peak, falling to 0 at the edges.
    case now(peak: Double, dayInto: Int, width: Int)
    /// Window opens in `days`.
    case soon(days: Int)
    /// Window closed `days` ago.
    case past(days: Int)

    var isNow: Bool { if case .now = self { return true }; return false }
}

extension Fit {
    /// Classify this fit against a day of year.
    func readiness(on day: Int) -> Readiness {
        let width = max(DOY.forward(from: ripeStart, to: ripeEnd), 1)
        let into = DOY.forward(from: ripeStart, to: day)
        if into <= width {
            let toPeak = DOY.forward(from: ripeStart, to: ripePeak)
            let closeness = 1 - abs(Double(into - toPeak)) / Double(width)
            return .now(peak: max(0, closeness), dayInto: into, width: width)
        }
        let until = DOY.forward(from: day, to: ripeStart)
        let since = DOY.forward(from: ripeEnd, to: day)
        return until <= since ? .soon(days: until) : .past(days: since)
    }

    /// Ranking score. Mirrors the web client so both surfaces order identically:
    /// proximity to peak, how much of it grows nearby, and how well the window is
    /// supported - then penalties for anything you should not be collecting.
    func score(on day: Int, localRecords: Int) -> Double {
        let base: Double
        switch readiness(on: day) {
        case .now(let peak, _, _): base = 1 + peak
        case .soon(let days): base = 0.5 - Double(days) / 200
        case .past: base = 0.2
        }
        let abundance = log1p(Double(localRecords))
        let support = 0.35 + confidence
        let nonNative = establishment == "introduced" ? 0.3 : 1.0
        let rare = sensitive ? 0.15 : 1.0
        return base * abundance * support * nonNative * rare
    }

    /// Windows this wide are a failed fit rather than a long season - typically a
    /// species that flowers near year-round, so the flowering anchor carries no
    /// information. The web client drops these; so do we.
    var isTooVagueToShow: Bool { ripeDays > 200 }

    var readsLate: Bool { (persistence ?? 0) > 0.3 }
}

/// The next ripe window as real dates: the one open now (from today to its end)
/// or else the next to open. Windows may wrap the new year. Same rule as the
/// web client's nextRipeWindow, so both add the same calendar event.
struct RipeWindow: Equatable {
    let start: Date
    let end: Date
    let isOpen: Bool

    static func next(ripeStart: Int, ripeEnd: Int, today: Date = Date(),
                     calendar: Calendar = .current) -> RipeWindow? {
        let today = calendar.startOfDay(for: today)
        let length = DOY.forward(from: ripeStart, to: ripeEnd)
        let year = calendar.component(.year, from: today)
        for y in [year - 1, year, year + 1] {
            guard let jan1 = calendar.date(from: DateComponents(year: y, month: 1, day: 1)),
                  let start = calendar.date(byAdding: .day, value: ripeStart - 1, to: jan1),
                  let end = calendar.date(byAdding: .day, value: length, to: start) else { continue }
            if end >= today { return RipeWindow(start: max(start, today), end: end, isOpen: start <= today) }
        }
        return nil
    }
}
