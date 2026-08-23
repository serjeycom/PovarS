import Fluent
import Foundation
import Vapor

// MARK: - Ответ на заказ, лист ожидания
func handleOrderReplyCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    orderIDString: String,
    fromTelegramID: Int64,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let orderID = UUID(uuidString: orderIDString),
          let order = try await Order.find(orderID, on: req.db) else {
        return
    }
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          let userID = user.id,
          order.$cook.id == userID || order.$client.id == userID else {
        try await answerToast("Только для участников этого заказа", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    try await answerToast("Пишите ответ…", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await ConversationService.startChatMessage(for: telegramUserID, orderID: orderID, on: req.db)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Введите ответ (собеседник получит ваше сообщение):",
            replyMarkup: nil
        ),
        logger: logger
    )
}

func handleOrderReplyDoneCallback(
    telegramUserID: Int64,
    callbackQueryID: String,
    orderIDString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let orderID = UUID(uuidString: orderIDString),
          let order = try await Order.find(orderID, on: req.db) else {
        return
    }
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          user.typedRole == .cook,
          order.$cook.id == user.id else {
        try await answerToast("Только для повара", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    let title = order.dish?.title ?? "Блюдо"
    let shortID = order.id?.uuidString.prefix(8) ?? ""
    try await answerToast("Готово", callbackQueryID: callbackQueryID, client: client, logger: logger)
    guard let clientTelegramID = try await findTelegramIDForUser(order.$client.id, on: req.db) else {
        return
    }
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: clientTelegramID,
            text: "🛑 Повар закрыл чат по заказу #\(shortID) «\(title)». Если что — пишите в поддержку.",
            replyMarkup: nil
        ),
        logger: logger
    )
}

func handleOrderWaitlistCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    dishIDString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }
    guard user.typedRole == .client else {
        try await answerToast("Только для клиентов", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    guard let dishID = UUID(uuidString: dishIDString),
          let dish = try await Dish.find(dishID, on: req.db) else {
        try await answerToast("Блюдо не найдено", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    guard let userID = user.id else { return }

    if let existing = try await WaitlistEntry.query(on: req.db)
        .filter(\.$dish.$id == dishID)
        .filter(\.$client.$id == userID)
        .first() {
        try await existing.delete(on: req.db)
        try await answerToast("Вы удалены из списка ожидания", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    let entry = WaitlistEntry(dishID: dishID, clientID: userID, quantity: 1)
    try await entry.save(on: req.db)
    try await answerToast("Вы в списке ожидания 👍", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Когда повар пополнит порции «\(dish.title)» — мы вас уведомим. Отпишитесь через кнопку снова.",
            replyMarkup: nil
        ),
        logger: logger
    )

    if let cookTelegramID = try await findTelegramIDForUser(dish.$cook.id, on: req.db) {
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: cookTelegramID,
                text: "👥 Кто‑то ждёт ваше блюдо «\(dish.title)» в списке ожидания.",
                replyMarkup: nil
            ),
            logger: logger
        )
    }
}

func notifyWaitlistOnRestock(
    dish: Dish,
    addedPortions: Int,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    let entries = try await WaitlistEntry.query(on: req.db)
        .filter(\.$dish.$id == (dish.id ?? UUID()))
        .filter(\.$notified == false)
        .sort(\.$createdAt)
        .all()
    guard !entries.isEmpty else { return }

    for entry in entries {
        guard let clientTelegramID = try await findTelegramIDForUser(entry.$client.id, on: req.db) else {
            continue
        }
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: clientTelegramID,
                text: "🔥 «\(dish.title)» пополнилось! Быстро заберите — ваше место в очереди.",
                replyMarkup: nil
            ),
            logger: logger
        )
        entry.notified = true
        try await entry.save(on: req.db)
    }
}
