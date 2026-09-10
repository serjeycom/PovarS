import Fluent
import Vapor

// MARK: - Статусы оплаты
enum PaymentStatus: String {
    case unpaid
    case paid
}

// MARK: - Конвертация цены в Stars
func priceToStars(_ price: Double) -> Int {
    Int(max(1, (price / 10).rounded(.up)))
}

// MARK: - Отправка инвойса оплаты (Stars)
func sendPaymentInvoice(
    order: Order,
    title: String,
    chatID: Int64,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    let stars = priceToStars(order.totalPrice)
    let description = "Оплата заказа звёздами. При получении можно заплатить наличными."
    try await client.sendInvoice(
        TelegramSendInvoiceRequest(
            chatID: chatID,
            title: title,
            description: description,
            payload: order.id?.uuidString ?? "",
            providerToken: "",
            currency: "XTR",
            prices: [TelegramLabeledPrice(label: title, amount: stars)]
        ),
        logger: logger
    )
}

/// Инвойс для заказа из Mini App.
func sendOrderInvoice(
    order: Order,
    title: String,
    chatID: Int64,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    try await sendPaymentInvoice(
        order: order,
        title: title,
        chatID: chatID,
        client: client,
        logger: logger
    )
}

// MARK: - Подтверждение pre-checkout
func handlePreCheckoutQuery(
    query: TelegramPreCheckoutQuery,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let orderID = UUID(uuidString: query.invoicePayload),
          let order = try await Order.find(orderID, on: req.db) else {
        try await client.answerPreCheckoutQuery(
            TelegramAnswerPreCheckoutQueryRequest(
                preCheckoutQueryID: query.id,
                ok: false,
                errorMessage: "Заказ не найден"
            ),
            logger: logger
        )
        return
    }
    guard order.paymentStatus != PaymentStatus.paid.rawValue,
          order.typedStatus != .cancelled else {
        try await client.answerPreCheckoutQuery(
            TelegramAnswerPreCheckoutQueryRequest(
                preCheckoutQueryID: query.id,
                ok: false,
                errorMessage: "Заказ уже обработан"
            ),
            logger: logger
        )
        return
    }

    try await client.answerPreCheckoutQuery(
        TelegramAnswerPreCheckoutQueryRequest(preCheckoutQueryID: query.id, ok: true, errorMessage: nil),
        logger: logger
    )
}

// MARK: - Обработка успешной оплаты
func handleSuccessfulPayment(
    payment: TelegramSuccessfulPayment,
    chatID: Int64,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let orderID = UUID(uuidString: payment.invoicePayload),
          let order = try await Order.find(orderID, on: req.db) else {
        return
    }

    order.paymentStatus = PaymentStatus.paid.rawValue
    order.starsAmount = payment.totalAmount
    order.paidAt = Date()
    try await order.save(on: req.db)

    let starsLine = "⭐ \(payment.totalAmount)"
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Оплата получена (\(starsLine)). Спасибо!",
            replyMarkup: nil
        ),
        logger: logger
    )

    guard let cookTelegramID = try await findTelegramIDForUser(order.$cook.id, on: req.db) else {
        return
    }
    let title = (try? await order.$dish.get(on: req.db))?.title ?? "Блюдо"
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: cookTelegramID,
            text: "💳 Клиент оплатил заказ «\(title)» звёздами (\(starsLine)).",
            replyMarkup: nil
        ),
        logger: logger
    )
}

// MARK: - Форматирование строки оплаты Stars для карточки заказа
func formatStarsLine(_ order: Order) -> String? {
    guard let amount = order.starsAmount else { return nil }
    return "⭐ Оплачено: \(amount)"
}
