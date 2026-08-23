import Fluent
import Foundation
import Vapor

// MARK: - Отправка заказов клиенту
func sendClientOrders(
    telegramUserID: Int64,
    chatID: Int64,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          let userID = user.id else {
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

    let orders = try await Order.query(on: req.db)
        .filter(\.$client.$id == userID)
        .with(\.$client)
        .with(\.$cook)
        .with(\.$dish)
        .sort(\.$createdAt, .descending)
        .all()

    guard !orders.isEmpty else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "У вас пока нет заказов.", replyMarkup: nil),
            logger: logger
        )
        return
    }

    for order in orders {
        let title = order.dish?.title ?? "Без названия"
        var text = """
        Блюдо \(title)
        Повар: \(order.cook.firstName)
        Статус: \(statusTitle(order.typedStatus ?? .new))
        Кол-во: \(order.quantity ?? 1)
        Сумма: \(formatPrice(order.totalPrice)) руб.
        Заказ #\(order.id?.uuidString ?? "")
        """
        if let window = order.pickupWindow ?? order.cook.pickupSchedule {
            text += "\nВремя выдачи: \(window)"
        }
        if let pickupTime = order.pickupTime {
            text += "\nЗаберу к: \(pickupTime)"
        }
        if let scheduledDate = order.scheduledDate {
            text += "\n📅 На день: \(scheduledDate)"
        }
        if let starsLine = formatStarsLine(order) {
            text += "\n\(starsLine)"
        }
        if order.balanceUsed > 0 {
            text += "\n💰 Оплачено баллами: \(order.balanceUsed)"
        }
        if let promoCode = order.promoCode {
            text += "\n🎟 Промокод: \(promoCode)"
        }
        if let voiceNote = order.voiceNote, !voiceNote.isEmpty {
            text += "\n🎤 Есть голосовой комментарий"
        }
        if order.isDelivery == true {
            let deliveryAddress = order.shippingAddress ?? order.client.address
            text += "\nДоставка по адресу: \(deliveryAddress ?? "не указан")"
        } else {
            let pickupAddress = order.cook.address ?? "не указан"
            text += "\nСамовывоз. Забрать: \(pickupAddress)"
        }

        var rows: [[TelegramInlineKeyboardButton]] = []
        if isClientCancelable(order: order) {
            rows.append([
                TelegramInlineKeyboardButton(
                    text: "Отменить заказ",
                    callbackData: "order:client_cancel:\(order.id?.uuidString ?? "")"
                )
            ])
        }
        let orderID = order.id?.uuidString ?? ""
        if let status = order.typedStatus, status != .delivered, status != .cancelled {
            var actionRow: [TelegramInlineKeyboardButton] = []
            actionRow.append(TelegramInlineKeyboardButton(
                text: "🕐 Перенести",
                callbackData: "order:reschedule:\(orderID)"
            ))
            if order.isDelivery == true {
                actionRow.append(TelegramInlineKeyboardButton(
                    text: "📍 Сменить адрес",
                    callbackData: "order:change_address:\(orderID)"
                ))
            } else {
                actionRow.append(TelegramInlineKeyboardButton(
                    text: "🚚 Доставить здесь",
                    callbackData: "order:change_address:\(orderID)"
                ))
            }
            actionRow.append(TelegramInlineKeyboardButton(
                text: "💬 Чат",
                callbackData: "order:chat:\(orderID)"
            ))
            actionRow.append(TelegramInlineKeyboardButton(
                text: "🎤 Голос",
                callbackData: "order:voice:\(orderID)"
            ))
            rows.append(actionRow)
        }
        if let status = order.typedStatus, status == .onTheWay {
            rows.append([
                TelegramInlineKeyboardButton(
                    text: "📍 Геолокация курьера",
                    callbackData: "order:track:\(orderID)"
                )
            ])
        }
        if order.typedStatus != .cancelled, order.typedStatus != .new {
            rows.append([
                TelegramInlineKeyboardButton(
                    text: "⚠️ Пожаловаться",
                    callbackData: "order:report:\(orderID)"
                )
            ])
        }
        if order.typedStatus == .ready {
            let action = order.isDelivery == true
                ? TelegramInlineKeyboardButton(text: "✅ Получил заказ", callbackData: "order:receive:\(order.id?.uuidString ?? "")")
                : TelegramInlineKeyboardButton(text: "Я у повара", callbackData: "order:pickup:\(order.id?.uuidString ?? "")")
            rows.append([action])
        }
        if order.typedStatus == .delivered, order.rating == nil {
            rows.append([
                TelegramInlineKeyboardButton(
                    text: "✅ Получил заказ",
                    callbackData: "order:receive:\(order.id?.uuidString ?? "")"
                )
            ])
        }
        if order.typedStatus == .delivered, let dishID = order.dish?.id {
            rows.append([
                TelegramInlineKeyboardButton(
                    text: "Заказать ещё",
                    callbackData: "order:repeat:\(dishID.uuidString)"
                )
            ])
        }
        if order.typedStatus == .delivered {
            rows.append([
                TelegramInlineKeyboardButton(
                    text: "👤 Карточка повара",
                    callbackData: "order:cook_card:\(orderID)"
                )
            ])
        }

        let markup = rows.isEmpty ? nil : TelegramInlineKeyboardMarkup(inlineKeyboard: rows)
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: text, replyMarkup: markup),
            logger: logger
        )
    }
}

