import Fluent
import Foundation
import Vapor

// MARK: - Фото блюда, избранное, отметки «сегодня»
func handleDishPhotoCallback(
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

    guard let dishID = UUID(uuidString: dishIDString),
          let dish = try await Dish.find(dishID, on: req.db),
          dish.$cook.id == user.id else {
        try await answerToast("Блюдо не найдено", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    try await ConversationService.startDishPhoto(for: telegramUserID, dishID: dishID, on: req.db)

    try await answerToast("Отправьте фото", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Отправьте фото блюда «\(dish.title)» (или '-' чтобы без фото):",
            replyMarkup: nil
        ),
        logger: logger
    )
}

func handleFavoriteToggleCallback(
    telegramUserID: Int64,
    callbackQueryID: String,
    dishIDString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          let userID = user.id else {
        return
    }
    guard user.typedRole == .client else {
        try await answerToast("Только для клиентов", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    guard let dishID = UUID(uuidString: dishIDString),
          try await Dish.find(dishID, on: req.db) != nil else {
        try await answerToast("Блюдо не найдено", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    if let existing = try await Favorite.query(on: req.db)
        .filter(\.$client.$id == userID)
        .filter(\.$dish.$id == dishID)
        .first() {
        try await existing.delete(on: req.db)
        try await answerToast("Убрано из избранного", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    let favorite = Favorite(clientID: userID, dishID: dishID)
    try await favorite.save(on: req.db)
    try await answerToast("Добавлено в избранное", callbackQueryID: callbackQueryID, client: client, logger: logger)
}

func handleDishTodayCallback(
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
    guard let dishID = UUID(uuidString: dishIDString),
          let dish = try await Dish.find(dishID, on: req.db),
          dish.$cook.id == user.id else {
        try await answerToast("Блюдо не найдено", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    try await ConversationService.startPortions(for: telegramUserID, dishID: dishID, on: req.db)

    try await answerToast("На сегодня", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Сколько порций «\(dish.title)» готовите сегодня? (числом, например: 5; или '-' без лимита)",
            replyMarkup: nil
        ),
        logger: logger
    )
}

func handleDishUntodayCallback(
    telegramUserID: Int64,
    callbackQueryID: String,
    dishIDString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }
    guard let dishID = UUID(uuidString: dishIDString),
          let dish = try await Dish.find(dishID, on: req.db),
          dish.$cook.id == user.id else {
        try await answerToast("Блюдо не найдено", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    dish.cookedDate = nil
    dish.portionsTotal = nil
    dish.portionsLeft = nil
    try await dish.save(on: req.db)

    try await answerToast("Убрано с сегодня", callbackQueryID: callbackQueryID, client: client, logger: logger)
}

// MARK: - Выбор типа блюда при заказе
func handleDishTypeCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    dishIDString: String,
    typeRaw: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }
    guard let dishID = UUID(uuidString: dishIDString),
          let dish = try await Dish.find(dishID, on: req.db),
          dish.$cook.id == user.id else {
        try await answerToast("Блюдо не найдено", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    if typeRaw != "skip" {
        dish.dishType = typeRaw
        try await dish.save(on: req.db)
    }

    if let state = try await ConversationService.getState(for: telegramUserID, on: req.db) {
        state.step = ConversationStep.waitingDishPhoto.rawValue
        try await state.save(on: req.db)
    }

    let typeLine = dishTypeTitle(dish.dishType).map { "\nКатегория: \($0)" } ?? ""
    try await answerToast("Категория сохранена", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Блюдо «\(dish.title)»\(typeLine). Теперь отправьте фото (или '-' чтобы без фото):",
            replyMarkup: nil
        ),
        logger: logger
    )
}

func handleCookCancelOrderPromptCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    orderIDString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let orderID = UUID(uuidString: orderIDString) else { return }
    guard let order = try await Order.find(orderID, on: req.db) else { return }

    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          user.typedRole == .cook,
          user.id == order.$cook.id,
          let currentStatus = order.typedStatus,
          isClientCancelable(status: currentStatus) else {
        try await answerToast("Заказ нельзя отменить", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    let title = order.dish?.title ?? "Блюдо"
    let markup = TelegramInlineKeyboardMarkup(inlineKeyboard: [
        [
            TelegramInlineKeyboardButton(text: "✅ Да, отменить", callbackData: "order:cook_cancel_confirm:\(orderIDString)"),
            TelegramInlineKeyboardButton(text: "❌ Нет", callbackData: "order:cancel_noop")
        ]
    ])
    try await answerToast("Подтвердите отмену", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: chatID, text: "Отменить заказ по «\(title)»?", replyMarkup: markup),
        logger: logger
    )
}

func handleCookCancelOrderConfirmCallback(
    telegramUserID: Int64,
    chatID: Int64,
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

    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }
    guard user.typedRole == .cook else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Только для повара", replyMarkup: nil),
            logger: logger
        )
        return
    }

    guard user.id == order.$cook.id,
          let currentStatus = order.typedStatus,
          isClientCancelable(status: currentStatus) else {
        try await answerToast("Заказ нельзя отменить", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    order.status = OrderStatus.cancelled.rawValue
    try await order.save(on: req.db)

    try await answerToast("Заказ отменен", callbackQueryID: callbackQueryID, client: client, logger: logger)

    let title = order.dish?.title ?? "Блюдо"
    guard let clientTelegramID = try await findTelegramIDForUser(order.$client.id, on: req.db) else {
        return
    }
    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: clientTelegramID, text: "Повар отменил заказ по \(title)", replyMarkup: nil),
        logger: logger
    )
}
