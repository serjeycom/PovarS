import Fluent
import Foundation
import Vapor

// MARK: - Оформление заказа (промпты, кол-во, подтверждение)
func handleCreateOrderPromptCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    dishIDString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        try await sendRoleSelection(
            telegramUserID: telegramUserID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )
        return
    }

    guard user.typedRole == .client else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Только для клиентов", replyMarkup: nil),
            logger: logger
        )
        return
    }

    guard let dishID = UUID(uuidString: dishIDString),
          let dish = try await Dish.find(dishID, on: req.db),
          dish.isActive else {
        try await answerToast("Блюдо не найдено", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    try await answerToast("Сколько порций?", callbackQueryID: callbackQueryID, client: client, logger: logger)

    try await sendOrderQuantityPrompt(
        telegramUserID: telegramUserID,
        chatID: chatID,
        dishID: dishID,
        req: req,
        client: client,
        logger: logger
    )
}

func sendOrderQuantityPrompt(
    telegramUserID: Int64,
    chatID: Int64,
    dishID: UUID,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let dish = try await Dish.find(dishID, on: req.db) else { return }

    let buttons = (1...5).map { value in
        TelegramInlineKeyboardButton(
            text: "\(value)",
            callbackData: "order:qty_done:\(dishID.uuidString):\(value)"
        )
    }
    let customButton = TelegramInlineKeyboardButton(
        text: "✏️ Другое",
        callbackData: "order:qty_custom:\(dishID.uuidString)"
    )
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Сколько порций «\(dish.title)»?\n(Выберите число или введите вручную)",
            replyMarkup: TelegramInlineKeyboardMarkup(inlineKeyboard: [buttons, [customButton]])
        ),
        logger: logger
    )
}

func sendOrderConfirmDialog(
    telegramUserID: Int64,
    chatID: Int64,
    dishID: UUID,
    quantity: Int,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let dish = try await Dish.find(dishID, on: req.db) else { return }
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          user.typedRole == .client else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Только для клиентов", replyMarkup: nil),
            logger: logger
        )
        return
    }

    let totalPrice = dish.price * Double(quantity)
    let balance = user.balance ?? 0
    var text = """
    Подтвердить заказ?
    Блюдо «\(dish.title)» — \(formatQuantity(quantity))
    Сумма: \(formatPrice(totalPrice)) руб.
    Способ: самовывоз (по умолчанию) или доставка
    """
    if balance > 0 {
        text += "\n💰 Ваш баланс: \(balance) баллов"
    }
    let qty = quantity
    let markup = TelegramInlineKeyboardMarkup(inlineKeyboard: [
        [
            TelegramInlineKeyboardButton(
                text: "Подтвердить (\(qty))",
                callbackData: "order:confirm:\(dish.id?.uuidString ?? ""):\(qty)"
            )
        ],
        [
            TelegramInlineKeyboardButton(
                text: "Доставить по адресу (\(qty))",
                callbackData: "order:deliver:\(dish.id?.uuidString ?? ""):\(qty)"
            )
        ],
        [
            TelegramInlineKeyboardButton(
                text: "🎟 Промокод",
                callbackData: "order:promo:\(dish.id?.uuidString ?? ""):\(qty)"
            ),
            TelegramInlineKeyboardButton(
                text: "💰 Оплатить баллами (\(min(balance, Int(totalPrice)))",
                callbackData: "order:pay_balance:\(dish.id?.uuidString ?? ""):\(qty)"
            )
        ],
        [
            TelegramInlineKeyboardButton(
                text: "Добавить комментарий",
                callbackData: "order:comment:\(dish.id?.uuidString ?? ""):\(qty)"
            )
        ],
        [
            TelegramInlineKeyboardButton(
                text: "В избранное",
                callbackData: "dish:fav:\(dish.id?.uuidString ?? "")"
            )
        ],
        [
            TelegramInlineKeyboardButton(
                text: "📅 Заказать на другой день",
                callbackData: "order:preorder:\(dish.id?.uuidString ?? ""):\(qty)"
            )
        ],
        [
            TelegramInlineKeyboardButton(
                text: "🛒 В корзину",
                callbackData: "cart:add:\(dish.id?.uuidString ?? ""):\(qty)"
            )
        ],
        [
            TelegramInlineKeyboardButton(text: "Отмена", callbackData: "order:create_cancel")
        ]
    ])
    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: chatID, text: text, replyMarkup: markup),
        logger: logger
    )
}

