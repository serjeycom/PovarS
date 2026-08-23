import Fluent
import Foundation
import Vapor

// MARK: - Точка входа: обработка всех входящих сообщений
func handleMessage(
    _ message: TelegramMessage,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    let telegramUserID = message.from?.id ?? 0
    let chatID = message.chat.id

    if let from = message.from {
        _ = try? await BotUserService.upsertFromTelegram(from, on: req.db)
    }

    if let payment = message.successfulPayment {
        try await handleSuccessfulPayment(
            payment: payment,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )
        return
    }

    if let location = message.location {
        guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
            return
        }

        if let state = try await ConversationService.getState(for: telegramUserID, on: req.db),
           state.typedStep == .waitingOrderLocation,
           user.typedRole == .cook,
           let orderIDString = state.draftDishID,
           let orderID = UUID(uuidString: orderIDString),
           let order = try await Order.find(orderID, on: req.db),
           order.$cook.id == user.id {
            try await ConversationService.clear(for: telegramUserID, on: req.db)
            guard let clientTelegramID = try await findTelegramIDForUser(order.$client.id, on: req.db) else {
                return
            }
            try await client.sendLocation(
                TelegramSendLocationRequest(
                    chatID: clientTelegramID,
                    latitude: location.latitude,
                    longitude: location.longitude,
                    title: nil,
                    address: nil
                ),
                logger: logger
            )
            let title = order.dish?.title ?? "Блюдо"
            try await client.sendMessage(
                TelegramSendMessageRequest(
                    chatID: clientTelegramID,
                    text: "🚚 Курьер в пути по заказу «\(title)». Вот его геолокация.",
                    replyMarkup: nil
                ),
                logger: logger
            )
            try await client.sendMessage(
                TelegramSendMessageRequest(
                    chatID: chatID,
                    text: "Геолокация отправлена клиенту.",
                    replyMarkup: nil
                ),
                logger: logger
            )
            return
        }

        user.latitude = location.latitude
        user.longitude = location.longitude
        try await user.save(on: req.db)

        guard user.typedRole == .client else {
            try await client.sendMessage(
                TelegramSendMessageRequest(
                    chatID: chatID,
                    text: "📍 Локация кухни сохранена. Клиенты в радиусе 10 км смогут найти ваши блюда.",
                    replyMarkup: nil
                ),
                logger: logger
            )
            return
        }

        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "Локация сохранена. Теперь найду блюда рядом.",
                replyMarkup: nil
            ),
            logger: logger
        )
        try await sendDishesForClient(
            telegramUserID: telegramUserID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )
        return
    }

    if let contact = message.contact {
        try await handleContactMessage(
            telegramUserID: telegramUserID,
            chatID: chatID,
            contact: contact,
            req: req,
            client: client,
            logger: logger
        )
        return
    }

    if let photo = message.photo, !photo.isEmpty {
        try await handleDishPhotoMessage(
            telegramUserID: telegramUserID,
            chatID: chatID,
            photo: photo,
            req: req,
            client: client,
            logger: logger
        )
        return
    }

    if let voice = message.voice {
        try await handleVoiceMessage(
            telegramUserID: telegramUserID,
            chatID: chatID,
            voice: voice,
            req: req,
            client: client,
            logger: logger
        )
        return
    }

    guard let text = message.text else { return }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

    switch trimmed {
    case let s where s == "/start" || s.hasPrefix("/start "):
        if s.hasPrefix("/start ") {
            let code = String(s.dropFirst("/start ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !code.isEmpty, let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) {
                if user.referredBy == nil {
                    user.pendingReferral = code
                    try await user.save(on: req.db)
                }
            }
        }
        try await sendRoleSelection(
            telegramUserID: telegramUserID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )

    case "/menu":
        try await sendMenu(
            telegramUserID: telegramUserID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )

    case "/cancel":
        try await ConversationService.clear(for: telegramUserID, on: req.db)
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Текущий сценарий отменен.", replyMarkup: nil),
            logger: logger
        )

    case "/status":
        try await handleStatusCommand(
            telegramUserID: telegramUserID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )

    default:
        if isCommand(trimmed) {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Некорректная команда", replyMarkup: nil),
                logger: logger
            )
            return
        }

        let handled = try await processConversationInput(
            telegramUserID: telegramUserID,
            chatID: chatID,
            text: trimmed,
            req: req,
            client: client,
            logger: logger
        )
        if handled { return }

        try await handleTextMenuShortcut(
            telegramUserID: telegramUserID,
            chatID: chatID,
            text: trimmed,
            req: req,
            client: client,
            logger: logger
        )
    }
}

// MARK: - Добавление блюда поваром (пошаговый флоу)
func startAddDishFlow(
    telegramUserID: Int64,
    chatID: Int64,
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

    guard user.typedRole == .cook else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Только для повара", replyMarkup: nil),
            logger: logger
        )
        return
    }

    try await ConversationService.startAddDish(for: telegramUserID, on: req.db)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Введите название блюда. Для отмены: /cancel",
            replyMarkup: nil
        ),
        logger: logger
    )
}

