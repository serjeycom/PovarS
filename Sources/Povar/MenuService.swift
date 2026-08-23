import Fluent
import Vapor

// MARK: - Выбор роли (клиент / повар)
func sendRoleSelection(
    telegramUserID: Int64,
    chatID: Int64,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    let markup = TelegramInlineKeyboardMarkup(inlineKeyboard: [
        [
            TelegramInlineKeyboardButton(text: "Я клиент", callbackData: "role:client")
        ],
        [
            TelegramInlineKeyboardButton(text: "Я повар", callbackData: "role:cook")
        ]
    ])
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Привет! Я бот Povar. Выберите вашу роль:",
            replyMarkup: markup
        ),
        logger: logger
    )
}

// MARK: - Главное меню
func sendMenu(
    telegramUserID: Int64,
    chatID: Int64,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          let role = user.typedRole else {
        try await sendRoleSelection(
            telegramUserID: telegramUserID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )
        return
    }

    let text: String
    let keyboard: [[TelegramKeyboardButton]]
    let balanceLine = user.balance.map { " 💰 \($0) баллов" } ?? ""
    switch role {
    case .client:
        text = "Меню клиента: используйте кнопки снизу или команды.\(balanceLine)"
        keyboard = [
            [TelegramKeyboardButton(text: "Найти блюда рядом")],
            [TelegramKeyboardButton(text: "🛒 Корзина")],
            [TelegramKeyboardButton(text: "🔍 Поиск и фильтры")],
            [TelegramKeyboardButton(text: "Удиви меня")],
            [TelegramKeyboardButton(text: "Мои заказы")],
            [TelegramKeyboardButton(text: "Избранное")],
            [TelegramKeyboardButton(text: "Мои повара")],
            [TelegramKeyboardButton(text: "Мои адреса")],
            [TelegramKeyboardButton(text: "Мой адрес")],
            [TelegramKeyboardButton(text: "Мой телефон")],
            [TelegramKeyboardButton(text: "Реферальная программа")],
            [TelegramKeyboardButton(text: "Сменить роль")]
        ]
    case .cook:
        let ordersLabel = user.isAcceptingOrders == false
            ? "Включить приём заказов"
            : "Отключить приём заказов"
        text = "Меню повара: используйте кнопки снизу или команды.\(balanceLine)"
        keyboard = [
            [TelegramKeyboardButton(text: "Добавить блюдо")],
            [TelegramKeyboardButton(text: "Мои блюда")],
            [TelegramKeyboardButton(text: "Заказы повара")],
            [TelegramKeyboardButton(text: "Промокоды")],
            [TelegramKeyboardButton(text: "Статистика")],
            [TelegramKeyboardButton(text: "Часы выдачи")],
            [TelegramKeyboardButton(text: "Дни готовки")],
            [TelegramKeyboardButton(text: "Мой адрес")],
            [TelegramKeyboardButton(text: "📍 Моя кухня", requestLocation: true)],
            [TelegramKeyboardButton(text: ordersLabel)],
            [TelegramKeyboardButton(text: "Сменить роль")]
        ]
    }

    let markup = TelegramReplyKeyboardMarkup(
        keyboard: keyboard,
        resizeKeyboard: true,
        isPersistent: true,
        oneTimeKeyboard: false
    )
    try await client.sendMessageWithReplyKeyboard(
        TelegramSendMessageReplyKeyboardRequest(chatID: chatID, text: text, replyMarkup: markup),
        logger: logger
    )
}

