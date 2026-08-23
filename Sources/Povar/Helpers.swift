import Fluent
import Foundation
import Vapor

func isCommand(_ text: String) -> Bool {
    text.hasPrefix("/")
}

func formatPrice(_ price: Double) -> String {
    String(format: "%.2f", price)
}

func findTelegramIDForUser(_ userID: UUID, on db: Database) async throws -> Int64? {
    try await User.query(on: db)
        .filter(\.$id == userID)
        .first()?
        .telegramID
}

func formatTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

func dayLabel(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
        return "Сегодня"
    }
    if calendar.isDateInTomorrow(date) {
        return "Завтра"
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.dateFormat = "EEE dd.MM"
    return formatter.string(from: date).capitalized
}

func nextDays(count: Int) -> [Date] {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
}

func todayWeekdayName() -> String {
    let weekday = Calendar.current.component(.weekday, from: Date())
    let names = ["вс", "пн", "вт", "ср", "чт", "пт", "сб"]
    return names[(weekday - 1 + 7) % 7]
}

func isToday(_ dish: Dish) -> Bool {
    dish.cookedDate == formatDate(Date())
}

func formatQuantity(_ quantity: Int) -> String {
    switch quantity {
    case 1: return "1 порция"
    case 2, 3, 4: return "\(quantity) порции"
    default: return "\(quantity) порций"
    }
}

func bonusFor(orderTotal: Double, hasReview: Bool) -> Int {
    var stars = Int((orderTotal / 100).rounded(.down))
    if hasReview { stars += 5 }
    return max(stars, 0)
}