// MARK: - Машина состояний диалогов (FSM)
func processConversationInput(
    telegramUserID: Int64,
    chatID: Int64,
    text: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws -> Bool {
    guard let state = try await ConversationService.getState(for: telegramUserID, on: req.db),
          let step = state.typedStep else {
        return false
    }

    let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db)
    let role = user?.typedRole

    switch step {
    case .waitingOrderComment:
        guard role == .client, let clientUser = user else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для клиентов.", replyMarkup: nil),
                logger: logger
            )
            return true
        }
        guard let dishIDString = state.draftDishID,
              let dishID = UUID(uuidString: dishIDString),
              let dish = try await Dish.find(dishID, on: req.db) else {
            try await ConversationService.clear(for: telegramUserID, on: req.db)
            return true
        }
        let comment = text == "-" ? nil : text
        let quantity = try await ConversationService.getQuantity(for: telegramUserID, on: req.db)
        try await ConversationService.clear(for: telegramUserID, on: req.db)
        try await createOrderAndNotify(
            dish: dish,
            comment: comment,
            clientUser: clientUser,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger,
            quantity: quantity
        )
        return true

    case .waitingDishTitle, .waitingDishDetails, .waitingDishPrice,
         .waitingEditTitle, .waitingEditDetails, .waitingEditPrice:
        guard let role else {
            try await client.sendMessage(
                TelegramSendMessageRequest(
                    chatID: chatID,
                    text: "Эта функция только для повара. Выберите роль через /start",
                    replyMarkup: nil
                ),
                logger: logger
            )
            return true
        }
        guard role == .cook, let cookUser = user, let cookID = cookUser.id else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для поваров.", replyMarkup: nil),
                logger: logger
            )
            return true
        }

        switch step {
        case .waitingDishTitle:
            let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                try await client.sendMessage(
                    TelegramSendMessageRequest(chatID: chatID, text: "Название не должно быть пустым.", replyMarkup: nil),
                    logger: logger
                )
                return true
            }
            state.draftTitle = title
            state.step = ConversationStep.waitingDishDetails.rawValue
            try await state.save(on: req.db)
            try await client.sendMessage(
                TelegramSendMessageRequest(
                    chatID: chatID,
                    text: "Добавьте описание блюда (или отправьте '-' чтобы пропустить).",
                    replyMarkup: nil
                ),
                logger: logger
            )
            return true

        case .waitingDishDetails:
            state.draftDetails = text == "-" ? nil : text
            state.step = ConversationStep.waitingDishPrice.rawValue
            try await state.save(on: req.db)
            try await client.sendMessage(
                TelegramSendMessageRequest(
                    chatID: chatID,
                    text: "Введите цену в рублях, например: 450 или 450.50",
                    replyMarkup: nil
                ),
                logger: logger
            )
            return true

        case .waitingDishPrice:
            let normalized = text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ",", with: ".")
            guard let price = Double(normalized), price > 0 else {
                try await client.sendMessage(
                    TelegramSendMessageRequest(chatID: chatID, text: "Некорректная цена. Пример: 450", replyMarkup: nil),
                    logger: logger
                )
                return true
            }
            let dish = Dish(
                cookID: cookID,
                title: state.draftTitle ?? "Без названия",
                details: state.draftDetails,
                price: price
            )
            try await dish.save(on: req.db)
            state.draftDishID = dish.id?.uuidString
            state.step = ConversationStep.waitingDishType.rawValue
            try await state.save(on: req.db)
            let typeButtons = DishType.allCases.map { type in
                TelegramInlineKeyboardButton(
                    text: type.title,
                    callbackData: "dish:type:\(dish.id?.uuidString ?? ""):\(type.rawValue)"
                )
            }
            let skipButton = TelegramInlineKeyboardButton(text: "Пропустить", callbackData: "dish:type:\(dish.id?.uuidString ?? ""):skip")
            try await client.sendMessage(
                TelegramSendMessageRequest(
                    chatID: chatID,
                    text: "Блюдо добавлено: \(dish.title). Выберите категорию (или пропустите):",
                    replyMarkup: TelegramInlineKeyboardMarkup(inlineKeyboard: [typeButtons, [skipButton]])
                ),
                logger: logger
            )
            return true

        case .waitingEditTitle:
            if text != "-" {
                let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else {
                    try await client.sendMessage(
                        TelegramSendMessageRequest(chatID: chatID, text: "Название не должно быть пустым.", replyMarkup: nil),
                        logger: logger
                    )
                    return true
                }
                state.draftTitle = title
            }
            state.step = ConversationStep.waitingEditDetails.rawValue
            try await state.save(on: req.db)
            try await client.sendMessage(
                TelegramSendMessageRequest(
                    chatID: chatID,
                    text: "Введите новое описание блюда (или отправьте '-' чтобы оставить текущее):",
                    replyMarkup: nil
                ),
                logger: logger
            )
            return true

        case .waitingEditDetails:
            if text != "-" {
                state.draftDetails = text
            }
            state.step = ConversationStep.waitingEditPrice.rawValue
            try await state.save(on: req.db)
            try await client.sendMessage(
                TelegramSendMessageRequest(
                    chatID: chatID,
                    text: "Введите новую цену в рублях, например: 450 или 450.50 (или отправьте '-' чтобы оставить текущую):",
                    replyMarkup: nil
                ),
                logger: logger
            )
            return true

        case .waitingEditPrice:
            var newPrice: Double?
            if text != "-" {
                let normalized = text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: ",", with: ".")
                guard let price = Double(normalized), price > 0 else {
                    try await client.sendMessage(
                        TelegramSendMessageRequest(chatID: chatID, text: "Некорректная цена. Пример: 450", replyMarkup: nil),
                        logger: logger
                    )
                    return true
                }
                newPrice = price
            }
            guard let dishIDString = state.draftDishID,
                  let dishID = UUID(uuidString: dishIDString),
                  let dish = try await Dish.find(dishID, on: req.db) else {
                try await ConversationService.clear(for: telegramUserID, on: req.db)
                return true
            }
            if let title = state.draftTitle {
                dish.title = title
            }
            if let details = state.draftDetails {
                dish.details = details
            }
            if let price = newPrice {
                dish.price = price
            }
            try await dish.save(on: req.db)
            try await ConversationService.clear(for: telegramUserID, on: req.db)
            try await client.sendMessage(
                TelegramSendMessageRequest(
                    chatID: chatID,
                    text: "Блюдо обновлено: \(dish.title)",
                    replyMarkup: nil
                ),
                logger: logger
            )
            try await sendMenu(
                telegramUserID: telegramUserID,
                chatID: chatID,
                req: req,
                client: client,
                logger: logger
            )
            return true

        case .waitingOrderComment, .waitingPickupSchedule, .waitingOrderWindow, .waitingPickupTime, .waitingAddress, .waitingDishPhoto, .waitingPortions, .waitingSurpriseBudget, .waitingCookingDays, .waitingReviewText, .waitingReviewPhoto, .waitingOrderQuantity, .waitingAddressName, .waitingAddressText, .waitingOrderAddress, .waitingChatMessage, .waitingSearchKeyword, .waitingSearchMaxPrice, .waitingReferralCode, .waitingDishType, .waitingOrderLocation, .waitingReport, .waitingVoiceComment, .waitingPromoCode, .waitingPromoCreate:
            break
        }
        return true

    case .waitingPickupSchedule:
        guard role == .cook, let cookUser = user else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для поваров.", replyMarkup: nil),
                logger: logger
            )
            return true
        }
        try await ConversationService.clear(for: telegramUserID, on: req.db)
        if text == "-" {
            cookUser.pickupSchedule = nil
            try await cookUser.save(on: req.db)
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Расписание выдачи убрано.", replyMarkup: nil),
                logger: logger
            )
        } else {
            cookUser.pickupSchedule = text
            try await cookUser.save(on: req.db)
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Часы выдачи: \(text)", replyMarkup: nil),
                logger: logger
            )
        }
        return true

    case .waitingOrderWindow:
        guard role == .cook else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для поваров.", replyMarkup: nil),
                logger: logger
            )
            return true
        }
        guard let orderIDString = state.draftDishID,
              let orderID = UUID(uuidString: orderIDString),
              let order = try await Order.find(orderID, on: req.db) else {
            try await ConversationService.clear(for: telegramUserID, on: req.db)
            return true
        }
        try await ConversationService.clear(for: telegramUserID, on: req.db)
        if text == "-" {
            order.pickupWindow = nil
            try await order.save(on: req.db)
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Окно выдачи для заказа убрано.", replyMarkup: nil),
                logger: logger
            )
        } else {
            order.pickupWindow = text
            try await order.save(on: req.db)
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Окно выдачи заказа: \(text)", replyMarkup: nil),
                logger: logger
            )
        }
        return true

    case .waitingPickupTime:
        guard role == .client else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для клиентов.", replyMarkup: nil),
                logger: logger
            )
            return true
        }
        guard let orderIDString = state.draftDishID,
              let orderID = UUID(uuidString: orderIDString),
              let order = try await Order.find(orderID, on: req.db) else {
            try await ConversationService.clear(for: telegramUserID, on: req.db)
            return true
        }
        try await ConversationService.clear(for: telegramUserID, on: req.db)
        if text == "-" {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Время получения не указано.", replyMarkup: nil),
                logger: logger
            )
        } else {
            order.pickupTime = text
            try await order.save(on: req.db)
            try await client.sendMessage(
                TelegramSendMessageRequest(
                    chatID: chatID,
                    text: "Отлично, подойдёте к \(text). Повар получит уведомление.",
                    replyMarkup: nil
                ),
                logger: logger
            )
            guard let cookTelegramID = try await findTelegramIDForUser(order.$cook.id, on: req.db) else {
                return true
            }
            let shortID = String(order.id?.uuidString.prefix(8) ?? "")
            let deliveryAction = order.isDelivery == true ? "Доставить заказ" : "Клиент заберёт заказ"
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: cookTelegramID, text: "\(deliveryAction) #\(shortID) к \(text)", replyMarkup: nil),
                logger: logger
            )
        }
        return true

    case .waitingDishPhoto:
        guard role == .cook else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для поваров.", replyMarkup: nil),
                logger: logger
            )
            return true
        }
        guard let dishIDString = state.draftDishID,
              let dishID = UUID(uuidString: dishIDString),
              let dish = try await Dish.find(dishID, on: req.db) else {
            try await ConversationService.clear(for: telegramUserID, on: req.db)
            return true
        }
        guard text != "-" else {
            try await ConversationService.clear(for: telegramUserID, on: req.db)
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Блюдо добавлено: \(dish.title)", replyMarkup: nil),
                logger: logger
            )
            try await sendMenu(
                telegramUserID: telegramUserID,
                chatID: chatID,
                req: req,
                client: client,
                logger: logger
            )
            return true
        }
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Отправьте фото блюда (или '-' чтобы пропустить):", replyMarkup: nil),
            logger: logger
        )
        return true

    case .waitingAddress:
        guard let user else {
            try await sendRoleSelection(
                telegramUserID: telegramUserID,
                chatID: chatID,
                req: req,
                client: client,
                logger: logger
            )
            return true
        }
        let pendingDishIDString = state.draftDishID
        try await ConversationService.clear(for: telegramUserID, on: req.db)

        guard text != "-" else {
            if user.typedRole == .client, pendingDishIDString != nil {
                try await client.sendMessage(
                    TelegramSendMessageRequest(chatID: chatID, text: "Хорошо, оформим как самовывоз.", replyMarkup: nil),
                    logger: logger
                )
            } else {
                try await client.sendMessage(
                    TelegramSendMessageRequest(chatID: chatID, text: "Адрес не указан.", replyMarkup: nil),
                    logger: logger
                )
            }
            return true
        }

        user.address = text
        try await user.save(on: req.db)

        if user.typedRole == .client,
           let dishIDString = pendingDishIDString,
           let dishID = UUID(uuidString: dishIDString),
           let dish = try await Dish.find(dishID, on: req.db),
           dish.isActive {
            let quantity = try await ConversationService.getQuantity(for: telegramUserID, on: req.db)
            try await ConversationService.clear(for: telegramUserID, on: req.db)
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
        } else {
            try await ConversationService.clear(for: telegramUserID, on: req.db)
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Адрес сохранён: \(text)", replyMarkup: nil),
                logger: logger
            )
        }
        return true

    case .waitingPortions:
        guard role == .cook else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для поваров.", replyMarkup: nil),
                logger: logger
            )
            return true
        }
        guard let dishIDString = state.draftDishID,
              let dishID = UUID(uuidString: dishIDString),
              let dish = try await Dish.find(dishID, on: req.db) else {
            try await ConversationService.clear(for: telegramUserID, on: req.db)
            return true
        }
        guard text != "-" else {
            dish.cookedDate = formatDate(Date())
            dish.portionsTotal = nil
            dish.portionsLeft = nil
            try await dish.save(on: req.db)
            try await ConversationService.clear(for: telegramUserID, on: req.db)
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "«\(dish.title)» помечено на сегодня без лимита порций.", replyMarkup: nil),
                logger: logger
            )
            try await notifySubscribersOfCook(dish: dish, portions: nil, req: req, client: client, logger: logger)
            return true
        }
        guard let portions = Int(text), portions > 0 else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Введите количество порций числом, например: 5", replyMarkup: nil),
                logger: logger
            )
            return true
        }
        dish.cookedDate = formatDate(Date())
        dish.portionsTotal = portions
        dish.portionsLeft = portions
        try await dish.save(on: req.db)
        try await ConversationService.clear(for: telegramUserID, on: req.db)
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "«\(dish.title)» готовится сегодня, осталось \(portions) порций.", replyMarkup: nil),
            logger: logger
        )
        try await notifySubscribersOfCook(dish: dish, portions: portions, req: req, client: client, logger: logger)
        try await notifyWaitlistOnRestock(dish: dish, addedPortions: portions, req: req, client: client, logger: logger)
        return true

    case .waitingSurpriseBudget:
        guard role == .client else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для клиентов.", replyMarkup: nil),
                logger: logger
            )
            return true
        }
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let budget = Double(normalized), budget > 0 else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Введите бюджет числом в рублях, например: 500", replyMarkup: nil),
                logger: logger
            )
            return true
        }
        try await sendSurprise(
            telegramUserID: telegramUserID,
            chatID: chatID,
            budget: budget,
            req: req,
            client: client,
            logger: logger
        )
        return true

    case .waitingCookingDays:
        guard role == .cook, let cookUser = user else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для поваров.", replyMarkup: nil),
                logger: logger
            )
            return true
        }
        try await ConversationService.clear(for: telegramUserID, on: req.db)
        if text == "-" {
            cookUser.cookingDays = nil
            try await cookUser.save(on: req.db)
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Дни готовки убраны. Блюда видны всегда.", replyMarkup: nil),
                logger: logger
            )
        } else {
            let days = text
                .lowercased()
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: ",")
            cookUser.cookingDays = days
            try await cookUser.save(on: req.db)
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Дни готовки: \(days)", replyMarkup: nil),
                logger: logger
            )
        }
        return true

    case .waitingReviewText:
        guard role == .client else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для клиентов.", replyMarkup: nil),
                logger: logger
            )
            return true
        }
        guard let state = try await ConversationService.getState(for: telegramUserID, on: req.db),
              let orderIDString = state.draftDishID,
              let orderID = UUID(uuidString: orderIDString),
              let order = try await Order.find(orderID, on: req.db) else {
            try await ConversationService.clear(for: telegramUserID, on: req.db)
            return true
        }
        if text != "-" {
            order.reviewText = text
            try await order.save(on: req.db)
        }
        guard let orderIDValue = order.id else {
            try await ConversationService.clear(for: telegramUserID, on: req.db)
            return true
        }
        try await ConversationService.startReviewPhoto(for: telegramUserID, orderID: orderIDValue, on: req.db)
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "Хотите приложить фото блюда к отзыву? (отправьте фото или '-' чтобы пропустить)",
                replyMarkup: nil
            ),
            logger: logger
        )
        return true

    case .waitingReviewPhoto:
        guard role == .client else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для клиентов.", replyMarkup: nil),
                logger: logger
            )
            return true
        }
        try await ConversationService.clear(for: telegramUserID, on: req.db)
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Спасибо за отзыв! ⭐", replyMarkup: nil),
            logger: logger
        )
        return true

    case .waitingOrderQuantity:
        guard role == .client, let clientUser = user else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для клиентов.", replyMarkup: nil),
                logger: logger
            )
            return true
        }
        guard let state = try await ConversationService.getState(for: telegramUserID, on: req.db),
              let dishIDString = state.draftDishID,
              let dishID = UUID(uuidString: dishIDString),
              let dish = try await Dish.find(dishID, on: req.db),
              dish.isActive else {
            try await ConversationService.clear(for: telegramUserID, on: req.db)
            return true
        }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let quantity = Int(normalized), (1...20).contains(quantity) else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Введите число от 1 до 20, например: 2", replyMarkup: nil),
                logger: logger
            )
            return true
        }
        try await ConversationService.clear(for: telegramUserID, on: req.db)
        try await sendOrderConfirmDialog(
            telegramUserID: telegramUserID,
            chatID: chatID,
            dishID: dishID,
            quantity: quantity,
            req: req,
            client: client,
            logger: logger
        )
        return true

    case .waitingAddressName:
        guard let state = try await ConversationService.getState(for: telegramUserID, on: req.db) else {
            return true
        }
        let addressIDString = state.draftTitle
        let existingID = addressIDString.flatMap { UUID(uuidString: $0) }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Введите название, например: «Дом» или «Работа».", replyMarkup: nil),
                logger: logger
            )
            return true
        }
        try await ConversationService.startAddressText(for: telegramUserID, addressID: existingID, on: req.db)
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "Теперь введите адрес (или отправьте геопозицию, или '-' чтобы взять текущий).",
                replyMarkup: nil
            ),
            logger: logger
        )
        return true

    case .waitingAddressText:
        guard role == .client, let clientUser = user,
              let state = try await ConversationService.getState(for: telegramUserID, on: req.db),
              let existingIDString = state.draftTitle,
              let existingID = UUID(uuidString: existingIDString) else {
            try await ConversationService.clear(for: telegramUserID, on: req.db)
            return true
        }
        let name = state.draftDetails ?? "Адрес"
        if let address = try await Address.query(on: req.db).filter(\.$id == existingID).first() {
            address.text = text
            address.name = name
            try await address.save(on: req.db)
        } else {
            let address = Address(userID: clientUser.id!, name: name, latitude: nil, longitude: nil, text: text, isDefault: nil)
            try await address.save(on: req.db)
        }
        try await ConversationService.clear(for: telegramUserID, on: req.db)
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "Адрес сохранён: \(name) — \(text)",
                replyMarkup: nil
            ),
            logger: logger
        )
        return true

    case .waitingOrderAddress:
        guard role == .client, let clientUser = user else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для клиентов.", replyMarkup: nil),
                logger: logger
            )
            return true
        }
        guard let state = try await ConversationService.getState(for: telegramUserID, on: req.db),
              let orderIDString = state.draftDishID,
              let orderID = UUID(uuidString: orderIDString),
              let order = try await Order.find(orderID, on: req.db),
              order.$client.id == clientUser.id else {
            try await ConversationService.clear(for: telegramUserID, on: req.db)
            return true
        }
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Введите адрес доставки.", replyMarkup: nil),
                logger: logger
            )
            return true
        }
        order.shippingAddress = address
        order.isDelivery = true
        try await order.save(on: req.db)
        try await ConversationService.clear(for: telegramUserID, on: req.db)
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "✅ Доставка включена. Адрес: \(address)",
                replyMarkup: nil
            ),
            logger: logger
        )
        let title = order.dish?.title ?? "Блюдо"
        if let cookTelegramID = try await findTelegramIDForUser(order.$cook.id, on: req.db) {
            try await client.sendMessage(
                TelegramSendMessageRequest(
                    chatID: cookTelegramID,
                    text: "🚚 Клиент добавил адрес доставки для заказа «\(title)»: \(address)",
                    replyMarkup: nil
                ),
                logger: logger
            )
        }
        return true

    case .waitingDishType:
        guard role == .cook, let cookUser = user,
              let state = try await ConversationService.getState(for: telegramUserID, on: req.db),
              let dishIDString = state.draftDishID,
              let dishID = UUID(uuidString: dishIDString),
              let dish = try await Dish.find(dishID, on: req.db),
              dish.$cook.id == cookUser.id else {
            try await ConversationService.clear(for: telegramUserID, on: req.db)
            return true
        }
        if text != "-" {
            let candidate = DishType.allCases.first { $0.title.lowercased() == text.lowercased() }
                ?? DishType.allCases.first { $0.rawValue.lowercased() == text.lowercased() }
            dish.dishType = candidate?.rawValue
            try await dish.save(on: req.db)
        }
        state.step = ConversationStep.waitingDishPhoto.rawValue
        try await state.save(on: req.db)
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "Отправьте фото блюда (или '-' чтобы без фото):",
                replyMarkup: nil
            ),
            logger: logger
        )
        return true

    case .waitingSearchKeyword:
        guard role == .client, let clientUser = user else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для клиентов.", replyMarkup: nil),
                logger: logger
            )
            return true
        }
        try await ConversationService.clear(for: telegramUserID, on: req.db)
        if text == "-" {
            clientUser.searchKeyword = nil
        } else {
            clientUser.searchKeyword = text
        }
        try await clientUser.save(on: req.db)
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Фильтр по слову сохранён.", replyMarkup: nil),
            logger: logger
        )
        try await sendSearchFiltersMenu(
            telegramUserID: telegramUserID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )
        return true

    case .waitingSearchMaxPrice:
        guard role == .client, let clientUser = user else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для клиентов.", replyMarkup: nil),
                logger: logger
            )
            return true
        }
        try await ConversationService.clear(for: telegramUserID, on: req.db)
        if text == "-" {
            clientUser.searchMaxPrice = nil
            try await clientUser.save(on: req.db)
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Фильтр по цене сброшен.", replyMarkup: nil),
                logger: logger
            )
        } else {
            let normalized = text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ",", with: ".")
            guard let maxPrice = Double(normalized), maxPrice > 0 else {
                try await client.sendMessage(
                    TelegramSendMessageRequest(chatID: chatID, text: "Введите цену числом, например: 500", replyMarkup: nil),
                    logger: logger
                )
                return true
            }
            clientUser.searchMaxPrice = maxPrice
            try await clientUser.save(on: req.db)
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Максимальная цена: \(Int(maxPrice))₽", replyMarkup: nil),
                logger: logger
            )
        }
        try await sendSearchFiltersMenu(
            telegramUserID: telegramUserID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )
        return true

    case .waitingReferralCode:
        try await ConversationService.clear(for: telegramUserID, on: req.db)
        if let clientUser = user, clientUser.referredBy == nil {
            clientUser.pendingReferral = text
            try await clientUser.save(on: req.db)
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Код сохранён. Выберите роль через /start, чтобы активировать бонусы.", replyMarkup: nil),
                logger: logger
            )
        }
        return true

    case .waitingChatMessage:
        guard let clientUser = user else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для участников заказа.", replyMarkup: nil),
                logger: logger
            )
            return true
        }
        guard let state = try await ConversationService.getState(for: telegramUserID, on: req.db),
              let orderIDString = state.draftDishID,
              let orderID = UUID(uuidString: orderIDString),
              let order = try await Order.find(orderID, on: req.db) else {
            try await ConversationService.clear(for: telegramUserID, on: req.db)
            return true
        }
        try await ConversationService.clear(for: telegramUserID, on: req.db)

        let isCook = role == .cook
        let isClient = role == .client
        guard (isCook && order.$cook.id == clientUser.id) || (isClient && order.$client.id == clientUser.id) else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Вы не участвуете в этом заказе.", replyMarkup: nil),
                logger: logger
            )
            return true
        }

        let recipientID: Int64
        if isCook {
            guard let clientTelegramID = try await findTelegramIDForUser(order.$client.id, on: req.db) else {
                return true
            }
            recipientID = clientTelegramID
        } else {
            guard let cookTelegramID = try await findTelegramIDForUser(order.$cook.id, on: req.db) else {
                return true
            }
            recipientID = cookTelegramID
        }

        let senderName = clientUser.firstName
        let roleMark = isCook ? "👨‍🍳 Повар" : "🙂 Клиент"
        let dishTitle = order.dish?.title ?? "Блюдо"
        let forwarded = "\(roleMark) \(senderName) пишет по заказу «\(dishTitle)» (#\(order.id?.uuidString.prefix(8) ?? "")):\n\(text)"
        let callbackOrderID = order.id?.uuidString ?? ""
        let markup = TelegramInlineKeyboardMarkup(inlineKeyboard: [[
            TelegramInlineKeyboardButton(text: "Ответить", callbackData: "order:reply:\(callbackOrderID):\(telegramUserID)"),
            TelegramInlineKeyboardButton(text: "Готово", callbackData: "order:reply_done:\(callbackOrderID)")
        ]])
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: recipientID, text: forwarded, replyMarkup: markup),
            logger: logger
        )
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: isCook ? "Ответ отправлен клиенту." : "Сообщение повару отправлено. Ожидайте ответ.",
                replyMarkup: nil
            ),
            logger: logger
        )
        return true

    case .waitingReport:
        guard let clientUser = user, clientUser.typedRole == .client,
              let state = try await ConversationService.getState(for: telegramUserID, on: req.db),
              let orderIDString = state.draftDishID,
              let orderID = UUID(uuidString: orderIDString),
              let order = try await Order.find(orderID, on: req.db),
              order.$client.id == clientUser.id else {
            try await ConversationService.clear(for: telegramUserID, on: req.db)
            return true
        }
        let reportText = text == "-" ? "Без описания" : text
        order.complaintText = reportText
        try await order.save(on: req.db)
        try await ConversationService.clear(for: telegramUserID, on: req.db)
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "⚠️ Жалоба отправлена. Мы рассмотрим её.",
                replyMarkup: nil
            ),
            logger: logger
        )
        if let cookTelegramID = try await findTelegramIDForUser(order.$cook.id, on: req.db) {
            let title = order.dish?.title ?? "Блюдо"
            try await client.sendMessage(
                TelegramSendMessageRequest(
                    chatID: cookTelegramID,
                    text: "⚠️ На заказ «\(title)» поступила жалоба: \(reportText)",
                    replyMarkup: nil
                ),
                logger: logger
            )
        }
        return true

    case .waitingVoiceComment, .waitingOrderLocation:
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "Пожалуйста, отправьте голосовое или геопозицию, как просил бот.",
                replyMarkup: nil
            ),
            logger: logger
        )
        return true

    case .waitingPromoCode:
        guard let clientUser = user, clientUser.typedRole == .client,
              let state = try await ConversationService.getState(for: telegramUserID, on: req.db),
              let dishIDString = state.draftDishID,
              let dishID = UUID(uuidString: dishIDString),
              let dish = try await Dish.find(dishID, on: req.db),
              dish.isActive else {
            try await ConversationService.clear(for: telegramUserID, on: req.db)
            return true
        }
        let quantity = Int(state.draftDetails ?? "1") ?? 1
        guard let promo = try await PromoCode.query(on: req.db)
            .filter(\.$code == text.trimmingCharacters(in: .whitespacesAndNewlines))
            .filter(\.$cook.$id == dish.$cook.id)
            .filter(\.$isActive == true)
            .first() else {
            try await client.sendMessage(
                TelegramSendMessageRequest(
                    chatID: chatID,
                    text: "Промокод не найден или не действует для этого повара.",
                    replyMarkup: nil
                ),
                logger: logger
            )
            return true
        }
        let totalPrice = dish.price * Double(quantity)
        let discount = totalPrice * Double(promo.discountPercent) / 100.0
        try await ConversationService.clear(for: telegramUserID, on: req.db)
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "🎟 Промокод \(promo.code) применён. Скидка \(promo.discountPercent)%.",
                replyMarkup: nil
            ),
            logger: logger
        )
        try await createOrderAndNotify(
            dish: dish,
            comment: nil,
            clientUser: clientUser,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger,
            quantity: quantity,
            promoCode: promo.code,
            promoDiscount: discount
        )
        return true

    case .waitingPromoCreate:
        guard let cookUser = user, cookUser.typedRole == .cook, let cookID = cookUser.id else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Эта функция только для поваров.", replyMarkup: nil),
                logger: logger
            )
            return true
        }
        let parts = text.split(separator: " ").map(String.init)
        guard parts.count == 2,
              let discount = Int(parts[1]), (1...90).contains(discount),
              parts[0].count >= 3, parts[0].count <= 20 else {
            try await client.sendMessage(
                TelegramSendMessageRequest(
                    chatID: chatID,
                    text: "Формат: КОД СКИДКА\nНапример: SUMMER 10 (скидка 10%).",
                    replyMarkup: nil
                ),
                logger: logger
            )
            return true
        }
        let code = parts[0].uppercased()
        if let existing = try await PromoCode.query(on: req.db)
            .filter(\.$code == code)
            .filter(\.$cook.$id == cookID)
            .first() {
            existing.discountPercent = discount
            existing.isActive = true
            try await existing.save(on: req.db)
            try await ConversationService.clear(for: telegramUserID, on: req.db)
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "🎟 Промокод \(code) обновлён: скидка \(discount)%.", replyMarkup: nil),
                logger: logger
            )
            return true
        }
        let promo = PromoCode(cookID: cookID, code: code, discountPercent: discount)
        try await promo.save(on: req.db)
        try await ConversationService.clear(for: telegramUserID, on: req.db)
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "🎟 Промокод \(code) создан: скидка \(discount)%.", replyMarkup: nil),
            logger: logger
        )
        return true
    }
}

