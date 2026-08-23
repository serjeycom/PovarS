import Fluent
import Foundation
import Vapor

enum DishType: String, CaseIterable {
    case breakfast
    case lunch
    case dinner
    case dessert
    case drink

    var title: String {
        switch self {
        case .breakfast: return "Завтрак"
        case .lunch: return "Обед"
        case .dinner: return "Ужин"
        case .dessert: return "Десерт"
        case .drink: return "Напиток"
        }
    }

    static func from(_ raw: String?) -> DishType? {
        guard let raw else { return nil }
        return DishType(rawValue: raw)
    }
}

func dishTypeTitle(_ raw: String?) -> String? {
    DishType.from(raw)?.title
}

func generateReferralCode(length: Int = 8) -> String {
    let letters = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    return String((0..<length).compactMap { _ in letters.randomElement() })
}

func sendCartMenu(
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

    let items = try await CartItem.query(on: req.db)
        .filter(\.$client.$id == userID)
        .with(\.$dish)
        .sort(\.$createdAt)
        .all()

    guard !items.isEmpty else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "🛒 Корзина пуста. Добавьте блюда кнопкой «В корзину».", replyMarkup: nil),
            logger: logger
        )
        return
    }

    var text = "🛒 Ваша корзина:\n"
    var rows: [[TelegramInlineKeyboardButton]] = []
    var total: Double = 0

    for (index, item) in items.enumerated() {
        let dish = item.dish
        guard let dishID = dish.id, let itemID = item.id else { continue }
        let price = dish.price * Double(item.quantity)
        total += price
        text += "\n\(index + 1). \(dish.title) — \(formatPrice(dish.price))₽ × \(item.quantity) = \(formatPrice(price))₽"
        rows.append([
            TelegramInlineKeyboardButton(
                text: "➖",
                callbackData: "cart:dec:\(itemID.uuidString)"
            ),
            TelegramInlineKeyboardButton(
                text: "\(item.quantity)",
                callbackData: "cart:noop"
            ),
            TelegramInlineKeyboardButton(
                text: "➕",
                callbackData: "cart:inc:\(itemID.uuidString)"
            ),
            TelegramInlineKeyboardButton(
                text: "Убрать",
                callbackData: "cart:remove:\(itemID.uuidString)"
            )
        ])
    }

    text += "\n\nИтого: \(formatPrice(total))₽"
    rows.append([
        TelegramInlineKeyboardButton(
            text: "✅ Оформить заказ",
            callbackData: "cart:checkout"
        ),
        TelegramInlineKeyboardButton(
            text: "🗑 Очистить",
            callbackData: "cart:clear"
        )
    ])

    let markup = TelegramInlineKeyboardMarkup(inlineKeyboard: rows)
    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: chatID, text: text, replyMarkup: markup),
        logger: logger
    )
}
