import EventKit
import EventKitUI
import SwiftUI

extension RipeWindow {
    static func next(for fit: Fit, today: Date = Date(), calendar: Calendar = .current) -> RipeWindow? {
        next(ripeStart: fit.ripeStart, ripeEnd: fit.ripeEnd, today: today, calendar: calendar)
    }
}

/// Apple's own Add Event sheet, prefilled. Since iOS 17 it runs out of process
/// and needs no calendar permission, so the app never asks for calendar access.
struct RipeWindowEventSheet: UIViewControllerRepresentable {
    let fit: Fit
    let window: RipeWindow
    let placeLabel: String
    let cue: String?
    let link: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = "Seed likely ripe: \(fit.displayName)"
        event.isAllDay = true
        event.startDate = window.start
        event.endDate = window.end
        event.location = placeLabel
        let how = cue.map { " How to tell: \($0)" } ?? ""
        event.notes = "\(fit.name) near \(placeLabel). Modeled window \(DOY.label(fit.ripeStart)) to "
            + "\(DOY.label(fit.ripeEnd)), peak \(DOY.label(fit.ripePeak)), "
            + "\(Int((fit.confidence * 100).rounded()))% confidence.\(how) Check the fruit before collecting."
        event.url = link
        // A 9 am nudge on opening day, unless the window is already open.
        if !window.isOpen { event.addAlarm(EKAlarm(relativeOffset: 9 * 3600)) }

        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        func eventEditViewController(_ controller: EKEventEditViewController,
                                     didCompleteWith action: EKEventEditViewAction) {
            controller.dismiss(animated: true)
        }
    }
}