// MARK: - Спецтипы сообщений: голос, контакт, фото блюда
func handleVoiceMessage(
    telegramUserID: Int64,
    chatID: Int64,
    voice: TelegramVoice,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          let state = try await ConversationService.getState(for: telegramUserID, on: req.db) else {
        return
    }

    guard state.typedStep == .waitingVoiceComment, user.typedRole == .client,
          let orderIDString = state.draftDishID,
          let orderID = UUID(uuidString: orderIDString),
          let order = try await Order.find(orderID, on: req.db),
          order.$client.id == user.id else {
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "Сейчас голосовое не требуется. Отправьте текст.",
                replyMarkup: nil
            ),
            logger: logger
        )
        return
    }

    order.voiceNote = voice.fileID
    try await order.save(on: req.db)
    try await ConversationService.clear(for: telegramUserID, on: req.db)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "🎤 Голосовой комментарий передан повару.",
            replyMarkup: nil
        ),
        logger: logger
    )

    guard let cookTelegramID = try await findTelegramIDForUser(order.$cook.id, on: req.db) else {
        return
    }
    let title = order.dish?.title ?? "Блюдо"
    try await client.sendVoice(
        TelegramSendVoiceRequest(
            chatID: cookTelegramID,
            voice: voice.fileID,
            caption: "🎤 Голосовой комментарий клиента по заказу «\(title)»",
            replyMarkup: nil
        ),
        logger: logger
    )
}

