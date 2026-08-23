import Fluent
import Foundation
import Vapor

// MARK: - Поиск (фильтры, сброс)
func handleSearchTypeCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    typeRaw: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }
    let value: String?
    if typeRaw == "any" {
        value = nil
    } else {
        value = typeRaw
    }
    user.searchDishType = value
    try await user.save(on: req.db)
    let label = value.flatMap { dishTypeTitle($0) } ?? "Любая"
    try await answerToast("Тип: \(label)", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await sendSearchFiltersMenu(
        telegramUserID: telegramUserID,
        chatID: chatID,
        req: req,
        client: client,
        logger: logger
    )
}

func handleSearchClearCallback(
    telegramUserID: Int64,
    callbackQueryID: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }
    user.searchKeyword = nil
    user.searchMaxPrice = nil
    user.searchDishType = nil
    try await user.save(on: req.db)
    try await answerToast("Фильтры сброшены", callbackQueryID: callbackQueryID, client: client, logger: logger)
}

// MARK: - Меню фильтров поиска
func sendSearchFiltersMenu(
    telegramUserID: Int64,
    chatID: Int64,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }
    let keywordLine = user.searchKeyword.map { "Слово: \($0)" } ?? "Слово: любое"
    let priceLine = user.searchMaxPrice.map { "Цена: до \(Int($0))₽" } ?? "Цена: любая"
    let typeLine = dishTypeTitle(user.searchDishType).map { "Тип: \($0)" } ?? "Тип: любой"
    let text = """
    🔍 Фильтры поиска:
    • \(keywordLine)
    • \(priceLine)
    • \(typeLine)
    """

    let typeButtons = DishType.allCases.map { type in
        TelegramInlineKeyboardButton(
            text: type.title,
            callbackData: "search:type:\(type.rawValue)"
        )
    }

    let markup = TelegramInlineKeyboardMarkup(inlineKeyboard: [
        [
            TelegramInlineKeyboardButton(text: "🔤 По слову", callbackData: "search:keyword")
        ],
        [
            TelegramInlineKeyboardButton(text: "💰 До цены", callbackData: "search:price")
        ],
        typeButtons,
        [
            TelegramInlineKeyboardButton(text: "Любой тип", callbackData: "search:type:any")
        ],
        [
            TelegramInlineKeyboardButton(text: "✖️ Сбросить", callbackData: "search:clear"),
            TelegramInlineKeyboardButton(text: "✅ Показать", callbackData: "search:apply")
        ]
    ])
    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: chatID, text: text, replyMarkup: markup),
        logger: logger
    )
}
