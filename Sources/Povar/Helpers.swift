import Fluent
import Foundation
import NIOConcurrencyHelpers
import Vapor

func isCommand(_ text: String) -> Bool {
    text.hasPrefix("/")
}

/// URL Mini App, показываемый в боте (кнопка «Открыть каталог»).
var miniAppURL: String {
    Environment.get("MINI_APP_URL") ?? "https://povar.serjey.com/app/"
}

/// Ник бота, используемый для ссылок t.me/<bot>?start=...
var botUsername: String {
    Environment.get("BOT_USERNAME") ?? "uncle_masha_bot"
}

enum DishType: String, CaseIterable {
    case breakfast
    case lunch
    case dinner
    case dessert
    case drink

    var title: String {
        switch self {
        case .breakfast: return "Завтрак"
        case .lunch: return "Обед"
        case .dinner: return "Ужин"
        case .dessert: return "Десерт"
        case .drink: return "Напиток"
        }
    }

    static func from(_ raw: String?) -> DishType? {
        guard let raw else { return nil }
        return DishType(rawValue: raw)
    }
}

func dishTypeTitle(_ raw: String?) -> String? {
    DishType.from(raw)?.title
}

func generateReferralCode(length: Int = 8) -> String {
    let letters = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    return String((0..<length).compactMap { _ in letters.randomElement() })
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

/// Telegram-клиент для отправки уведомлений из Mini App API.
func makeTelegramClient(_ app: Application) -> TelegramBotClient? {
    guard let token = Environment.get("TELEGRAM_BOT_TOKEN"), !token.isEmpty else { return nil }
    return TelegramBotClient(app: app, botToken: token)
}

/// Потокобезопасная коробка для результата операции с таймаутом.
private final class TimeoutBox<T>: @unchecked Sendable {
    private let lock = NIOLock()
    private var _result: T?
    private var _finished = false
    private var _error: Error?

    func finish(_ value: T) {
        lock.withLock {
            if !_finished {
                _finished = true
                _result = value
            }
        }
    }

    func fail(_ error: Error) {
        lock.withLock {
            if !_finished {
                _finished = true
                _error = error
            }
        }
    }

    var isFinished: Bool { lock.withLock { _finished } }
    var error: Error? { lock.withLock { _error } }
    var result: T? { lock.withLock { _result } }
}

/// Выполняет операцию с таймаутом. Возвращает nil, если операция не успела.
/// Нужен, потому что у HTTP-клиента Vapor нет таймаута по умолчанию,
/// а task group ждёт все дочерние задачи и не подходит для обрыва зависшего запроса.
func withTimeout<T: Sendable>(
    seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T? {
    let box = TimeoutBox<T>()
    let task = Task {
        do {
            box.finish(try await operation())
        } catch {
            box.fail(error)
        }
    }

    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(seconds)
    while clock.now < deadline {
        if box.isFinished { break }
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    if !box.isFinished {
        task.cancel()
        return nil
    }
    if let error = box.error {
        throw error
    }
    return box.result
}

/// URL фото блюда: локальный файл из Mini App или прокси Telegram-файла.
func photoURL(path: String?, fileID: String?) -> String? {
    if let path, !path.isEmpty {
        return "/uploads/\(path)"
    }
    if let fileID, !fileID.isEmpty {
        return "/api/v1/uploads/\(fileID)"
    }
    return nil
}

/// Локальный час пользователя по его смещению от UTC (в минутах).
/// Без смещения используется серверное время.
func localHour(at date: Date, utcOffsetMinutes: Int?) -> Int {
    guard let offset = utcOffsetMinutes else {
        return Calendar.current.component(.hour, from: date)
    }
    var utcCalendar = Calendar(identifier: .gregorian)
    utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    let utcHour = utcCalendar.component(.hour, from: date)
    let totalMinutes = utcHour * 60 + offset
    return ((totalMinutes / 60) % 24 + 24) % 24
}

/// Простой in-memory кэш URL файлов Telegram (file_id → URL),
/// чтобы не дёргать getFile на каждый запрос фото.
actor PhotoURLCache {
    static let shared = PhotoURLCache()

    private var storage: [String: String] = [:]
    private var order: [String] = []
    private let maxCount = 300

    func get(_ key: String) -> String? {
        storage[key]
    }

    func set(_ key: String, _ value: String) {
        if storage[key] == nil {
            order.append(key)
        }
        storage[key] = value
        while order.count > maxCount {
            let oldest = order.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }
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
