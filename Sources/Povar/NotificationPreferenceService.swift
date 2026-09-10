import Fluent
import Foundation
import Vapor

enum NotificationPreferenceService {
    /// Whether a proactive (non-transactional) notification may be sent to this user right now.
    /// Order-status updates and other direct replies to a user's own action are never gated here —
    /// only "someone else did something" pushes (new dish from a followed cook, waitlist restock).
    static func shouldSendProactiveNotification(to user: User) -> Bool {
        guard user.notificationsEnabled != false else { return false }
        guard let start = user.quietHoursStart, let end = user.quietHoursEnd else { return true }
        let hour = localHour(at: Date(), utcOffsetMinutes: user.utcOffsetMinutes)
        if start == end { return true }
        if start < end {
            return !(hour >= start && hour < end)
        } else {
            return !(hour >= start || hour < end)
        }
    }

    static let quietHoursPresets: [(label: String, start: Int, end: Int)] = [
        ("22:00 – 08:00", 22, 8),
        ("23:00 – 07:00", 23, 7),
        ("00:00 – 09:00", 0, 9)
    ]
}
