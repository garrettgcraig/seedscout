import Foundation
import UserNotifications

/// Local notifications for the day a lot's stratification ends.
///
/// Stratification comes due months after the work that starts it, which is why
/// it gets missed; the Needs attention list only helps if the app is opened.
/// Rebuilt from the records on every save, so editing or deleting a lot can
/// never leave a stale reminder behind. Matches the web client, which offers a
/// calendar event for the same date instead (browsers cannot schedule a
/// notification months ahead).
enum StratificationReminders {
    private static let prefix = "strat-"
    /// iOS keeps at most 64 pending local notifications per app.
    private static let limit = 60

    static func sync(_ lots: [SeedLot]) {
        let now = Date()
        let cal = Calendar.current
        let upcoming: [(lot: SeedLot, fire: DateComponents, method: String)] = lots.compactMap { lot in
            guard lot.prop.sown.date == nil, let end = lot.lifecycle().stratEnd,
                  let method = lot.prop.stratify.method else { return nil }
            var when = cal.dateComponents([.year, .month, .day], from: end)
            when.hour = 9
            guard let fireDate = cal.date(from: when), fireDate > now else { return nil }
            return (lot, when, method)
        }
        .sorted { (cal.date(from: $0.fire) ?? now) < (cal.date(from: $1.fire) ?? now) }

        Task {
            let center = UNUserNotificationCenter.current()
            let stale = await center.pendingNotificationRequests()
                .map(\.identifier).filter { $0.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: stale)
            guard !upcoming.isEmpty else { return }

            // Ask only once there is something to remind about, so the prompt
            // arrives right after the user sets a stratification, not at launch.
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined:
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            case .authorized, .provisional, .ephemeral:
                break
            default:
                return
            }

            for item in upcoming.prefix(limit) {
                let content = UNMutableNotificationContent()
                content.title = "Ready to sow: \(item.lot.displayName)"
                content.body = "\(item.lot.batchCode) finished \(item.method) stratification today."
                content.sound = .default
                let trigger = UNCalendarNotificationTrigger(dateMatching: item.fire, repeats: false)
                try? await center.add(UNNotificationRequest(identifier: prefix + item.lot.id,
                                                            content: content, trigger: trigger))
            }
        }
    }
}