// MARK: - Создание заказа (обычный / предзаказ)
func handleCreateOrderCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    dishIDString: String,
    quantityString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let clientUser = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        try await sendRoleSelection(
            telegramUserID: telegramUserID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )
        return
    }

    guard clientUser.typedRole == .client else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Только для клиентов", replyMarkup: nil),
            logger: logger
        )
        return
    }

    guard let dishID = UUID(uuidString: dishIDString),
          let dish = try await Dish.find(dishID, on: req.db),
          dish.isActive else {
        try await answerToast("Блюдо не найдено", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    guard let quantity = Int(quantityString), (1...20).contains(quantity) else {
        try await answerToast("Введите число от 1 до 20", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    try await createOrderAndNotify(
        dish: dish,
        comment: nil,
        clientUser: clientUser,
        chatID: chatID,
        req: req,
        client: client,
        logger: logger,
        quantity: quantity
    )

    try await answerToast("Заказ создан", callbackQueryID: callbackQueryID, client: client, logger: logger)
}

// MARK: - Предзаказ
func handleOrderPreorderCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    dishIDString: String,
    quantity: Int,
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
          let dish = try await Dish.find(dishID, on: req.db),
          dish.isActive else {
        try await answerToast("Блюдо не найдено", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    try await answerToast("Выберите день", callbackQueryID: callbackQueryID, client: client, logger: logger)

    let days = nextDays(count: 7)
    let buttons = days.map { day in
        TelegramInlineKeyboardButton(
            text: dayLabel(day),
            callbackData: "order:preorder_confirm:\(dishID.uuidString):\(quantity):\(formatDate(day))"
        )
    }
    var rows: [[TelegramInlineKeyboardButton]] = stride(from: 0, to: buttons.count, by: 2).map { sliceStart in
        Array(buttons[sliceStart..<min(sliceStart + 2, buttons.count)])
    }
    rows.append([
        TelegramInlineKeyboardButton(text: "Отмена", callbackData: "order:create_cancel")
    ])

    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "На какой день заказать «\(dish.title)» (\(formatQuantity(quantity)))?",
            replyMarkup: TelegramInlineKeyboardMarkup(inlineKeyboard: rows)
        ),
        logger: logger
    )
}

func handleOrderPreorderConfirmCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    dishIDString: String,
    quantity: Int,
    dateString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let clientUser = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }
    guard clientUser.typedRole == .client else {
        try await answerToast("Только для клиентов", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    guard let dishID = UUID(uuidString: dishIDString),
          let dish = try await Dish.find(dishID, on: req.db),
          dish.isActive else {
        try await answerToast("Блюдо не найдено", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    try await createOrderAndNotify(
        dish: dish,
        comment: nil,
        clientUser: clientUser,
        chatID: chatID,
        req: req,
        client: client,
        logger: logger,
        isDelivery: false,
        scheduledDate: dateString,
        quantity: quantity
    )

    try await answerToast("Заказ оформлен", callbackQueryID: callbackQueryID, client: client, logger: logger)
}

// MARK: - Статусы заказа (принят / готовится / готов / в пути)
func handleOrderStatusCallback(
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
    guard user.typedRole == .cook else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Только для повара", replyMarkup: nil),
            logger: logger
        )
        return
    }

    guard let newStatus = allOrderStatuses.first(where: { statusTitle($0) == parts[3] }) else {
        try await answerToast("Переход статуса недоступен", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    guard let currentStatus = order.typedStatus,
          isAllowedTransition(from: currentStatus, to: newStatus) else {
        try await answerToast("Переход статуса недоступен", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    order.status = newStatus.rawValue
    try await order.save(on: req.db)

    try await answerToast("Статус обновлен", callbackQueryID: callbackQueryID, client: client, logger: logger)

    guard let clientTelegramID = try await findTelegramIDForUser(order.$client.id, on: req.db) else {
        return
    }
    let title = order.dish?.title ?? "Блюдо"
    let text = "Ваш заказ по \(title): статус -> \(statusTitle(newStatus))"
    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: clientTelegramID, text: text, replyMarkup: nil),
        logger: logger
    )

    if newStatus == .ready {
        var windowLine = ""
        if let window = order.pickupWindow {
            windowLine = "\nВремя выдачи: \(window)"
        } else if let cook = try await User.find(order.$cook.id, on: req.db),
                  let schedule = cook.pickupSchedule {
            windowLine = "\nВремя выдачи: \(schedule)"
        }
        let orderID = order.id?.uuidString ?? ""
        let pickupLabel = order.isDelivery == true ? "✅ Получил заказ" : "Я у повара"
        let readyQuestion = order.isDelivery == true ? "Когда привезти заказ?" : "Когда подойдёте?"
        let pickupAction = order.isDelivery == true ? "order:receive:\(orderID)" : "order:pickup:\(orderID)"
        let timeButtons = [
            TelegramInlineKeyboardButton(text: "Через 15 мин", callbackData: "order:time:\(orderID):15"),
            TelegramInlineKeyboardButton(text: "Через 30 мин", callbackData: "order:time:\(orderID):30"),
            TelegramInlineKeyboardButton(text: "Через час", callbackData: "order:time:\(orderID):60"),
            TelegramInlineKeyboardButton(text: "Укажу сам", callbackData: "order:time:\(orderID):custom"),
            TelegramInlineKeyboardButton(text: pickupLabel, callbackData: pickupAction)
        ]
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: clientTelegramID,
                text: "Ваш заказ по \(title): статус -> Готов. Можно забирать!\(windowLine) \(readyQuestion)",
                replyMarkup: TelegramInlineKeyboardMarkup(inlineKeyboard: [timeButtons])
            ),
            logger: logger
        )
    }

    if newStatus == .onTheWay {
        let orderID = order.id?.uuidString ?? ""
        let trackButton = TelegramInlineKeyboardButton(
            text: "📍 Геолокация курьера",
            callbackData: "order:track:\(orderID)"
        )
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: clientTelegramID,
                text: "🚚 Ваш заказ по \(title) в пути! Можно отследить курьера.",
                replyMarkup: TelegramInlineKeyboardMarkup(inlineKeyboard: [[trackButton]])
            ),
            logger: logger
        )
    }

    if newStatus == .delivered {
        let ratingButtons = (1...5).map { value in
            TelegramInlineKeyboardButton(
                text: "\(value)",
                callbackData: "order:rate:\(order.id?.uuidString ?? ""):\(value)"
            )
        }
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: clientTelegramID,
                text: "Оцените блюдо «\(title)» от 1 до 5:",
                replyMarkup: TelegramInlineKeyboardMarkup(inlineKeyboard: [ratingButtons])
            ),
            logger: logger
        )

        if order.bonusAwarded != true {
            let bonus = bonusFor(orderTotal: order.totalPrice, hasReview: order.reviewText != nil || order.reviewPhoto != nil)
            try await BotUserService.applyBonus(
                to: order.$client.id,
                amount: bonus,
                reason: "Заказ «\(title)»",
                on: req.db
            )
            order.bonusAwarded = true
            try await order.save(on: req.db)
        }
    }
}