func handleContactMessage(
    telegramUserID: Int64,
    chatID: Int64,
    contact: TelegramContact,
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
    user.phone = contact.phoneNumber
    try await user.save(on: req.db)
    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: chatID, text: "Номер сохранён: \(contact.phoneNumber)", replyMarkup: nil),
        logger: logger
    )
}

func handleDishPhotoMessage(
    telegramUserID: Int64,
    chatID: Int64,
    photo: [TelegramPhotoSize],
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          let state = try await ConversationService.getState(for: telegramUserID, on: req.db) else {
        return
    }

    guard let largest = photo.max(by: { ($0.width * $0.height) < ($1.width * $1.height) }) else {
        return
    }

    if state.typedStep == .waitingReviewPhoto, user.typedRole == .client {
        guard let orderIDString = state.draftDishID,
              let orderID = UUID(uuidString: orderIDString),
              let order = try await Order.find(orderID, on: req.db),
              order.$client.id == user.id else {
            try await ConversationService.clear(for: telegramUserID, on: req.db)
            return
        }
        order.reviewPhoto = largest.fileID
        try await order.save(on: req.db)
        try await ConversationService.clear(for: telegramUserID, on: req.db)
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Спасибо! Фото добавлено к вашему отзыву.", replyMarkup: nil),
            logger: logger
        )
        return
    }

    guard user.typedRole == .cook,
          state.typedStep == .waitingDishPhoto,
          let dishIDString = state.draftDishID,
          let dishID = UUID(uuidString: dishIDString),
          let dish = try await Dish.find(dishID, on: req.db),
          dish.$cook.id == user.id else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Сейчас фото не требуется. Отправьте текст.", replyMarkup: nil),
            logger: logger
        )
        return
    }

    dish.photoFileID = largest.fileID
    try await dish.save(on: req.db)
    try await ConversationService.clear(for: telegramUserID, on: req.db)
    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: chatID, text: "Фото сохранено. Блюдо «\(dish.title)» готово!", replyMarkup: nil),
        logger: logger
    )
    try await sendMenu(
        telegramUserID: telegramUserID,
        chatID: chatID,
        req: req,
        client: client,
        logger: logger
    )
}