// MARK: - Отправка заказов повару
func sendCookOrders(
    orders: [Order],
    cookChatID: Int64,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard !orders.isEmpty else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: cookChatID, text: "У вас пока нет заказов.", replyMarkup: nil),
            logger: logger
        )
        return
    }

    for order in orders {
        let shortID: String
        if let idPrefix = order.id?.uuidString.prefix(8), !idPrefix.isEmpty {
            shortID = String(idPrefix)
        } else {
            shortID = "-"
        }

        let title = order.dish?.title ?? "Блюдо"
        var text = "Заказ #\(shortID)\n\(title)\nКол-во: \(order.quantity ?? 1)\nКлиент: \(order.client.firstName)\nСумма: \(formatPrice(order.totalPrice)) руб.\nСтатус: \(statusTitle(order.typedStatus ?? .new))"
        if let comment = order.comment, !comment.isEmpty {
            text += "\nКомментарий: \(comment)"
        }
        if let window = order.pickupWindow ?? order.cook.pickupSchedule {
            text += "\nВремя выдачи: \(window)"
        }
        if let pickupTime = order.pickupTime {
            text += "\nЗаберут к: \(pickupTime)"
        }
        if let scheduledDate = order.scheduledDate {
            text += "\n📅 Предзаказ на \(scheduledDate)"
        }
        if let starsLine = formatStarsLine(order) {
            text += "\n\(starsLine)"
        }
        if order.balanceUsed > 0 {
            text += "\n💰 Оплачено баллами: \(order.balanceUsed)"
        }
        if let promoCode = order.promoCode {
            text += "\n🎟 Промокод: \(promoCode)"
        }
        if let voiceNote = order.voiceNote, !voiceNote.isEmpty {
            text += "\n🎤 Голосовой комментарий клиента"
        }
        if order.isDelivery == true {
            let deliveryAddress = order.shippingAddress ?? order.client.address ?? "не указан"
            text += "\nДоставка: \(deliveryAddress)"
            if let cookAddress = order.cook.address {
                text += "\nВаш адрес: \(cookAddress)"
            }
        } else {
            text += "\nСамовывоз. Ваш адрес: \(order.cook.address ?? "не указан")"
        }
        if let phone = order.client.phone, !phone.isEmpty {
            text += "\nТелефон клиента: \(phone)"
        }

        let statuses = nextStatuses(for: order.typedStatus ?? .new)
        var rows: [[TelegramInlineKeyboardButton]] = []
        if statuses.isEmpty {
            rows.append([
                TelegramInlineKeyboardButton(text: "Без действий", callbackData: "order:noop")
            ])
        } else {
            rows.append(statuses.map { status in
                TelegramInlineKeyboardButton(
                    text: statusTitle(status),
                    callbackData: "order:status:\(order.id?.uuidString ?? ""):\(statusTitle(status))"
                )
            })
        }
        if let status = order.typedStatus, isClientCancelable(status: status) {
            rows.append([
                TelegramInlineKeyboardButton(
                    text: "Отменить заказ",
                    callbackData: "order:cook_cancel:\(order.id?.uuidString ?? "")"
                )
            ])
        }
        if let status = order.typedStatus, status != .delivered, status != .cancelled {
            rows.append([
                TelegramInlineKeyboardButton(
                    text: "Время выдачи",
                    callbackData: "order:window:\(order.id?.uuidString ?? "")"
                )
            ])
        }
        if order.typedStatus == .onTheWay, order.isDelivery == true {
            rows.append([
                TelegramInlineKeyboardButton(
                    text: "📍 Отправить геолокацию курьера",
                    callbackData: "order:send_geo:\(order.id?.uuidString ?? "")"
                )
            ])
        }
        if let voiceNote = order.voiceNote, !voiceNote.isEmpty {
            rows.append([
                TelegramInlineKeyboardButton(
                    text: "🎧 Послушать голос клиента",
                    callbackData: "order:listen_voice:\(order.id?.uuidString ?? "")"
                )
            ])
        }
        rows.append([
            TelegramInlineKeyboardButton(
                text: "👤 Карточка клиента",
                callbackData: "order:client_card:\(order.id?.uuidString ?? "")"
            )
        ])

        let markup = TelegramInlineKeyboardMarkup(inlineKeyboard: rows)
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: cookChatID, text: text, replyMarkup: markup),
            logger: logger
        )
    }
}