// MARK: - Отмена заказа клиентом/поваром
func handleClientCancelOrderPromptCallback(
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
          user.typedRole == .client,
          user.id == order.$client.id,
          isClientCancelable(order: order) else {
        try await answerToast("Заказ нельзя отменить", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    let title = order.dish?.title ?? "Блюдо"
    let markup = TelegramInlineKeyboardMarkup(inlineKeyboard: [
        [
            TelegramInlineKeyboardButton(text: "✅ Да, отменить", callbackData: "order:client_cancel_confirm:\(orderIDString)"),
            TelegramInlineKeyboardButton(text: "❌ Нет", callbackData: "order:cancel_noop")
        ]
    ])
    try await answerToast("Подтвердите отмену", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: chatID, text: "Отменить заказ по «\(title)»?", replyMarkup: markup),
        logger: logger
    )
}

func handleClientCancelOrderConfirmCallback(
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

    guard user.id == order.$client.id,
          isClientCancelable(order: order) else {
        try await answerToast("Заказ нельзя отменить", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    order.status = OrderStatus.cancelled.rawValue
    try await order.save(on: req.db)

    if order.balanceUsed > 0 {
        try await BotUserService.applyBonus(
            to: user.id!,
            amount: order.balanceUsed,
            reason: "Возврат баллов за отменённый заказ",
            on: req.db
        )
    }

    try await answerToast("Заказ отменен", callbackQueryID: callbackQueryID, client: client, logger: logger)

    let title = order.dish?.title ?? "Блюдо"
    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: chatID, text: "Вы отменили заказ по \(title)", replyMarkup: nil),
        logger: logger
    )

    guard let cookTelegramID = try await findTelegramIDForUser(order.$cook.id, on: req.db) else {
        return
    }
    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: cookTelegramID, text: "Клиент отменил заказ по \(title)", replyMarkup: nil),
        logger: logger
    )
}

