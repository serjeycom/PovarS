import Fluent
import Foundation
import Vapor

func handleStatusCommand(
    telegramUserID: Int64,
    chatID: Int64,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    let usersCount = try await User.query(on: req.db).count()
    let clientsCount = try await User.query(on: req.db)
        .filter(\.$role == UserRole.client.rawValue)
        .count()
    let cooksCount = try await User.query(on: req.db)
        .filter(\.$role == UserRole.cook.rawValue)
        .count()
    let dishesCount = try await Dish.query(on: req.db).count()
    let activeDishesCount = try await Dish.query(on: req.db)
        .filter(\.$isActive == true)
        .count()

    let ordersCount = try await Order.query(on: req.db).count()
    let todayOrdersCount = try await Order.query(on: req.db)
        .filter(\.$createdAt >= Calendar.current.startOfDay(for: Date()))
        .count()
    let pendingOrdersCount = try await Order.query(on: req.db)
        .filter(\.$status != OrderStatus.delivered.rawValue)
        .filter(\.$status != OrderStatus.cancelled.rawValue)
        .count()

    let promoCount = try await PromoCode.query(on: req.db).count()

    var text = """
    📊 Статус бота
    Пользователи: \(usersCount) (клиенты \(clientsCount), повара \(cooksCount))
    Блюда: \(dishesCount) (активных \(activeDishesCount))
    Заказы: \(ordersCount) всего, \(todayOrdersCount) сегодня
    В работе: \(pendingOrdersCount)
    Промокоды: \(promoCount)
    """
    text += "\n🕐 Время: \(Date())"
    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: chatID, text: text, replyMarkup: nil),
        logger: logger
    )
}