// MARK: - Обработка текстовых команд-ярлыков меню
func handleTextMenuShortcut(
    telegramUserID: Int64,
    chatID: Int64,
    text: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          let role = user.typedRole else {
        try await sendRoleSelection(
            telegramUserID: telegramUserID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )
        return
    }

    switch text {
    case "Найти блюда рядом":
        guard role == .client else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для клиентов.", replyMarkup: nil),
                logger: logger
            )
            return
        }
        try await sendDishesForClient(
            telegramUserID: telegramUserID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )

    case "Мои заказы":
        guard role == .client else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для клиентов.", replyMarkup: nil),
                logger: logger
            )
            return
        }
        try await sendClientOrders(
            telegramUserID: telegramUserID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )

    case "Мои блюда":
        guard role == .cook else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для поваров.", replyMarkup: nil),
                logger: logger
            )
            return
        }
        try await sendCookDishes(
            telegramUserID: telegramUserID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )

    case "Добавить блюдо":
        guard role == .cook else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для поваров.", replyMarkup: nil),
                logger: logger
            )
            return
        }
        try await startAddDishFlow(
            telegramUserID: telegramUserID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )

    case "Заказы повара":
        guard role == .cook, let cookID = user.id else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для поваров.", replyMarkup: nil),
                logger: logger
            )
            return
        }
        let orders = try await Order.query(on: req.db)
            .filter(\.$cook.$id == cookID)
            .with(\.$client)
            .with(\.$cook)
            .with(\.$dish)
            .sort(\.$createdAt, .descending)
            .all()
        try await sendCookOrders(
            orders: orders,
            cookChatID: chatID,
            req: req,
            client: client,
            logger: logger
        )

    case "Статистика":
        guard role == .cook, let cookID = user.id else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для поваров.", replyMarkup: nil),
                logger: logger
            )
            return
        }
        try await sendCookAnalytics(
            cookID: cookID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )

    case "Промокоды":
        guard role == .cook, let cookID = user.id else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для поваров.", replyMarkup: nil),
                logger: logger
            )
            return
        }
        try await sendPromoCodesMenu(
            cookID: cookID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )

    case "Часы выдачи":
        guard role == .cook else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для поваров.", replyMarkup: nil),
                logger: logger
            )
            return
        }
        try await ConversationService.startPickupSchedule(for: telegramUserID, on: req.db)
        let currentLine = user.pickupSchedule.map { "\nТекущее: \($0)" } ?? ""
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "Введите часы выдачи (например: 10:00-18:00)\(currentLine)\nОтправьте '-' чтобы убрать.",
                replyMarkup: nil
            ),
            logger: logger
        )

    case "Удиви меня":
        guard role == .client else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для клиентов.", replyMarkup: nil),
                logger: logger
            )
            return
        }
        guard user.latitude != nil, user.longitude != nil else {
            try await client.sendMessage(
                TelegramSendMessageRequest(
                    chatID: chatID,
                    text: "Сначала поделитесь геолокацией через «Найти блюда рядом».",
                    replyMarkup: nil
                ),
                logger: logger
            )
            return
        }
        try await ConversationService.startSurpriseBudget(for: telegramUserID, budget: nil, on: req.db)
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "🎲 Удивлю вас! Введите ваш бюджет в рублях, например: 500",
                replyMarkup: nil
            ),
            logger: logger
        )

    case "Мои адреса":
        guard role == .client else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для клиентов.", replyMarkup: nil),
                logger: logger
            )
            return
        }
        try await sendMyAddresses(
            telegramUserID: telegramUserID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )

    case "Мои повара":
        guard role == .client else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для клиентов.", replyMarkup: nil),
                logger: logger
            )
            return
        }
        try await sendMyCooks(
            telegramUserID: telegramUserID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )

    case "Дни готовки":
        guard role == .cook else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для поваров.", replyMarkup: nil),
                logger: logger
            )
            return
        }
        try await ConversationService.startCookingDays(for: telegramUserID, on: req.db)
        let currentLine = user.cookingDays.map { "\nТекущие: \($0)" } ?? ""
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "В какие дни вы готовите? Перечислите через запятую: пн, вт, ср, чт, пт, сб, вс\(currentLine)\nОтправьте '-' чтобы готовить всегда.",
                replyMarkup: nil
            ),
            logger: logger
        )

    case "Избранное":
        guard role == .client else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для клиентов.", replyMarkup: nil),
                logger: logger
            )
            return
        }
        try await sendFavoriteDishes(
            telegramUserID: telegramUserID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )

    case "Мой телефон":
        guard role == .client else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для клиентов.", replyMarkup: nil),
                logger: logger
            )
            return
        }
        let keyboard = TelegramReplyKeyboardMarkup(
            keyboard: [[TelegramKeyboardButton(text: "📱 Поделиться номером", requestContact: true)]],
            resizeKeyboard: true,
            isPersistent: true,
            oneTimeKeyboard: true
        )
        try await client.sendMessageWithReplyKeyboard(
            TelegramSendMessageReplyKeyboardRequest(
                chatID: chatID,
                text: "Нажмите кнопку, чтобы поделиться номером. Он будет виден повару при заказе.",
                replyMarkup: keyboard
            ),
            logger: logger
        )

    case "Отключить приём заказов":
        guard role == .cook else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для поваров.", replyMarkup: nil),
                logger: logger
            )
            return
        }
        user.isAcceptingOrders = false
        try await user.save(on: req.db)
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Приём заказов отключен. Ваши блюда скрыты из поиска.", replyMarkup: nil),
            logger: logger
        )

    case "Включить приём заказов":
        guard role == .cook else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для поваров.", replyMarkup: nil),
                logger: logger
            )
            return
        }
        user.isAcceptingOrders = true
        try await user.save(on: req.db)
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Приём заказов включен. Ваши блюда снова видны клиентам.", replyMarkup: nil),
            logger: logger
        )

    case "Мой адрес":
        try await ConversationService.startAddress(for: telegramUserID, dishID: nil, on: req.db)
        let roleHint = role == .cook ? "адрес, где вы готовите" : "адрес доставки"
        let currentLine = user.address.map { "\nТекущий: \($0)" } ?? ""
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "Введите ваш \(roleHint) (например: г. Москва, ул. Ленина, 5)\(currentLine)\nОтправьте '-' чтобы убрать.",
                replyMarkup: nil
            ),
            logger: logger
        )

    case "Сменить роль":
        try await sendRoleSelection(
            telegramUserID: telegramUserID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )

    case "🛒 Корзина":
        guard role == .client else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для клиентов.", replyMarkup: nil),
                logger: logger
            )
            return
        }
        try await sendCartMenu(
            telegramUserID: telegramUserID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )

    case "🔍 Поиск и фильтры":
        guard role == .client else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для клиентов.", replyMarkup: nil),
                logger: logger
            )
            return
        }
        try await sendSearchFiltersMenu(
            telegramUserID: telegramUserID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )

    case "Реферальная программа":
        guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
            return
        }
        if user.referralCode == nil {
            user.referralCode = generateReferralCode()
            try await user.save(on: req.db)
        }
        let code = user.referralCode ?? ""
        var text = """
        🎁 Реферальная программа

        Ваш код: \(code)

        Поделитесь им с друзьями: пусть отправят боту /start \(code)
        или перейдут по ссылке t.me/PovarBot?start=\(code).

        Вы получите 100 баллов, когда друг зарегистрируется по вашему коду. Друг тоже получит 100 баллов!
        """
        if let referredBy = user.referredBy,
           let referrer = try await User.find(referredBy, on: req.db) {
            text += "\n\nВас пригласил: \(referrer.firstName) 💝"
        }
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: text, replyMarkup: nil),
            logger: logger
        )

    default:
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Некорректная команда", replyMarkup: nil),
            logger: logger
        )
    }
}
