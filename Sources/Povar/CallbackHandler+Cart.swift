import Fluent
import Foundation
import Vapor

// MARK: - Корзина (добавить / количество / удалить / очистить / оформить)
func handleCartAddCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    dishID: UUID,
    quantity: Int,
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
    guard let dish = try await Dish.find(dishID, on: req.db), dish.isActive else {
        try await answerToast("Блюдо не найдено", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    if let existing = try await CartItem.query(on: req.db)
        .filter(\.$client.$id == userID)
        .filter(\.$dish.$id == dishID)
        .first() {
        existing.quantity += max(quantity, 1)
        try await existing.save(on: req.db)
    } else {
        let item = CartItem(clientID: userID, dishID: dishID, quantity: max(quantity, 1))
        try await item.save(on: req.db)
    }

    try await answerToast("🛒 В корзине", callbackQueryID: callbackQueryID, client: client, logger: logger)
    let markup = TelegramInlineKeyboardMarkup(inlineKeyboard: [[
        TelegramInlineKeyboardButton(text: "🛒 Перейти в корзину", callbackData: "cart:show")
    ]])
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "🛒 «\(dish.title)» — \(formatQuantity(quantity)) добавлено в корзину. Откройте меню и нажмите «Корзина», чтобы оформить.",
            replyMarkup: markup
        ),
        logger: logger
    )
}

func handleCartChangeQuantityCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    itemID: UUID,
    delta: Int,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          let item = try await CartItem.find(itemID, on: req.db),
          item.$client.id == user.id else {
        return
    }
    item.quantity += delta
    if item.quantity <= 0 {
        try await item.delete(on: req.db)
    } else {
        try await item.save(on: req.db)
    }
    try await answerToast("Обновлено", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await sendCartMenu(
        telegramUserID: telegramUserID,
        chatID: chatID,
        req: req,
        client: client,
        logger: logger
    )
}

func handleCartRemoveCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    itemID: UUID,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          let item = try await CartItem.find(itemID, on: req.db),
          item.$client.id == user.id else {
        return
    }
    try await item.delete(on: req.db)
    try await answerToast("Убрано из корзины", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await sendCartMenu(
        telegramUserID: telegramUserID,
        chatID: chatID,
        req: req,
        client: client,
        logger: logger
    )
}

func handleCartClearCallback(
    telegramUserID: Int64,
    callbackQueryID: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          let userID = user.id else {
        return
    }
    let items = try await CartItem.query(on: req.db)
        .filter(\.$client.$id == userID)
        .all()
    for item in items {
        try await item.delete(on: req.db)
    }
    try await answerToast("Корзина очищена", callbackQueryID: callbackQueryID, client: client, logger: logger)
}

func handleCartCheckoutCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
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

    let items = try await CartItem.query(on: req.db)
        .filter(\.$client.$id == userID)
        .with(\.$dish)
        .all()

    guard !items.isEmpty else {
        try await answerToast("Корзина пуста", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    try await answerToast("Оформляем", callbackQueryID: callbackQueryID, client: client, logger: logger)

    let defaultAddress = user.address
    let addressLine = defaultAddress.map { "\nАдрес доставки: \($0)" } ?? ""
    let markup = TelegramInlineKeyboardMarkup(inlineKeyboard: [
        [
            TelegramInlineKeyboardButton(text: "📦 Самовывоз", callbackData: "cart:place:pickup")
        ],
        [
            TelegramInlineKeyboardButton(text: "🚚 Доставить", callbackData: "cart:place:deliver")
        ],
        [
            TelegramInlineKeyboardButton(text: "Отмена", callbackData: "cart:clear")
        ]
    ])
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Как хотите получить заказ?\(addressLine)",
            replyMarkup: markup
        ),
        logger: logger
    )
}

