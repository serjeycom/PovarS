import Fluent
import Foundation
import Vapor

// MARK: - Бот работает только как канал уведомлений.
// Вся интерактивность (каталог, блюда, заказы, настройки) — в Mini App (/app).
// Здесь обрабатываем только оплату звёздами и направляем пользователей в каталог.

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

    // Оплата заказа звёздами — единственный транзакционный сценарий в боте.
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

    guard let text = message.text else { return }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

    // Реферальная ссылка /start CODE: сохраняем код до выбора роли в Mini App.
    if trimmed.hasPrefix("/start "),
       let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) {
        let code = String(trimmed.dropFirst("/start ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !code.isEmpty, !code.hasPrefix("chat_"), user.referredBy == nil, user.pendingReferral == nil {
            user.pendingReferral = code
            try await user.save(on: req.db)
        }
    }

    // Отвечаем только на /start и /menu — одной кнопкой входа в каталог.
    guard trimmed == "/start" || trimmed.hasPrefix("/start ") || trimmed == "/menu" else { return }

    let markup = TelegramInlineKeyboardMarkup(inlineKeyboard: [[
        TelegramInlineKeyboardButton(text: "📱 Открыть каталог", webApp: TelegramWebAppInfo(url: miniAppURL))
    ]])
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Привет! Я бот сервиса «Повар» 🍲\n\nЗдесь приходят уведомления о заказах и новых блюдах. Заказывайте и управляйте блюдами в каталоге:",
            replyMarkup: markup
        ),
        logger: logger
    )
}

// MARK: - Устаревшие inline-кнопки: отвечаем и направляем в каталог.
func handleCallbackQuery(
    _ callbackQuery: TelegramCallbackQuery,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    let chatID = callbackQuery.message?.chat.id ?? callbackQuery.from.id
    try? await client.answerCallbackQuery(
        TelegramAnswerCallbackQueryRequest(callbackQueryID: callbackQuery.id, text: nil),
        logger: logger
    )
    try? await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Эта функция переехала в каталог. Откройте Mini App, чтобы продолжить.",
            replyMarkup: nil
        ),
        logger: logger
    )
}