// MARK: - Создание заказа и рассылка уведомлений
func createOrderAndNotify(
    dish: Dish,
    comment: String?,
    clientUser: User,
    chatID: Int64,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger,
    isDelivery: Bool = false,
    scheduledDate: String? = nil,
    quantity: Int = 1,
    promoCode: String? = nil,
    promoDiscount: Double? = nil,
    balanceUsed: Int = 0
) async throws {
    let cookID = dish.$cook.id
    guard let cook = try await User.find(cookID, on: req.db),
          cook.latitude != nil,
          cook.longitude != nil else {
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "Не найден профиль повара. Начните заново через /start",
                replyMarkup: nil
            ),
            logger: logger
        )
        return
    }

    guard cook.isAcceptingOrders != false else {
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "Повар сейчас не принимает заказы. Попробуйте позже.",
                replyMarkup: nil
            ),
            logger: logger
        )
        return
    }

    let totalPrice = dish.price * Double(quantity)

    if isToday(dish), let left = dish.portionsLeft, left < quantity {
        let waitlistCount = try await WaitlistEntry.query(on: req.db)
            .filter(\.$dish.$id == (dish.id ?? UUID()))
            .filter(\.$notified == false)
            .count()
        let waitlistButton = TelegramInlineKeyboardMarkup(inlineKeyboard: [[
            TelegramInlineKeyboardButton(
                text: "В список ожидания (\(waitlistCount))",
                callbackData: "order:waitlist:\(dish.id?.uuidString ?? "")"
            )
        ]])
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "Это блюдо раскупили 😔 (\(formatQuantity(quantity)) нужно, осталось \(left)). Добавить вас в список ожидания?",
                replyMarkup: waitlistButton
            ),
            logger: logger
        )
        return
    }

    guard let clientUserID = clientUser.id else { return }
    let discount = promoDiscount ?? 0
    let discountCapped = min(discount, totalPrice)
    let payable = totalPrice - discountCapped

    var usedBalance = 0
    let balance = clientUser.balance ?? 0
    if balanceUsed > 0, balance > 0 {
        usedBalance = min(balanceUsed, Int(payable.rounded(.down)))
        if usedBalance > 0 {
            _ = try await BotUserService.spendBalance(from: clientUserID, amount: usedBalance, on: req.db)
        }
    }
    let finalTotal = max(0, payable - Double(usedBalance))

    let order = Order(
        clientID: clientUserID,
        cookID: cookID,
        dishID: dish.id,
        totalPrice: finalTotal,
        comment: comment,
        quantity: quantity
    )
    order.scheduledDate = scheduledDate
    order.isDelivery = isDelivery
    if isDelivery, let address = clientUser.address {
        order.shippingAddress = address
    }
    order.promoCode = promoCode
    order.promoDiscount = discountCapped
    order.balanceUsed = usedBalance
    try await order.save(on: req.db)

    if let promoCode, let promo = try await PromoCode.query(on: req.db)
        .filter(\.$code == promoCode)
        .filter(\.$cook.$id == cookID)
        .first() {
        promo.usesCount += 1
        try await promo.save(on: req.db)
    }

    if scheduledDate == nil, isToday(dish), let left = dish.portionsLeft, left >= quantity {
        dish.portionsLeft = left - quantity
        try await dish.save(on: req.db)
    }

    // MARK: - Сообщение клиенту
    let deliveryLine = isDelivery ? "Доставка" : "Самовывоз"
    let dateLine = scheduledDate.map { "\nНа день: \($0)" } ?? ""
    let qtyLine = "\n\(formatQuantity(quantity))"
    // Показываем адрес в зависимости от способа получения
    let addressLine = isDelivery
        ? "\nАдрес доставки: \(clientUser.address ?? "не указан")"
        : "\nЗабрать: \(cook.address ?? "не указан")"
    let commentLine = comment.map { "\nКомментарий: \($0)" } ?? ""
    let windowLine = cook.pickupSchedule.map { "\nВремя выдачи: \($0)" } ?? ""
    var priceLine = "\nСумма: \(formatPrice(finalTotal)) руб."
    if discountCapped > 0 {
        priceLine += "\n🎟 Скидка: \(formatPrice(discountCapped)) руб."
    }
    if usedBalance > 0 {
        priceLine += "\n💰 Оплачено баллами: \(usedBalance)"
    }
    let clientText = "Заказ оформлен: \(dish.title)\(qtyLine)\(priceLine)\nСпособ: \(deliveryLine)\(dateLine)\(addressLine)\(commentLine)\(windowLine)"
    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: chatID, text: clientText, replyMarkup: nil),
        logger: logger
    )

    if scheduledDate == nil {
        try await sendPaymentInvoice(
            order: order,
            dish: dish,
            chatID: chatID,
            client: client,
            logger: logger
        )
    }

    // MARK: Уведомление повару
    let cookAddressLine = isDelivery ? "\nВаш адрес: \(cook.address ?? "не указан")" : ""
    let phoneLine = clientUser.phone.map { "\nТелефон: \($0)" } ?? ""
    let preorderLine = scheduledDate.map { "\n📅 Предзаказ на \($0)" } ?? ""
    var cookPriceLine = "Сумма: \(formatPrice(finalTotal)) руб."
    if discountCapped > 0 {
        cookPriceLine += "\n🎟 Скидка: \(formatPrice(discountCapped)) руб."
    }
    if usedBalance > 0 {
        cookPriceLine += "\n💰 Оплачено баллами: \(usedBalance)"
    }
    let cookText = "Новый заказ на блюдо: \(dish.title)\nКол-во: \(quantity)\nКлиент: \(clientUser.firstName)\n\(cookPriceLine)\nСпособ: \(deliveryLine)\(preorderLine)\(addressLine)\(cookAddressLine)\(phoneLine)\(commentLine)"
    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: cook.telegramID, text: cookText, replyMarkup: nil),
        logger: logger
    )
}