// MARK: - Голосовой комментарий, трекинг, жалоба, гео к заказу
func handleOrderVoiceCommentCallback(
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
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          user.typedRole == .client,
          order.$client.id == user.id else {
        try await answerToast("Только для клиента по этому заказу", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    try await ConversationService.startVoiceComment(for: telegramUserID, orderID: orderID, on: req.db)
    try await answerToast("Жду голосовое", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Отправьте голосовое сообщение — оно будет передано повару.",
            replyMarkup: nil
        ),
        logger: logger
    )
}

func handleOrderTrackCallback(
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
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          user.typedRole == .client,
          order.$client.id == user.id else {
        try await answerToast("Только для клиента по этому заказу", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    guard order.typedStatus == .onTheWay else {
        try await answerToast("Курьер ещё не в пути", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    try await answerToast("Запрашиваю геолокацию", callbackQueryID: callbackQueryID, client: client, logger: logger)
    guard let cookTelegramID = try await findTelegramIDForUser(order.$cook.id, on: req.db) else {
        return
    }
    let title = order.dish?.title ?? "Блюдо"
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: cookTelegramID,
            text: "📍 Клиент запросил геолокацию курьера по заказу «\(title)». Нажмите кнопку на карточке заказа, чтобы отправить её.",
            replyMarkup: nil
        ),
        logger: logger
    )
}

func handleOrderReportCallback(
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
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          user.typedRole == .client,
          order.$client.id == user.id else {
        try await answerToast("Только для клиента по этому заказу", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    try await ConversationService.startReport(for: telegramUserID, orderID: orderID, on: req.db)
    try await answerToast("Жалоба", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Опишите проблему с заказом — мы передадим её повару и учтём в статистике.",
            replyMarkup: nil
        ),
        logger: logger
    )
}

func handleOrderSendGeoCallback(
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
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          user.typedRole == .cook,
          order.$cook.id == user.id else {
        try await answerToast("Только для повара", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    try await ConversationService.startOrderLocation(for: telegramUserID, orderID: orderID, on: req.db)
    try await answerToast("Отправьте геолокацию", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Отправьте текущую геолокацию — она будет передана клиенту.",
            replyMarkup: nil
        ),
        logger: logger
    )
}

func handleOrderListenVoiceCallback(
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
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          user.typedRole == .cook,
          order.$cook.id == user.id else {
        try await answerToast("Только для повара", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    guard let voiceNote = order.voiceNote, !voiceNote.isEmpty else {
        try await answerToast("Голосовой комментарий не найден", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    try await client.sendVoice(
        TelegramSendVoiceRequest(
            chatID: chatID,
            voice: voiceNote,
            caption: nil,
            replyMarkup: nil
        ),
        logger: logger
    )
}

// MARK: - Карточки заказа (клиентская / поварская), доставка, оплата балансом
func handleOrderClientCardCallback(
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
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          user.typedRole == .cook,
          order.$cook.id == user.id else {
        try await answerToast("Только для повара", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    guard let clientUser = try await User.find(order.$client.id, on: req.db) else {
        return
    }
    var text = "👤 Клиент: \(clientUser.firstName)\n"
    if let phone = clientUser.phone, !phone.isEmpty {
        text += "📞 Телефон: \(phone)\n"
    }
    if let address = clientUser.address, !address.isEmpty {
        text += "📍 Адрес: \(address)\n"
    }
    let ordersCount = try await Order.query(on: req.db)
        .filter(\.$client.$id == clientUser.id!)
        .count()
    text += "📋 Всего заказов: \(ordersCount)"
    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: chatID, text: text, replyMarkup: nil),
        logger: logger
    )
}

func handleOrderCookCardCallback(
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
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          user.typedRole == .client,
          order.$client.id == user.id else {
        try await answerToast("Только для клиента по этому заказу", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    guard let cookUser = try await User.find(order.$cook.id, on: req.db) else {
        return
    }

    var text = "👨‍🍳 \(cookUser.firstName)\n"
    if let lastName = cookUser.lastName, !lastName.isEmpty {
        text = "👨‍🍳 \(cookUser.firstName) \(lastName)\n"
    }
    let deliveredCount = try await Order.query(on: req.db)
        .filter(\.$cook.$id == cookUser.id!)
        .filter(\.$status == OrderStatus.delivered.rawValue)
        .count()
    text += "✅ Доставленных заказов: \(deliveredCount)\n"
    let avgRating = try await Order.query(on: req.db)
        .filter(\.$cook.$id == cookUser.id!)
        .filter(\.$rating != nil)
        .all()
        .compactMap { $0.rating }
    if !avgRating.isEmpty {
        let avg = Double(avgRating.reduce(0, +)) / Double(avgRating.count)
        text += "⭐ Рейтинг: \(String(format: "%.1f", avg)) (\(avgRating.count) оценок)\n"
    }
    if let address = cookUser.address, !address.isEmpty {
        text += "📍 Адрес: \(address)\n"
    }
    if let schedule = cookUser.pickupSchedule, !schedule.isEmpty {
        text += "🕐 Часы выдачи: \(schedule)\n"
    }
    let cookID = cookUser.id?.uuidString ?? ""
    var rows: [[TelegramInlineKeyboardButton]] = []
    var footer: [TelegramInlineKeyboardButton] = []
    footer.append(TelegramInlineKeyboardButton(
        text: "🗺 Карта",
        callbackData: "cook:map:\(cookID)"
    ))
    footer.append(TelegramInlineKeyboardButton(
        text: "📋 Меню повара",
        callbackData: "cook:menu:\(cookID)"
    ))
    let reviewCount = try await Order.query(on: req.db)
        .filter(\.$cook.$id == cookUser.id!)
        .filter(\.$reviewText != nil)
        .count()
    if reviewCount > 0 {
        footer.append(TelegramInlineKeyboardButton(
            text: "⭐ \(reviewCount)",
            callbackData: "cook:reviews:\(cookID)"
        ))
    }
    rows.append(footer)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: text,
            replyMarkup: TelegramInlineKeyboardMarkup(inlineKeyboard: rows)
        ),
        logger: logger
    )
}

func handleOrderDeliverCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    dishIDString: String,
    quantity: Int,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        try await sendRoleSelection(
            telegramUserID: telegramUserID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )
        return
    }

    guard user.typedRole == .client else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Только для клиентов", replyMarkup: nil),
            logger: logger
        )
        return
    }

    guard let dishID = UUID(uuidString: dishIDString),
          let dish = try await Dish.find(dishID, on: req.db),
          dish.isActive else {
        try await answerToast("Блюдо не найдено", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    if let address = user.address, !address.isEmpty {
        try await createOrderAndNotify(
            dish: dish,
            comment: nil,
            clientUser: user,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger,
            isDelivery: true,
            quantity: quantity
        )
        try await answerToast("Заказ с доставкой создан", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    try await ConversationService.startAddress(for: telegramUserID, dishID: dishID, on: req.db)
    try await ConversationService.setQuantity(for: telegramUserID, quantity: quantity, on: req.db)
    try await answerToast("Укажите адрес доставки", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Введите адрес доставки (например: г. Москва, ул. Ленина, 5) или отправьте '-' чтобы оформить самовывоз:",
            replyMarkup: nil
        ),
        logger: logger
    )
}

func handleOrderPayBalanceCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    dishIDString: String,
    quantity: Int,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          user.typedRole == .client,
          let dishID = UUID(uuidString: dishIDString),
          let dish = try await Dish.find(dishID, on: req.db),
          dish.isActive else {
        try await answerToast("Блюдо не найдено", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    let balance = user.balance ?? 0
    let totalPrice = dish.price * Double(quantity)
    guard balance > 0 else {
        try await answerToast("У вас нет баллов", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    let useBalance = min(balance, Int(totalPrice.rounded(.down)))
    try await createOrderAndNotify(
        dish: dish,
        comment: nil,
        clientUser: user,
        chatID: chatID,
        req: req,
        client: client,
        logger: logger,
        quantity: quantity,
        balanceUsed: useBalance
    )
    try await answerToast("Заказ создан, списано \(useBalance) баллов", callbackQueryID: callbackQueryID, client: client, logger: logger)
}

func handleOrderCommentCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    dishIDString: String,
    quantity: Int,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        try await sendRoleSelection(
            telegramUserID: telegramUserID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )
        return
    }

    guard user.typedRole == .client else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Только для клиентов", replyMarkup: nil),
            logger: logger
        )
        return
    }

    guard let dishID = UUID(uuidString: dishIDString),
          let dish = try await Dish.find(dishID, on: req.db),
          dish.isActive else {
        try await answerToast("Блюдо не найдено", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    try await ConversationService.startOrderComment(for: telegramUserID, dishID: dishID, on: req.db)
    try await ConversationService.setQuantity(for: telegramUserID, quantity: quantity, on: req.db)

    try await answerToast("Добавьте комментарий к заказу", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Введите комментарий к заказу (или '-' чтобы пропустить):",
            replyMarkup: nil
        ),
        logger: logger
    )
}
