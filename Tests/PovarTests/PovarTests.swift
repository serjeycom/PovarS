import Foundation
import Testing
import VaporTesting
import XCTVapor
@testable import Povar

// MARK: - Unit: статусы заказов

@Test func orderStatusTitles() {
    #expect(statusTitle(.new) == "Новый")
    #expect(statusTitle(.accepted) == "Принят")
    #expect(statusTitle(.cooking) == "Готовится")
    #expect(statusTitle(.ready) == "Готов")
    #expect(statusTitle(.onTheWay) == "В пути")
    #expect(statusTitle(.delivered) == "Доставлен")
    #expect(statusTitle(.cancelled) == "Отменен")
}

@Test func orderStatusTransitions() {
    #expect(nextStatuses(for: .new) == [.accepted])
    #expect(nextStatuses(for: .accepted) == [.cooking])
    #expect(nextStatuses(for: .cooking) == [.ready])
    #expect(nextStatuses(for: .ready).contains(.onTheWay))
    #expect(nextStatuses(for: .ready).contains(.delivered))
    #expect(nextStatuses(for: .onTheWay) == [.delivered])
    #expect(nextStatuses(for: .delivered).isEmpty)
    #expect(nextStatuses(for: .cancelled).isEmpty)

    #expect(isAllowedTransition(from: .new, to: .accepted))
    #expect(!isAllowedTransition(from: .new, to: .ready))
    #expect(!isAllowedTransition(from: .cooking, to: .accepted))
}

@Test func clientCancelableStatuses() {
    #expect(isClientCancelable(status: .new))
    #expect(isClientCancelable(status: .accepted))
    #expect(isClientCancelable(status: .onTheWay))
    #expect(!isClientCancelable(status: .cooking))
    #expect(!isClientCancelable(status: .ready))
    #expect(!isClientCancelable(status: .delivered))
    #expect(!isClientCancelable(status: .cancelled))
}

// MARK: - Unit: категории блюд

@Test func dishTypes() {
    #expect(DishType.lunch.title == "Обед")
    #expect(DishType.from("dessert") == .dessert)
    #expect(DishType.from(nil) == nil)
    #expect(DishType.from("unknown") == nil)
    #expect(dishTypeTitle("breakfast") == "Завтрак")
    #expect(DishType.allCases.count == 5)
}

// MARK: - Unit: форматирование и утилиты

@Test func priceFormatting() {
    #expect(formatPrice(350) == "350.00")
    #expect(formatPrice(99.9) == "99.90")
}

@Test func quantityFormatting() {
    #expect(formatQuantity(1) == "1 порция")
    #expect(formatQuantity(3) == "3 порции")
    #expect(formatQuantity(11) == "11 порций")
}

@Test func starsConversion() {
    #expect(priceToStars(0) == 1)
    #expect(priceToStars(350) == 35)
    #expect(priceToStars(341) == 35)
}

@Test func bonusCalculation() {
    #expect(bonusFor(orderTotal: 350, hasReview: false) == 3)
    #expect(bonusFor(orderTotal: 350, hasReview: true) == 8)
    #expect(bonusFor(orderTotal: 10, hasReview: false) == 0)
}

@Test func referralCode() {
    let code = generateReferralCode()
    #expect(code.count == 8)
    let allowed = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    #expect(code.allSatisfy { allowed.contains($0) })
    #expect(generateReferralCode(length: 6).count == 6)
}

@Test func dishToday() {
    let dish = Dish()
    dish.cookedDate = formatDate(Date())
    #expect(isToday(dish))

    dish.cookedDate = "2000-01-01"
    #expect(!isToday(dish))
}

@Test func photoURLSelection() {
    #expect(photoURL(path: "abc.jpg", fileID: nil) == "/uploads/abc.jpg")
    #expect(photoURL(path: nil, fileID: "AgACAgIAA") == "/api/v1/uploads/AgACAgIAA")
    #expect(photoURL(path: "abc.jpg", fileID: "AgACAgIAA") == "/uploads/abc.jpg")
    #expect(photoURL(path: "", fileID: nil) == nil)
}

// MARK: - Unit: часовые пояса и тихие часы

