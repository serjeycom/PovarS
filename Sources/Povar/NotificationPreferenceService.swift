import Fluent
import Foundation
import Vapor

enum NotificationPreferenceService {
    /// Whether a proactive (non-transactional) notification may be sent to this user right now.
    /// Order-status updates and other direct replies to a user's own action are never gated here —
    /// only "someone else did something" pushes (new dish from a followed cook, waitlist restock).
    static func shouldSendProactiveNotification(to user: User) -> Bool {
        guard user.notificationsEnabled != false else { return false }
        guard let start = user.quietHoursStart, let end = user.quietHoursEnd else { return true }
        let hour = Calendar.current.component(.hour, from: Date())
        if start == end { return true }
        if start < end {
            return !(hour >= start && hour < end)
        } else {
            return !(hour >= start || hour < end)
        }
    }

    static let quietHoursPresets: [(label: String, start: Int, end: Int)] = [
        ("22:00 – 08:00", 22, 8),
        ("23:00 – 07:00", 23, 7),
        ("00:00 – 09:00", 0, 9)
    ]
}

func sendNotificationSettings(
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

    let enabled = user.notificationsEnabled != false
    var text = "🔔 Уведомления: \(enabled ? "включены" : "выключены")"
    if let start = user.quietHoursStart, let end = user.quietHoursEnd {
        text += "\n🌙 Тихие часы: \(String(format: "%02d:00", start)) – \(String(format: "%02d:00", end))"
    } else {
        text += "\n🌙 Тихие часы: не заданы"
    }
    text += "\n\nВ тихие часы бот не присылает уведомления о новых блюдах у поваров, за которыми вы следите, и о появлении блюда из листа ожидания. Статусы ваших заказов приходят всегда."

    var rows: [[TelegramInlineKeyboardButton]] = []
    rows.append([
        TelegramInlineKeyboardButton(
            text: enabled ? "Выключить уведомления" : "Включить уведомления",
            callbackData: "notif:toggle"
        )
    ])
    for preset in NotificationPreferenceService.quietHoursPresets {
        rows.append([
            TelegramInlineKeyboardButton(text: preset.label, callbackData: "notif:quiet:\(preset.start):\(preset.end)")
        ])
    }
    if user.quietHoursStart != nil {
        rows.append([TelegramInlineKeyboardButton(text: "Сбросить тихие часы", callbackData: "notif:quiet_off")])
    }

    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: text,
            replyMarkup: TelegramInlineKeyboardMarkup(inlineKeyboard: rows)
        ),
        logger: logger
    )
}

func handleNotificationToggleCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }
    let enabled = user.notificationsEnabled != false
    user.notificationsEnabled = !enabled
    try await user.save(on: req.db)

    try await client.answerCallbackQuery(
        TelegramAnswerCallbackQueryRequest(
            callbackQueryID: callbackQueryID,
            text: enabled ? "Уведомления выключены" : "Уведомления включены"
        ),
        logger: logger
    )
    try await sendNotificationSettings(
        telegramUserID: telegramUserID,
        chatID: chatID,
        req: req,
        client: client,
        logger: logger
    )
}

func handleNotificationQuietHoursCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    startString: String,
    endString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          let start = Int(startString), (0...23).contains(start),
          let end = Int(endString), (0...23).contains(end) else {
        return
    }
    user.quietHoursStart = start
    user.quietHoursEnd = end
    try await user.save(on: req.db)

    try await client.answerCallbackQuery(
        TelegramAnswerCallbackQueryRequest(callbackQueryID: callbackQueryID, text: "Тихие часы сохранены"),
        logger: logger
    )
    try await sendNotificationSettings(
        telegramUserID: telegramUserID,
        chatID: chatID,
        req: req,
        client: client,
        logger: logger
    )
}

func handleNotificationQuietHoursOffCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }
    user.quietHoursStart = nil
    user.quietHoursEnd = nil
    try await user.save(on: req.db)

    try await client.answerCallbackQuery(
        TelegramAnswerCallbackQueryRequest(callbackQueryID: callbackQueryID, text: "Тихие часы сброшены"),
        logger: logger
    )
    try await sendNotificationSettings(
        telegramUserID: telegramUserID,
        chatID: chatID,
        req: req,
        client: client,
        logger: logger
    )
}
