import Fluent
import Foundation
import Vapor

func sendCookAnalytics(
    cookID: UUID,
    chatID: Int64,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    let orders = try await Order.query(on: req.db)
        .filter(\.$cook.$id == cookID)
        .with(\.$client)
        .with(\.$dish)
        .all()

    var counts: [OrderStatus: Int] = [:]
    for order in orders {
        if let status = order.typedStatus {
            counts[status, default: 0] += 1
        }
    }

    let delivered = orders.filter { $0.typedStatus == .delivered }
    let revenueTotal = delivered.reduce(0) { $0 + $1.totalPrice }

    let now = Date()
    let weekAgo = now.addingTimeInterval(-7 * 86400)
    let monthAgo = now.addingTimeInterval(-30 * 86400)
    let revenueWeek = delivered
        .filter { ($0.createdAt ?? .distantPast) >= weekAgo }
        .reduce(0) { $0 + $1.totalPrice }
    let revenueMonth = delivered
        .filter { ($0.createdAt ?? .distantPast) >= monthAgo }
        .reduce(0) { $0 + $1.totalPrice }

    var dishStats: [String: (count: Int, revenue: Double)] = [:]
    for order in delivered {
        let title = order.dish?.title ?? "Без названия"
        var entry = dishStats[title] ?? (0, 0)
        entry.count += order.quantity
        entry.revenue += order.totalPrice
        dishStats[title] = entry
    }
    let topDishes = dishStats.sorted { $0.value.count > $1.value.count }.prefix(5)

    var clientCounts: [UUID: Int] = [:]
    for order in delivered {
        clientCounts[order.$client.id, default: 0] += 1
    }
    let repeatClients = clientCounts.filter { $0.value >= 2 }

    let ratings = orders.compactMap { $0.rating }
    let avgRating = ratings.isEmpty ? nil : Double(ratings.reduce(0, +)) / Double(ratings.count)

    var text = """
    📊 Аналитика
    Всего заказов: \(orders.count)
    Новый: \(counts[.new] ?? 0)
    Принят: \(counts[.accepted] ?? 0)
    Готовится: \(counts[.cooking] ?? 0)
    Готов: \(counts[.ready] ?? 0)
    Доставлен: \(counts[.delivered] ?? 0)
    Отменён: \(counts[.cancelled] ?? 0)

    💰 Выручка (доставлено):
    Всего: \(formatPrice(revenueTotal))₽
    За 7 дней: \(formatPrice(revenueWeek))₽
    За 30 дней: \(formatPrice(revenueMonth))₽
    """

    if let avg = avgRating {
        text += "\n⭐ Средняя оценка: \(String(format: "%.1f", avg))"
    }

    if !topDishes.isEmpty {
        text += "\n\n🥇 Топ блюд:"
        for (name, stat) in topDishes {
            text += "\n• \(name) — \(stat.count) шт, \(formatPrice(stat.revenue))₽"
        }
    }

    text += "\n\n👥 Повторные клиенты: \(repeatClients.count)"
    if !repeatClients.isEmpty {
        text += " (из \(clientCounts.count) клиентов)"
    }

    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: chatID, text: text, replyMarkup: nil),
        logger: logger
    )
}