// MARK: - Оформление из корзины и оплата инвойсом
func handleCartPlaceCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    deliveryRaw: String,
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

    let isDelivery = deliveryRaw == "deliver"
    if isDelivery, (user.address ?? "").isEmpty {
        try await answerToast("Укажите адрес в меню", callbackQueryID: callbackQueryID, client: client, logger: logger)
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "Для доставки укажите адрес: меню → «Мой адрес».",
                replyMarkup: nil
            ),
            logger: logger
        )
        return
    }

    let items = try await CartItem.query(on: req.db)
        .filter(\.$client.$id == userID)
        .with(\.$dish)
        .all()

    guard !items.isEmpty else {
        try await answerToast("Корзина пуста", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    var groupByCook: [UUID: [CartItem]] = [:]
    for item in items {
        let cookID = item.dish.$cook.id
        groupByCook[cookID, default: []].append(item)
    }

    var failedDish: Dish?
    outer: for (_, group) in groupByCook {
        for item in group {
            let dish = item.dish
            if isToday(dish), let left = dish.portionsLeft, left < item.quantity {
                failedDish = dish
                break outer
            }
        }
    }
    if let failedDish {
        try await answerToast("Не хватает порций", callbackQueryID: callbackQueryID, client: client, logger: logger)
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "Не хватает порций блюда «\(failedDish.title)». Уменьшите количество в корзине.",
                replyMarkup: nil
            ),
            logger: logger
        )
        return
    }

    try await answerToast("Заказ оформлен", callbackQueryID: callbackQueryID, client: client, logger: logger)

    for (cookID, group) in groupByCook {
        guard let cook = try await User.find(cookID, on: req.db),
              let cookIDValue = cook.id else { continue }
        let totalPrice = group.reduce(0) { $0 + ($1.dish.price * Double($1.quantity)) }
        let order = Order(
            clientID: userID,
            cookID: cookIDValue,
            dishID: group.first?.dish.id,
            totalPrice: totalPrice,
            comment: nil,
            quantity: 1
        )
        order.isDelivery = isDelivery
        if isDelivery {
            order.shippingAddress = user.address
        }
        try await order.save(on: req.db)
        guard let orderID = order.id else { continue }

        for item in group {
            let dish = item.dish
            let orderItem = OrderItem(
                orderID: orderID,
                dishID: dish.id ?? UUID(),
                dishTitle: dish.title,
                price: dish.price,
                quantity: item.quantity
            )
            try await orderItem.save(on: req.db)
            if isToday(dish), let left = dish.portionsLeft, left >= item.quantity {
                dish.portionsLeft = left - item.quantity
                try await dish.save(on: req.db)
            }
        }

        let dishList = group.map { "• \($0.dish.title) × \($0.quantity)" }.joined(separator: "\n")
        let deliveryLine = isDelivery ? "Доставка" : "Самовывоз"
        let addressLine = isDelivery ? "\nАдрес: \(user.address ?? "не указан")" : ""
        let phoneLine = user.phone.map { "\nТелефон: \($0)" } ?? ""
        let clientText = "✅ Заказ оформлен у \(cook.firstName)!\n\(dishList)\nСумма: \(formatPrice(totalPrice))₽\nСпособ: \(deliveryLine)\(addressLine)"
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: clientText, replyMarkup: nil),
            logger: logger
        )

        try await sendCartInvoice(
            order: order,
            cookName: cook.firstName,
            totalPrice: totalPrice,
            chatID: chatID,
            client: client,
            logger: logger
        )

        let cookText = "🛒 Новый заказ!\n\(dishList)\nКлиент: \(user.firstName)\nСумма: \(formatPrice(totalPrice))₽\nСпособ: \(deliveryLine)\(addressLine)\(phoneLine)"
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: cook.telegramID, text: cookText, replyMarkup: nil),
            logger: logger
        )
    }

    for item in items {
        try await item.delete(on: req.db)
    }

    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "🛒 Корзина очищена. Все заказы оформлены!",
            replyMarkup: nil
        ),
        logger: logger
    )
}

// MARK: - Инвойс оплаты корзины (Stars)
func sendCartInvoice(
    order: Order,
    cookName: String,
    totalPrice: Double,
    chatID: Int64,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    let stars = priceToStars(totalPrice)
    let title = "Заказ у \(cookName)"
    let description = "Оплата заказа звёздами. При получении можно заплатить наличными."
    try await client.sendInvoice(
        TelegramSendInvoiceRequest(
            chatID: chatID,
            title: title,
            description: description,
            payload: order.id?.uuidString ?? "",
            providerToken: "",
            currency: "XTR",
            prices: [TelegramLabeledPrice(label: cookName, amount: stars)]
        ),
        logger: logger
    )
}

// MARK: - Приём заказа поваром
func handleOrderReceiveCallback(
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
    guard order.typedStatus == .ready || order.typedStatus == .delivered else {
        try await answerToast("Заказ ещё не готов", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    let wasDelivered = order.typedStatus == .delivered
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

    try await answerToast("✅ Получено", callbackQueryID: callbackQueryID, client: client, logger: logger)

    let title = order.dish?.title ?? "Блюдо"
    if !wasDelivered {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Спасибо, приятного аппетита! Блюдо: \(title)", replyMarkup: nil),
            logger: logger
        )
        if let cookTelegramID = try await findTelegramIDForUser(order.$cook.id, on: req.db) {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: cookTelegramID, text: "✅ Клиент подтвердил получение заказа по «\(title)»", replyMarkup: nil),
                logger: logger
            )
        }
    }

    if order.rating == nil {
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
}
