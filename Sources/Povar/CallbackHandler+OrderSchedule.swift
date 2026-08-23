import Fluent
import Foundation
import Vapor

// MARK: - Оценка заказа, окно забора, время, самовывоз
func handleRateOrderCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    data: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    let parts = data.split(separator: ":").map(String.init)
    guard parts.count == 4,
          let orderID = UUID(uuidString: parts[2]),
          let rating = Int(parts[3]),
          (1...5).contains(rating) else {
        return
    }

    guard let order = try await Order.find(orderID, on: req.db) else {
        return
    }

    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }
    guard user.typedRole == .client else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Только для клиентов", replyMarkup: nil),
            logger: logger
        )
        return
    }

    guard user.id == order.$client.id,
          order.typedStatus == .delivered,
          order.rating == nil else {
        return
    }

    order.rating = rating
    try await order.save(on: req.db)

    try await answerToast("Спасибо за оценку!", callbackQueryID: callbackQueryID, client: client, logger: logger)

    guard let orderID = order.id else { return }
    try await ConversationService.startReviewText(for: telegramUserID, orderID: orderID, on: req.db)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Напишите отзыв о блюде текстом (или '-' чтобы пропустить):",
            replyMarkup: nil
        ),
        logger: logger
    )
}

func handleOrderWindowCallback(
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

    try await answerToast("Укажите окно выдачи", callbackQueryID: callbackQueryID, client: client, logger: logger)

    let cook = try await User.find(order.$cook.id, on: req.db)
    let current = order.pickupWindow ?? cook?.pickupSchedule
    let currentLine = current.map { "\nТекущее окно: \($0)" } ?? ""
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Введите окно выдачи для заказа (например: 12:00-14:00)\(currentLine)\nОтправьте '-' чтобы убрать:",
            replyMarkup: nil
        ),
        logger: logger
    )
    try await ConversationService.startOrderWindow(for: telegramUserID, orderID: orderID, on: req.db)
}

func handleOrderTimeCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    data: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    let parts = data.split(separator: ":").map(String.init)
    guard parts.count == 4,
          let orderID = UUID(uuidString: parts[2]),
          let order = try await Order.find(orderID, on: req.db) else {
        return
    }

    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }
    guard user.typedRole == .client else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Только для клиентов", replyMarkup: nil),
            logger: logger
        )
        return
    }
    guard order.typedStatus == .ready else {
        try await answerToast("Заказ ещё не готов", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    if parts[3] == "custom" {
        try await ConversationService.startPickupTime(for: telegramUserID, orderID: orderID, on: req.db)
        try await answerToast("Укажите время", callbackQueryID: callbackQueryID, client: client, logger: logger)
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "К какому времени заберёте заказ? (например: 14:30 или отправьте '-' чтобы пропустить)",
                replyMarkup: nil
            ),
            logger: logger
        )
        return
    }

    guard let minutes = Int(parts[3]), [15, 30, 60].contains(minutes) else {
        return
    }
    let pickupTime = formatTime(Date().addingTimeInterval(TimeInterval(minutes * 60)))
    order.pickupTime = pickupTime
    try await order.save(on: req.db)

    try await answerToast("Время сохранено", callbackQueryID: callbackQueryID, client: client, logger: logger)

    guard let cookTelegramID = try await findTelegramIDForUser(order.$cook.id, on: req.db) else {
        return
    }
    let shortID = String(order.id?.uuidString.prefix(8) ?? "")
    let deliveryAction = order.isDelivery == true ? "Доставить заказ" : "Клиент заберёт заказ"
    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: cookTelegramID, text: "\(deliveryAction) #\(shortID) к \(pickupTime)", replyMarkup: nil),
        logger: logger
    )
}

func handleOrderPickupCallback(
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
    guard user.typedRole == .client else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Только для клиентов", replyMarkup: nil),
            logger: logger
        )
        return
    }
    guard order.typedStatus == .ready else {
        try await answerToast("Заказ ещё не готов", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    order.status = OrderStatus.delivered.rawValue
    try await order.save(on: req.db)

    if order.bonusAwarded != true {
        let bonus = bonusFor(orderTotal: order.totalPrice, hasReview: order.reviewText != nil || order.reviewPhoto != nil)
        try await BotUserService.applyBonus(
            to: order.$client.id,
            amount: bonus,
            reason: "Заказ «\(order.dish?.title ?? "")»",
            on: req.db
        )
        order.bonusAwarded = true
        try await order.save(on: req.db)
    }

    try await answerToast("Отлично! Приятного аппетита", callbackQueryID: callbackQueryID, client: client, logger: logger)

    let title = order.dish?.title ?? "Блюдо"
    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: chatID, text: "Вы забрали заказ по \(title). Спасибо!", replyMarkup: nil),
        logger: logger
    )

    guard let cookTelegramID = try await findTelegramIDForUser(order.$cook.id, on: req.db) else {
        return
    }
    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: cookTelegramID, text: "Клиент забрал заказ по \(title)", replyMarkup: nil),
        logger: logger
    )

    let ratingButtons = (1...5).map { value in
        TelegramInlineKeyboardButton(
            text: "\(value)",
            callbackData: "order:rate:\(order.id?.uuidString ?? ""):\(value)"
        )
    }
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Оцените блюдо «\(title)» от 1 до 5:",
            replyMarkup: TelegramInlineKeyboardMarkup(inlineKeyboard: [ratingButtons])
        ),
        logger: logger
    )
}