@Test func localHourCalculation() {
    // 12:00 UTC + 3 часа (Москва) = 15
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let noonUTC = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!

    #expect(localHour(at: noonUTC, utcOffsetMinutes: 180) == 15)
    // 00:30 UTC - 5 часов (Нью-Йорк) = 19:30 предыдущего дня → час 19
    let midnight30 = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 0, minute: 30))!
    #expect(localHour(at: midnight30, utcOffsetMinutes: -300) == 19)
    // Без смещения — серверный час (любое значение в диапазоне 0...23)
    let fallback = localHour(at: noonUTC, utcOffsetMinutes: nil)
    #expect((0...23).contains(fallback))
    // Границы перехода через полночь
    let lateUTC = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 23))!
    #expect(localHour(at: lateUTC, utcOffsetMinutes: 180) == 2)
}

// MARK: - Unit: настройки уведомлений

@Test func notificationPreferences() {
    let user = User()
    user.notificationsEnabled = false
    #expect(!NotificationPreferenceService.shouldSendProactiveNotification(to: user))

    user.notificationsEnabled = true
    user.quietHoursStart = nil
    user.quietHoursEnd = nil
    #expect(NotificationPreferenceService.shouldSendProactiveNotification(to: user))

    // start == end означает «без ограничений»
    user.quietHoursStart = 5
    user.quietHoursEnd = 5
    #expect(NotificationPreferenceService.shouldSendProactiveNotification(to: user))

    // Тихие часы с учётом часового пояса пользователя не падают на любых значениях
    user.utcOffsetMinutes = 180
    user.quietHoursStart = 22
    user.quietHoursEnd = 8
    _ = NotificationPreferenceService.shouldSendProactiveNotification(to: user)
    #expect(true)
}

// MARK: - Integration: API-смоук на in-memory SQLite

@Test func apiSmoke() async throws {
    let app = try await Application.make(.testing)
    defer { Task { try? await app.asyncShutdown() } }

    app.databases.use(.sqlite(.memory), as: .sqlite)
    app.sessions.use(.memory)
    app.middleware.use(app.sessions.middleware)
    try registerMigrations(app)
    try await app.autoMigrate()
    try routes(app)

    // Health
    try await app.testing().test(.GET, "/health") { res async in
        #expect(res.status == .ok)
    }

    // Публичный каталог: пустая база → пустой список
    try await app.testing().test(.GET, "/api/v1/browse") { res async in
        #expect(res.status == .ok)
        expectContent(BrowseResponseDTO.self, res) { dto in
            #expect(dto.dishes.isEmpty)
            #expect(dto.page == 0)
            #expect(!dto.hasNext)
        }
    }

    // Публичный список городов
    try await app.testing().test(.GET, "/api/v1/cities") { res async in
        #expect(res.status == .ok)
        expectContent([String].self, res) { cities in
            #expect(cities.isEmpty)
        }
    }

    // Авторизованные endpoint'ы без initData → 401, сервер не падает
    try await app.testing().test(.GET, "/api/v1/me") { res async in
        #expect(res.status == .unauthorized)
    }
    try await app.testing().test(.GET, "/api/v1/cart") { res async in
        #expect(res.status == .unauthorized)
    }
    try await app.testing().test(.GET, "/api/v1/orders") { res async in
        #expect(res.status == .unauthorized)
    }

    // Админ-API: без ADMIN_TOKEN на сервере → 503, без заголовка → 401, с токеном → 200
    try await app.testing().test(.GET, "/api/v1/admin/stats") { res async in
        #expect(res.status == .serviceUnavailable)
    }
    setenv("ADMIN_TOKEN", "test-admin-token", 1)
    try await app.testing().test(.GET, "/api/v1/admin/stats") { res async in
        #expect(res.status == .unauthorized)
    }
    try await app.testing().test(.GET, "/api/v1/admin/stats", headers: ["Authorization": "Bearer wrong"]) { res async in
        #expect(res.status == .unauthorized)
    }
    try await app.testing().test(.GET, "/api/v1/admin/stats", headers: ["Authorization": "Bearer test-admin-token"]) { res async in
        #expect(res.status == .ok)
    }
    // Рассылка: пустой текст → 400 (без бот-токена была бы 503)
    try await app.testing().test(.POST, "/api/v1/admin/broadcast", headers: ["Authorization": "Bearer test-admin-token", "Content-Type": "application/json"], body: ByteBuffer(string: "{\"text\":\"\",\"audience\":\"all\"}")) { res async in
        #expect(res.status == .badRequest)
    }
    unsetenv("ADMIN_TOKEN")

    // Корень: редирект в каталог (лендинга больше нет)
    try await app.testing().test(.GET, "/") { res async in
        #expect(res.status == .seeOther || res.status == .temporaryRedirect || res.status == .ok)
    }
}
