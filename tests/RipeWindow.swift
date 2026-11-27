import Foundation

// swiftc tests/RipeWindow.swift ios/SeedFinder/Data/Phenology.swift ios/SeedFinder/Data/Models.swift -o /tmp/ripe && /tmp/ripe
@main struct RipeWindowTest {
    static func main() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        func day(_ s: String) -> Date {
            let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd"
            return f.date(from: s)!
        }
        func iso(_ d: Date) -> String {
            let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd"
            return f.string(from: d)
        }
        // Toyon-like: Oct 21 (294) to Dec 10 (344), asked on Nov 26: open, from today.
        let open = RipeWindow.next(ripeStart: 294, ripeEnd: 344, today: day("2026-11-26"), calendar: cal)!
        precondition(open.isOpen && iso(open.start) == "2026-11-26" && iso(open.end) == "2026-12-10")
        // Same species asked in June: the next one, not yet open.
        let ahead = RipeWindow.next(ripeStart: 294, ripeEnd: 344, today: day("2026-06-01"), calendar: cal)!
        precondition(!ahead.isOpen && iso(ahead.start) == "2026-10-21" && iso(ahead.end) == "2026-12-10")
        // Asked after it closed: next year's.
        let after = RipeWindow.next(ripeStart: 294, ripeEnd: 344, today: day("2026-12-20"), calendar: cal)!
        precondition(!after.isOpen && iso(after.start) == "2027-10-21")
        // Wrapping the new year (Dec 8 to Jan 5), asked on Jan 2: last year's window, still open.
        let wrap = RipeWindow.next(ripeStart: 342, ripeEnd: 5, today: day("2027-01-02"), calendar: cal)!
        precondition(wrap.isOpen && iso(wrap.start) == "2027-01-02" && iso(wrap.end) == "2027-01-05")
        // Same window asked in late November: opens Dec 8 and ends in January.
        let wrapAhead = RipeWindow.next(ripeStart: 342, ripeEnd: 5, today: day("2026-11-26"), calendar: cal)!
        precondition(!wrapAhead.isOpen && iso(wrapAhead.start) == "2026-12-08" && iso(wrapAhead.end) == "2027-01-05")
        print("PASS: open window, upcoming window, closed window, new-year wrap (open and upcoming)")
    }
}