// MARK: - Изменение адреса заказа
func handleOrderRescheduleCallback(
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
    let days = nextDays(count: 7)
    let buttons = days.map { day in
        TelegramInlineKeyboardButton(
            text: dayLabel(day),
            callbackData: "order:reschedule_date:\(orderID.uuidString):\(formatDate(day))"
        )
    }
    var rows: [[TelegramInlineKeyboardButton]] = stride(from: 0, to: buttons.count, by: 2).map { sliceStart in
        Array(buttons[sliceStart..<min(sliceStart + 2, buttons.count)])
    }
    rows.append([
        TelegramInlineKeyboardButton(text: "Отмена", callbackData: "order:create_cancel")
    ])
    try await answerToast("Выберите новую дату", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Перенести заказ «\(title)» на какой день?",
            replyMarkup: TelegramInlineKeyboardMarkup(inlineKeyboard: rows)
        ),
        logger: logger
    )
}

func handleOrderRescheduleDateCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    orderIDString: String,
    dateString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let orderID = UUID(uuidString: orderIDString),
          let order = try await Order.find(orderID, on: req.db) else {
        return
    }
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          user.typedRole == .client,
          order.$client.id == user.id else {
        try await answerToast("Только для клиента по этому заказу", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    guard order.typedStatus != .cancelled, order.typedStatus != .delivered else {
        try await answerToast("Нельзя перенести", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    order.rescheduleTo = dateString
    order.scheduledDate = dateString
    try await order.save(on: req.db)
    try await answerToast("Перенесено на \(dateString)", callbackQueryID: callbackQueryID, client: client, logger: logger)

    let title = order.dish?.title ?? "Блюдо"
    if let cookTelegramID = try await findTelegramIDForUser(order.$cook.id, on: req.db) {
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: cookTelegramID,
                text: "📅 Заказ «\(title)» перенесён клиентом на \(dateString).",
                replyMarkup: nil
            ),
            logger: logger
        )
    }
}

func handleOrderChangeAddressCallback(
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
    try await answerToast("Адрес", callbackQueryID: callbackQueryID, client: client, logger: logger)

    let saved = try await Address.query(on: req.db)
        .filter(\.$user.$id == order.$client.id)
        .all()
    if !saved.isEmpty {
        var rows: [[TelegramInlineKeyboardButton]] = saved.map { address in
            [TelegramInlineKeyboardButton(
                text: "✅ \(address.name) — \(address.text)",
                callbackData: "order:pick_address:\(orderID.uuidString):\(address.id?.uuidString ?? "")"
            )]
        }
        rows.append([
            TelegramInlineKeyboardButton(
                text: "+ Добавить адрес",
                callbackData: "order:add_address:\(orderID.uuidString)"
            )
        ])
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "Выберите адрес для заказа «\(title)»:",
                replyMarkup: TelegramInlineKeyboardMarkup(inlineKeyboard: rows)
            ),
            logger: logger
        )
    } else {
        try await ConversationService.startOrderAddress(for: telegramUserID, orderID: orderID, on: req.db)
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "Введите адрес доставки для заказа «\(title)»:",
                replyMarkup: nil
            ),
            logger: logger
        )
    }
}

func handleOrderPickAddressCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    orderIDString: String,
    addressIDString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let orderID = UUID(uuidString: orderIDString),
          let order = try await Order.find(orderID, on: req.db) else {
        return
    }
    guard let address = try await Address.find(UUID(uuidString: addressIDString), on: req.db) else {
        try await answerToast("Адрес не найден", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    order.shippingAddress = address.text
    order.isDelivery = true
    try await order.save(on: req.db)
    try await answerToast("✅ Доставка к \(address.name)", callbackQueryID: callbackQueryID, client: client, logger: logger)

    let title = order.dish?.title ?? "Блюдо"
    if let cookTelegramID = try await findTelegramIDForUser(order.$cook.id, on: req.db) {
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: cookTelegramID,
                text: "🚚 Заказ «\(title)»: доставка по адресу \(address.text).",
                replyMarkup: nil
            ),
            logger: logger
        )
    }
}

func handleOrderAddAddressCallback(
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
    try await ConversationService.startOrderAddress(for: telegramUserID, orderID: orderID, on: req.db)
    try await answerToast("Введите адрес", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Введите адрес доставки для заказа «\(order.dish?.title ?? "Блюдо")»:",
            replyMarkup: nil
        ),
        logger: logger
    )
}
