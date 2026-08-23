import Fluent
import Vapor

func sendPromoCodesMenu(
    cookID: UUID,
    chatID: Int64,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    let codes = try await PromoCode.query(on: req.db)
        .filter(\.$cook.$id == cookID)
        .sort(\.$createdAt, .descending)
        .all()

    var text = "🎟 Ваши промокоды:\n"
    if codes.isEmpty {
        text += "Пока нет. Создайте первый!"
    } else {
        for code in codes {
            let status = code.isActive ? "✅ активен" : "⛔ отключен"
            text += "\n\(code.code) — скидка \(code.discountPercent)% — \(status) — использован: \(code.usesCount)"
        }
    }

    var rows: [[TelegramInlineKeyboardButton]] = []
    for code in codes {
        let toggleLabel = code.isActive ? "⛔ Отключить" : "✅ Включить"
        rows.append([
            TelegramInlineKeyboardButton(
                text: "\(code.code) \(code.discountPercent)%",
                callbackData: "promo:toggle:\(code.id?.uuidString ?? "")"
            ),
            TelegramInlineKeyboardButton(
                text: toggleLabel,
                callbackData: "promo:toggle:\(code.id?.uuidString ?? "")"
            )
        ])
    }
    rows.append([
        TelegramInlineKeyboardButton(text: "➕ Создать промокод", callbackData: "promo:create")
    ])

    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: text,
            replyMarkup: TelegramInlineKeyboardMarkup(inlineKeyboard: rows)
        ),
        logger: logger
    )
}

func createPromoCode(
    cookID: UUID,
    code: String,
    discountPercent: Int,
    on db: Database
) async throws {
    let promo = PromoCode(cookID: cookID, code: code.uppercased(), discountPercent: discountPercent)
    try await promo.save(on: db)
}
