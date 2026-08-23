import Fluent
import Foundation
import Vapor

// MARK: - Чат с заказчиком, подписки на повара
func handleOrderChatCallback(
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
    let title = order.dish?.title ?? "Блюдо"
    try await answerToast("Чат", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await ConversationService.startChatMessage(for: telegramUserID, orderID: orderID, on: req.db)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "✍️ Напишите сообщение повару по заказу «\(title)» (или '-' чтобы отменить).",
            replyMarkup: nil
        ),
        logger: logger
    )
}

func handleCookSubscribeCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    cookIDString: String,
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
    guard let cookID = UUID(uuidString: cookIDString),
          let cook = try await User.find(cookID, on: req.db) else {
        try await answerToast("Повар не найден", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    if let existing = try await Subscription.query(on: req.db)
        .filter(\.$client.$id == userID)
        .filter(\.$cook.$id == cookID)
        .first() {
        try await existing.delete(on: req.db)
        try await answerToast("Вы отписались от \(cook.firstName)", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    let subscription = Subscription(clientID: userID, cookID: cookID)
    try await subscription.save(on: req.db)
    try await answerToast("Вы следите за \(cook.firstName)", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Теперь вы узнаете, когда \(cook.firstName) готовит сегодня. Управление — в «Мои повара».",
            replyMarkup: nil
        ),
        logger: logger
    )
}

func handleCookUnsubscribeCallback(
    telegramUserID: Int64,
    callbackQueryID: String,
    cookIDString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          let userID = user.id else {
        return
    }
    guard let cookID = UUID(uuidString: cookIDString),
          let cook = try await User.find(cookID, on: req.db) else {
        try await answerToast("Повар не найден", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    if let existing = try await Subscription.query(on: req.db)
        .filter(\.$client.$id == userID)
        .filter(\.$cook.$id == cookID)
        .first() {
        try await existing.delete(on: req.db)
    }
    try await answerToast("Вы отписались от \(cook.firstName)", callbackQueryID: callbackQueryID, client: client, logger: logger)
}

// MARK: - Меню повара, фото отзывов, сюрприз, карта, отзывы
func handleCookMenuCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    cookIDString: String,
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
    guard let cookID = UUID(uuidString: cookIDString),
          let clientLatitude = user.latitude,
          let clientLongitude = user.longitude else {
        try await answerToast("Сначала поделитесь геолокацией", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    let menus = try await collectNearbyMenus(
        clientLatitude: clientLatitude,
        clientLongitude: clientLongitude,
        req: req
    )
    guard let menu = menus.first(where: { $0.cook.id == cookID }) else {
        try await answerToast("Повар сейчас не готовит", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    try await answerToast("Меню", callbackQueryID: callbackQueryID, client: client, logger: logger)

    let subscriptions = try await Subscription.query(on: req.db)
        .filter(\.$client.$id == userID)
        .all()
    let subscribedCookIDs = Set(subscriptions.compactMap { $0.$cook.id })
    try await sendMenuMessage(
        menu: menu,
        subscribedCookIDs: subscribedCookIDs,
        req: req,
        chatID: chatID,
        client: client,
        logger: logger
    )
}

func handleReviewPhotosCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    cookIDString: String,
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
    guard let cookID = UUID(uuidString: cookIDString) else {
        return
    }

    let reviewOrders = try await Order.query(on: req.db)
        .filter(\.$cook.$id == cookID)
        .filter(\.$reviewPhoto != nil)
        .sort(\.$createdAt, .descending)
        .limit(3)
        .all()

    guard !reviewOrders.isEmpty else {
        try await answerToast("Фото пока нет", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    try await answerToast("Фото от клиентов", callbackQueryID: callbackQueryID, client: client, logger: logger)
    for order in reviewOrders {
        guard let photoFileID = order.reviewPhoto else { continue }
        let ratingLine = order.rating.map { "Оценка: \($0)/5" } ?? ""
        try await client.sendPhoto(
            TelegramSendPhotoRequest(chatID: chatID, photo: photoFileID, caption: ratingLine, replyMarkup: nil),
            logger: logger
        )
    }
}

func handleSurpriseAgainCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let state = try await ConversationService.getState(for: telegramUserID, on: req.db),
          state.typedStep == .waitingSurpriseBudget,
          let budgetString = state.draftTitle,
          let budget = Double(budgetString) else {
        try await answerToast("Укажите бюджет", callbackQueryID: callbackQueryID, client: client, logger: logger)
        try await ConversationService.startSurpriseBudget(for: telegramUserID, budget: nil, on: req.db)
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "Введите ваш бюджет в рублях, например: 500",
                replyMarkup: nil
            ),
            logger: logger
        )
        return
    }

    try await answerToast("Ещё раз", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await sendSurprise(
        telegramUserID: telegramUserID,
        chatID: chatID,
        budget: budget,
        req: req,
        client: client,
        logger: logger
    )
}

func handleCookMapCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    cookIDString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let cook = try await User.find(UUID(uuidString: cookIDString), on: req.db),
          let lat = cook.latitude, let lng = cook.longitude else {
        try await answerToast("Геопозиция повара неизвестна", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    try await answerToast("Карта", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await client.sendLocation(
        TelegramSendLocationRequest(
            chatID: chatID,
            latitude: lat,
            longitude: lng,
            title: "Кухня \(cook.firstName)",
            address: cook.address
        ),
        logger: logger
    )
}

func handleCookReviewsCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    cookIDString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let cookID = UUID(uuidString: cookIDString) else {
        try await answerToast("Повар не найден", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    let reviewOrders = try await Order.query(on: req.db)
        .filter(\.$cook.$id == cookID)
        .filter(\.$rating != nil)
        .with(\.$client)
        .with(\.$dish)
        .sort(\.$createdAt, .descending)
        .all()

    guard !reviewOrders.isEmpty else {
        try await answerToast("Отзывов пока нет", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    try await answerToast("Отзывы", callbackQueryID: callbackQueryID, client: client, logger: logger)
    for order in reviewOrders {
        let title = order.dish?.title ?? "Блюдо"
        let clientName = order.client.firstName
        let ratingLine = order.rating.map { "⭐ \($0)/5" } ?? ""
        let textLine = order.reviewText.map { "\n\($0)" } ?? ""
        let photoButton = order.reviewPhoto.map { _ in
            TelegramInlineKeyboardMarkup(inlineKeyboard: [[
                TelegramInlineKeyboardButton(text: "📷 Фото", callbackData: "cook:review_photos:\(order.cook.id?.uuidString ?? "")")
            ]])
        }
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "\(clientName) оценил «\(title)» \(ratingLine)\(textLine)",
                replyMarkup: photoButton
            ),
            logger: logger
        )
    }
}
