import Fluent
import Foundation
import Vapor

private let allOrderStatuses: [OrderStatus] = [.new, .accepted, .cooking, .ready, .onTheWay, .delivered, .cancelled]

private func answerToast(
    _ text: String,
    callbackQueryID: String,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    try await client.answerCallbackQuery(
        TelegramAnswerCallbackQueryRequest(callbackQueryID: callbackQueryID, text: text),
        logger: logger
    )
}

func handleCallbackQuery(
    _ callbackQuery: TelegramCallbackQuery,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    let telegramUserID = callbackQuery.from.id
    let chatID = callbackQuery.message?.chat.id ?? telegramUserID
    guard let data = callbackQuery.data else { return }
    // Callback data — закодированное действие вида "action:param1:param2".
    let parts = data.split(separator: ":").map(String.init)
    guard let action = parts.first else { return }

    switch action {
    // MARK: - Роль пользователя (клиент / повар)
    case "role":
        guard parts.count >= 2, let role = UserRole(rawValue: parts[1]) else {
            try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
            return
        }
        do {
            _ = try await BotUserService.setRole(telegramUserID: telegramUserID, role: role, on: req.db)
            try await ConversationService.clear(for: telegramUserID, on: req.db)
        } catch {
            try await answerToast("Ошибка сохранения роли", callbackQueryID: callbackQuery.id, client: client, logger: logger)
            return
        }
        try await answerToast("Роль сохранена: \(role.title)", callbackQueryID: callbackQuery.id, client: client, logger: logger)

        if let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
           let userID = user.id {
            if user.referralCode == nil {
                user.referralCode = generateReferralCode()
                try await user.save(on: req.db)
            }
            if let pending = user.pendingReferral,
               let referrer = try await User.query(on: req.db)
                   .filter(\.$referralCode == pending)
                   .first(),
               referrer.id != userID,
               user.referredBy == nil {
                user.referredBy = referrer.id
                user.pendingReferral = nil
                try await user.save(on: req.db)

                try await BotUserService.applyBonus(
                    to: userID,
                    amount: 100,
                    reason: "Реферальный бонус",
                    on: req.db
                )
                if let referrerID = referrer.id {
                    try await BotUserService.applyBonus(
                        to: referrerID,
                        amount: 100,
                        reason: "Пригласили друга",
                        on: req.db
                    )
                }
                let referrerName = referrer.firstName
                try await client.sendMessage(
                    TelegramSendMessageRequest(
                        chatID: chatID,
                        text: "🎉 Вы активировали реферальный код \(pending). Вам начислено 100 баллов! Вам обоим +100 баллов.",
                        replyMarkup: nil
                    ),
                    logger: logger
                )
                if let referrerTelegramID = try await findTelegramIDForUser(referrer.id!, on: req.db) {
                    try await client.sendMessage(
                        TelegramSendMessageRequest(
                            chatID: referrerTelegramID,
                            text: "🎉 \(user.firstName) зарегистрировался по вашему коду. Вам начислено 100 баллов!",
                            replyMarkup: nil
                        ),
                        logger: logger
                    )
                }
            } else if let pending = user.pendingReferral, user.referredBy == nil {
                user.pendingReferral = nil
                try await user.save(on: req.db)
            }
        }
        let greeting = role == .client
            ? "Отлично, вы зарегистрированы как клиент."
            : "Отлично, вы зарегистрированы как повар."
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: greeting, replyMarkup: nil),
            logger: logger
        )
        try await sendMenu(
            telegramUserID: telegramUserID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )

    case "menu":
        guard parts.count >= 2 else {
            try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
            return
        }
        switch parts[1] {
        case "add_dish":
            try await answerToast("Начинаем", callbackQueryID: callbackQuery.id, client: client, logger: logger)
            try await startAddDishFlow(
                telegramUserID: telegramUserID,
                chatID: chatID,
                req: req,
                client: client,
                logger: logger
            )
        case "find_nearby":
            try await answerToast("Показываю блюда", callbackQueryID: callbackQuery.id, client: client, logger: logger)
            try await sendDishesForClient(
                telegramUserID: telegramUserID,
                chatID: chatID,
                req: req,
                client: client,
                logger: logger
            )
        case "my_orders":
            try await answerToast("Показываю ваши заказы", callbackQueryID: callbackQuery.id, client: client, logger: logger)
            try await sendClientOrders(
                telegramUserID: telegramUserID,
                chatID: chatID,
                req: req,
                client: client,
                logger: logger
            )
        case "my_dishes":
            try await answerToast("Показываю блюда", callbackQueryID: callbackQuery.id, client: client, logger: logger)
            try await sendCookDishes(
                telegramUserID: telegramUserID,
                chatID: chatID,
                req: req,
                client: client,
                logger: logger
            )
        case "back":
            try await answerToast("Меню", callbackQueryID: callbackQuery.id, client: client, logger: logger)
            try await sendMenu(
                telegramUserID: telegramUserID,
                chatID: chatID,
                req: req,
                client: client,
                logger: logger
            )
        default:
            try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
        }

    // MARK: - Блюдо (просмотр, добавление в корзину, заказ)
    case "dish":
        guard parts.count >= 3 else {
            try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
            return
        }
        switch parts[1] {
        case "toggle":
            try await handleDishToggleCallback(
                telegramUserID: telegramUserID,
                callbackQueryID: callbackQuery.id,
                dishIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "delete":
            try await handleDishDeleteCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                dishIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "delete_confirm":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleDishDeleteConfirmCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                dishIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "delete_cancel":
            try await answerToast("Отменено", callbackQueryID: callbackQuery.id, client: client, logger: logger)
        case "edit":
            try await handleDishEditCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                dishIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "photo":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleDishPhotoCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                dishIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "fav":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleFavoriteToggleCallback(
                telegramUserID: telegramUserID,
                callbackQueryID: callbackQuery.id,
                dishIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "today":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleDishTodayCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                dishIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "untoday":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleDishUntodayCallback(
                telegramUserID: telegramUserID,
                callbackQueryID: callbackQuery.id,
                dishIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "type":
            guard parts.count == 4 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleDishTypeCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                dishIDString: parts[2],
                typeRaw: parts[3],
                req: req,
                client: client,
                logger: logger
            )
        default:
            try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
        }

    // MARK: - Заказ (статусы, подтверждение, отмена, оплата, отзыв, чат)
    case "order":
        guard parts.count >= 2 else {
            try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
            return
        }
        switch parts[1] {
        case "create":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleCreateOrderPromptCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                dishIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "repeat":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleCreateOrderPromptCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                dishIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "comment":
            guard parts.count == 4 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleOrderCommentCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                dishIDString: parts[2],
                quantity: Int(parts[3]) ?? 1,
                req: req,
                client: client,
                logger: logger
            )
        case "preorder":
            guard parts.count == 4 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleOrderPreorderCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                dishIDString: parts[2],
                quantity: Int(parts[3]) ?? 1,
                req: req,
                client: client,
                logger: logger
            )
        case "preorder_confirm":
            guard parts.count == 5 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleOrderPreorderConfirmCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                dishIDString: parts[2],
                quantity: Int(parts[3]) ?? 1,
                dateString: parts[4],
                req: req,
                client: client,
                logger: logger
            )
        case "pay_balance":
            guard parts.count == 4 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleOrderPayBalanceCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                dishIDString: parts[2],
                quantity: Int(parts[3]) ?? 1,
                req: req,
                client: client,
                logger: logger
            )
        case "deliver":
            guard parts.count == 4 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleOrderDeliverCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                dishIDString: parts[2],
                quantity: Int(parts[3]) ?? 1,
                req: req,
                client: client,
                logger: logger
            )
        case "confirm":
            guard parts.count == 4 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleCreateOrderCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                dishIDString: parts[2],
                quantityString: parts[3],
                req: req,
                client: client,
                logger: logger
            )
        case "create_cancel":
            try await answerToast("Отменено", callbackQueryID: callbackQuery.id, client: client, logger: logger)
        case "qty_done":
            guard parts.count == 4,
                  let dishID = UUID(uuidString: parts[2]),
                  let qty = Int(parts[3]), (1...20).contains(qty) else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await answerToast("\(qty) порций", callbackQueryID: callbackQuery.id, client: client, logger: logger)
            try await sendOrderConfirmDialog(
                telegramUserID: telegramUserID,
                chatID: chatID,
                dishID: dishID,
                quantity: qty,
                req: req,
                client: client,
                logger: logger
            )
        case "qty_custom":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await ConversationService.startOrderQuantity(
                for: telegramUserID,
                dishID: UUID(uuidString: parts[2]) ?? UUID(),
                on: req.db
            )
            try await client.sendMessage(
                TelegramSendMessageRequest(
                    chatID: chatID,
                    text: "Введите количество порций числом (например: 7):",
                    replyMarkup: nil
                ),
                logger: logger
            )
        case "status":
            try await handleOrderStatusCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                data: data,
                req: req,
                client: client,
                logger: logger
            )
        case "client_cancel":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleClientCancelOrderPromptCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                orderIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "client_cancel_confirm":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleClientCancelOrderConfirmCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                orderIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "cook_cancel":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleCookCancelOrderPromptCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                orderIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "cook_cancel_confirm":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleCookCancelOrderConfirmCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                orderIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "cancel_noop":
            try await answerToast("Отменено", callbackQueryID: callbackQuery.id, client: client, logger: logger)
        case "window":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleOrderWindowCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                orderIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "pickup":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleOrderPickupCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                orderIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "time":
            guard parts.count == 4 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleOrderTimeCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                data: data,
                req: req,
                client: client,
                logger: logger
            )
        case "reschedule":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleOrderRescheduleCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                orderIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "reschedule_date":
            guard parts.count == 4 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleOrderRescheduleDateCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                orderIDString: parts[2],
                dateString: parts[3],
                req: req,
                client: client,
                logger: logger
            )
        case "change_address":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleOrderChangeAddressCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                orderIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "chat":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleOrderChatCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                orderIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "pick_address":
            guard parts.count == 4 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleOrderPickAddressCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                orderIDString: parts[2],
                addressIDString: parts[3],
                req: req,
                client: client,
                logger: logger
            )
        case "add_address":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleOrderAddAddressCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                orderIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "rate":
            try await handleRateOrderCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                data: data,
                req: req,
                client: client,
                logger: logger
            )
        case "noop":
            return
        case "reply":
            guard parts.count == 4 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleOrderReplyCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                orderIDString: parts[2],
                fromTelegramID: Int64(parts[3]) ?? 0,
                req: req,
                client: client,
                logger: logger
            )
        case "reply_done":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleOrderReplyDoneCallback(
                telegramUserID: telegramUserID,
                callbackQueryID: callbackQuery.id,
                orderIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "waitlist":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleOrderWaitlistCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                dishIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "receive":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleOrderReceiveCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                orderIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "voice":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleOrderVoiceCommentCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                orderIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "track":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleOrderTrackCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                orderIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "report":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleOrderReportCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                orderIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "send_geo":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleOrderSendGeoCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                orderIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "listen_voice":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleOrderListenVoiceCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                orderIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "client_card":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleOrderClientCardCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                orderIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "cook_card":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleOrderCookCardCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                orderIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        default:
            try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
        }

    // MARK: - Корзина
    case "cart":
        guard parts.count >= 2 else {
            try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
            return
        }
        switch parts[1] {
        case "noop":
            return
        case "show":
            try await sendCartMenu(
                telegramUserID: telegramUserID,
                chatID: chatID,
                req: req,
                client: client,
                logger: logger
            )
        case "add":
            guard parts.count == 4, let dishID = UUID(uuidString: parts[2]), let qty = Int(parts[3]) else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleCartAddCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                dishID: dishID,
                quantity: qty,
                req: req,
                client: client,
                logger: logger
            )
        case "inc":
            guard parts.count == 3, let itemID = UUID(uuidString: parts[2]) else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleCartChangeQuantityCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                itemID: itemID,
                delta: 1,
                req: req,
                client: client,
                logger: logger
            )
        case "dec":
            guard parts.count == 3, let itemID = UUID(uuidString: parts[2]) else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleCartChangeQuantityCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                itemID: itemID,
                delta: -1,
                req: req,
                client: client,
                logger: logger
            )
        case "remove":
            guard parts.count == 3, let itemID = UUID(uuidString: parts[2]) else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleCartRemoveCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                itemID: itemID,
                req: req,
                client: client,
                logger: logger
            )
        case "clear":
            let markup = TelegramInlineKeyboardMarkup(inlineKeyboard: [
                [
                    TelegramInlineKeyboardButton(text: "🗑 Да, очистить", callbackData: "cart:clear_confirm"),
                    TelegramInlineKeyboardButton(text: "❌ Отмена", callbackData: "cart:clear_cancel")
                ]
            ])
            try await answerToast("Подтвердите", callbackQueryID: callbackQuery.id, client: client, logger: logger)
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: "Очистить корзину? Все позиции будут удалены.", replyMarkup: markup),
                logger: logger
            )
        case "clear_confirm":
            try await handleCartClearCallback(
                telegramUserID: telegramUserID,
                callbackQueryID: callbackQuery.id,
                req: req,
                client: client,
                logger: logger
            )
        case "clear_cancel":
            try await answerToast("Отменено", callbackQueryID: callbackQuery.id, client: client, logger: logger)
        case "checkout":
            try await handleCartCheckoutCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                req: req,
                client: client,
                logger: logger
            )
        case "place":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleCartPlaceCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                deliveryRaw: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        default:
            try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
        }

    // MARK: - Поиск блюд
    case "search":
        guard parts.count >= 2 else {
            try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
            return
        }
        switch parts[1] {
        case "keyword":
            try await ConversationService.startSearchKeyword(for: telegramUserID, on: req.db)
            try await answerToast("Поиск по слову", callbackQueryID: callbackQuery.id, client: client, logger: logger)
            try await client.sendMessage(
                TelegramSendMessageRequest(
                    chatID: chatID,
                    text: "Введите ключевое слово для поиска (например: борщ). Отправьте '-' чтобы сбросить.",
                    replyMarkup: nil
                ),
                logger: logger
            )
        case "price":
            try await ConversationService.startSearchMaxPrice(for: telegramUserID, on: req.db)
            try await answerToast("Фильтр по цене", callbackQueryID: callbackQuery.id, client: client, logger: logger)
            try await client.sendMessage(
                TelegramSendMessageRequest(
                    chatID: chatID,
                    text: "Введите максимальную цену в рублях (например: 500). Отправьте '-' чтобы сбросить.",
                    replyMarkup: nil
                ),
                logger: logger
            )
        case "type":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleSearchTypeCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                typeRaw: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "clear":
            try await handleSearchClearCallback(
                telegramUserID: telegramUserID,
                callbackQueryID: callbackQuery.id,
                req: req,
                client: client,
                logger: logger
            )
        case "apply":
            try await answerToast("Показываю", callbackQueryID: callbackQuery.id, client: client, logger: logger)
            try await sendDishesForClient(
                telegramUserID: telegramUserID,
                chatID: chatID,
                req: req,
                client: client,
                logger: logger
            )
        default:
            try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
        }

    // MARK: - Повар (подписки, меню, отзывы, карта)
    case "cook":
        guard parts.count >= 2 else {
            try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
            return
        }
        switch parts[1] {
        case "sub":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleCookSubscribeCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                cookIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "unsub":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleCookUnsubscribeCallback(
                telegramUserID: telegramUserID,
                callbackQueryID: callbackQuery.id,
                cookIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
// MARK: - Главное меню
    case "menu":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleCookMenuCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                cookIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "review_photos":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleReviewPhotosCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                cookIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "map":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleCookMapCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                cookIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        case "reviews":
            guard parts.count == 3 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleCookReviewsCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                cookIDString: parts[2],
                req: req,
                client: client,
                logger: logger
            )
        default:
            try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
        }

    // MARK: - Адреса
    case "address":
        guard parts.count >= 2 else {
            try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
            return
        }
        switch parts[1] {
        case "delete":
            guard parts.count == 3,
                  let addressID = UUID(uuidString: parts[2]),
                  let address = try await Address.find(addressID, on: req.db) else {
                try await answerToast("Адрес не найден", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            let markup = TelegramInlineKeyboardMarkup(inlineKeyboard: [
                [
                    TelegramInlineKeyboardButton(text: "🗑 Да, удалить", callbackData: "address:delete_confirm:\(parts[2])"),
                    TelegramInlineKeyboardButton(text: "❌ Отмена", callbackData: "address:delete_cancel")
                ]
            ])
            try await answerToast("Подтвердите удаление", callbackQueryID: callbackQuery.id, client: client, logger: logger)
            try await client.sendMessage(
                TelegramSendMessageRequest(
                    chatID: chatID,
                    text: "Удалить адрес «\(address.name)»? Это действие необратимо.",
                    replyMarkup: markup
                ),
                logger: logger
            )
        case "delete_confirm":
            guard parts.count == 3,
                  let addressID = UUID(uuidString: parts[2]),
                  let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
                  let address = try await Address.find(addressID, on: req.db),
                  address.$user.id == user.id else {
                try await answerToast("Адрес не найден", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await address.delete(on: req.db)
            try await answerToast("Адрес удалён", callbackQueryID: callbackQuery.id, client: client, logger: logger)
        case "delete_cancel":
            try await answerToast("Отменено", callbackQueryID: callbackQuery.id, client: client, logger: logger)
        case "default":
            guard parts.count == 3,
                  let addressID = UUID(uuidString: parts[2]),
                  let address = try await Address.find(addressID, on: req.db) else {
                try await answerToast("Адрес не найден", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            let userID = address.$user.id
            let all = try await Address.query(on: req.db)
                .filter(\.$user.$id == userID)
                .all()
            for item in all {
                item.isDefault = false
                try? await item.save(on: req.db)
            }
            address.isDefault = true
            try await address.save(on: req.db)
            try await answerToast("Адрес по умолчанию", callbackQueryID: callbackQuery.id, client: client, logger: logger)
        default:
            try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
        }

    // MARK: - Сюрприз-блюда
    case "surprise":
        try await handleSurpriseAgainCallback(
            telegramUserID: telegramUserID,
            chatID: chatID,
            callbackQueryID: callbackQuery.id,
            req: req,
            client: client,
            logger: logger
        )

    case "promo":
        guard parts.count >= 2 else {
            try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
            return
        }
        switch parts[1] {
        case "create":
            guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
                  user.typedRole == .cook else {
                try await answerToast("Только для поваров", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await ConversationService.startPromoCreate(for: telegramUserID, on: req.db)
            try await answerToast("Новый промокод", callbackQueryID: callbackQuery.id, client: client, logger: logger)
            try await client.sendMessage(
                TelegramSendMessageRequest(
                    chatID: chatID,
                    text: "Введите промокод в формате: КОД СКИДКА\nНапример: SUMMER 10 (скидка 10%)",
                    replyMarkup: nil
                ),
                logger: logger
            )
        case "toggle":
            guard parts.count == 3,
                  let promoID = UUID(uuidString: parts[2]),
                  let promo = try await PromoCode.find(promoID, on: req.db) else {
                try await answerToast("Промокод не найден", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
                  user.typedRole == .cook,
                  promo.$cook.id == user.id else {
                try await answerToast("Только для поваров", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            promo.isActive.toggle()
            try await promo.save(on: req.db)
            try await answerToast(promo.isActive ? "Промокод включён" : "Промокод отключён", callbackQueryID: callbackQuery.id, client: client, logger: logger)
        default:
            try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
        }

    default:
        try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
    }
}

// MARK: - Оформление заказа (промпты, кол-во, подтверждение)
func handleCreateOrderPromptCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    dishIDString: String,
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

    guard user.typedRole == .client else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Только для клиентов", replyMarkup: nil),
            logger: logger
        )
        return
    }

    guard let dishID = UUID(uuidString: dishIDString),
          let dish = try await Dish.find(dishID, on: req.db),
          dish.isActive else {
        try await answerToast("Блюдо не найдено", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    try await answerToast("Сколько порций?", callbackQueryID: callbackQueryID, client: client, logger: logger)

    try await sendOrderQuantityPrompt(
        telegramUserID: telegramUserID,
        chatID: chatID,
        dishID: dishID,
        req: req,
        client: client,
        logger: logger
    )
}

func sendOrderQuantityPrompt(
    telegramUserID: Int64,
    chatID: Int64,
    dishID: UUID,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let dish = try await Dish.find(dishID, on: req.db) else { return }

    let buttons = (1...5).map { value in
        TelegramInlineKeyboardButton(
            text: "\(value)",
            callbackData: "order:qty_done:\(dishID.uuidString):\(value)"
        )
    }
    let customButton = TelegramInlineKeyboardButton(
        text: "✏️ Другое",
        callbackData: "order:qty_custom:\(dishID.uuidString)"
    )
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Сколько порций «\(dish.title)»?\n(Выберите число или введите вручную)",
            replyMarkup: TelegramInlineKeyboardMarkup(inlineKeyboard: [buttons, [customButton]])
        ),
        logger: logger
    )
}

func sendOrderConfirmDialog(
    telegramUserID: Int64,
    chatID: Int64,
    dishID: UUID,
    quantity: Int,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let dish = try await Dish.find(dishID, on: req.db) else { return }
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          user.typedRole == .client else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Только для клиентов", replyMarkup: nil),
            logger: logger
        )
        return
    }

    let totalPrice = dish.price * Double(quantity)
    let balance = user.balance ?? 0
    var text = """
    Подтвердить заказ?
    Блюдо «\(dish.title)» — \(formatQuantity(quantity))
    Сумма: \(formatPrice(totalPrice)) руб.
    Способ: самовывоз (по умолчанию) или доставка
    """
    if balance > 0 {
        text += "\n💰 Ваш баланс: \(balance) баллов"
    }
    let qty = quantity
    let markup = TelegramInlineKeyboardMarkup(inlineKeyboard: [
        [
            TelegramInlineKeyboardButton(
                text: "Подтвердить (\(qty))",
                callbackData: "order:confirm:\(dish.id?.uuidString ?? ""):\(qty)"
            )
        ],
        [
            TelegramInlineKeyboardButton(
                text: "Доставить по адресу (\(qty))",
                callbackData: "order:deliver:\(dish.id?.uuidString ?? ""):\(qty)"
            )
        ],
        [
            TelegramInlineKeyboardButton(
                text: "🎟 Промокод",
                callbackData: "order:promo:\(dish.id?.uuidString ?? ""):\(qty)"
            ),
            TelegramInlineKeyboardButton(
                text: "💰 Оплатить баллами (\(min(balance, Int(totalPrice)))",
                callbackData: "order:pay_balance:\(dish.id?.uuidString ?? ""):\(qty)"
            )
        ],
        [
            TelegramInlineKeyboardButton(
                text: "Добавить комментарий",
                callbackData: "order:comment:\(dish.id?.uuidString ?? ""):\(qty)"
            )
        ],
        [
            TelegramInlineKeyboardButton(
                text: "В избранное",
                callbackData: "dish:fav:\(dish.id?.uuidString ?? "")"
            )
        ],
        [
            TelegramInlineKeyboardButton(
                text: "📅 Заказать на другой день",
                callbackData: "order:preorder:\(dish.id?.uuidString ?? ""):\(qty)"
            )
        ],
        [
            TelegramInlineKeyboardButton(
                text: "🛒 В корзину",
                callbackData: "cart:add:\(dish.id?.uuidString ?? ""):\(qty)"
            )
        ],
        [
            TelegramInlineKeyboardButton(text: "Отмена", callbackData: "order:create_cancel")
        ]
    ])
    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: chatID, text: text, replyMarkup: markup),
        logger: logger
    )
}

// MARK: - Создание заказа (обычный / предзаказ)
func handleCreateOrderCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    dishIDString: String,
    quantityString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let clientUser = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        try await sendRoleSelection(
            telegramUserID: telegramUserID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )
        return
    }

    guard clientUser.typedRole == .client else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Только для клиентов", replyMarkup: nil),
            logger: logger
        )
        return
    }

    guard let dishID = UUID(uuidString: dishIDString),
          let dish = try await Dish.find(dishID, on: req.db),
          dish.isActive else {
        try await answerToast("Блюдо не найдено", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    guard let quantity = Int(quantityString), (1...20).contains(quantity) else {
        try await answerToast("Введите число от 1 до 20", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    try await createOrderAndNotify(
        dish: dish,
        comment: nil,
        clientUser: clientUser,
        chatID: chatID,
        req: req,
        client: client,
        logger: logger,
        quantity: quantity
    )

    try await answerToast("Заказ создан", callbackQueryID: callbackQueryID, client: client, logger: logger)
}

// MARK: - Предзаказ
func handleOrderPreorderCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    dishIDString: String,
    quantity: Int,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }
    guard user.typedRole == .client else {
        try await answerToast("Только для клиентов", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    guard let dishID = UUID(uuidString: dishIDString),
          let dish = try await Dish.find(dishID, on: req.db),
          dish.isActive else {
        try await answerToast("Блюдо не найдено", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    try await answerToast("Выберите день", callbackQueryID: callbackQueryID, client: client, logger: logger)

    let days = nextDays(count: 7)
    let buttons = days.map { day in
        TelegramInlineKeyboardButton(
            text: dayLabel(day),
            callbackData: "order:preorder_confirm:\(dishID.uuidString):\(quantity):\(formatDate(day))"
        )
    }
    var rows: [[TelegramInlineKeyboardButton]] = stride(from: 0, to: buttons.count, by: 2).map { sliceStart in
        Array(buttons[sliceStart..<min(sliceStart + 2, buttons.count)])
    }
    rows.append([
        TelegramInlineKeyboardButton(text: "Отмена", callbackData: "order:create_cancel")
    ])

    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "На какой день заказать «\(dish.title)» (\(formatQuantity(quantity)))?",
            replyMarkup: TelegramInlineKeyboardMarkup(inlineKeyboard: rows)
        ),
        logger: logger
    )
}

func handleOrderPreorderConfirmCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    dishIDString: String,
    quantity: Int,
    dateString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let clientUser = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }
    guard clientUser.typedRole == .client else {
        try await answerToast("Только для клиентов", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    guard let dishID = UUID(uuidString: dishIDString),
          let dish = try await Dish.find(dishID, on: req.db),
          dish.isActive else {
        try await answerToast("Блюдо не найдено", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    try await createOrderAndNotify(
        dish: dish,
        comment: nil,
        clientUser: clientUser,
        chatID: chatID,
        req: req,
        client: client,
        logger: logger,
        isDelivery: false,
        scheduledDate: dateString,
        quantity: quantity
    )

    try await answerToast("Заказ оформлен", callbackQueryID: callbackQueryID, client: client, logger: logger)
}

// MARK: - Статусы заказа (принят / готовится / готов / в пути)
func handleOrderStatusCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    data: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    let parts = data.split(separator: ":").map(String.init)
    guard parts.count == 4,
          let orderID = UUID(uuidString: parts[2]),
          let order = try await Order.find(orderID, on: req.db) else {
        return
    }

    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }
    guard user.typedRole == .cook else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Только для повара", replyMarkup: nil),
            logger: logger
        )
        return
    }

    guard let newStatus = allOrderStatuses.first(where: { statusTitle($0) == parts[3] }) else {
        try await answerToast("Переход статуса недоступен", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    guard let currentStatus = order.typedStatus,
          isAllowedTransition(from: currentStatus, to: newStatus) else {
        try await answerToast("Переход статуса недоступен", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    order.status = newStatus.rawValue
    try await order.save(on: req.db)

    try await answerToast("Статус обновлен", callbackQueryID: callbackQueryID, client: client, logger: logger)

    guard let clientTelegramID = try await findTelegramIDForUser(order.$client.id, on: req.db) else {
        return
    }
    let title = order.dish?.title ?? "Блюдо"
    let text = "Ваш заказ по \(title): статус -> \(statusTitle(newStatus))"
    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: clientTelegramID, text: text, replyMarkup: nil),
        logger: logger
    )

    if newStatus == .ready {
        var windowLine = ""
        if let window = order.pickupWindow {
            windowLine = "\nВремя выдачи: \(window)"
        } else if let cook = try await User.find(order.$cook.id, on: req.db),
                  let schedule = cook.pickupSchedule {
            windowLine = "\nВремя выдачи: \(schedule)"
        }
        let orderID = order.id?.uuidString ?? ""
        let pickupLabel = order.isDelivery == true ? "✅ Получил заказ" : "Я у повара"
        let readyQuestion = order.isDelivery == true ? "Когда привезти заказ?" : "Когда подойдёте?"
        let pickupAction = order.isDelivery == true ? "order:receive:\(orderID)" : "order:pickup:\(orderID)"
        let timeButtons = [
            TelegramInlineKeyboardButton(text: "Через 15 мин", callbackData: "order:time:\(orderID):15"),
            TelegramInlineKeyboardButton(text: "Через 30 мин", callbackData: "order:time:\(orderID):30"),
            TelegramInlineKeyboardButton(text: "Через час", callbackData: "order:time:\(orderID):60"),
            TelegramInlineKeyboardButton(text: "Укажу сам", callbackData: "order:time:\(orderID):custom"),
            TelegramInlineKeyboardButton(text: pickupLabel, callbackData: pickupAction)
        ]
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: clientTelegramID,
                text: "Ваш заказ по \(title): статус -> Готов. Можно забирать!\(windowLine) \(readyQuestion)",
                replyMarkup: TelegramInlineKeyboardMarkup(inlineKeyboard: [timeButtons])
            ),
            logger: logger
        )
    }

    if newStatus == .onTheWay {
        let orderID = order.id?.uuidString ?? ""
        let trackButton = TelegramInlineKeyboardButton(
            text: "📍 Геолокация курьера",
            callbackData: "order:track:\(orderID)"
        )
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: clientTelegramID,
                text: "🚚 Ваш заказ по \(title) в пути! Можно отследить курьера.",
                replyMarkup: TelegramInlineKeyboardMarkup(inlineKeyboard: [[trackButton]])
            ),
            logger: logger
        )
    }

    if newStatus == .delivered {
        let ratingButtons = (1...5).map { value in
            TelegramInlineKeyboardButton(
                text: "\(value)",
                callbackData: "order:rate:\(order.id?.uuidString ?? ""):\(value)"
            )
        }
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: clientTelegramID,
                text: "Оцените блюдо «\(title)» от 1 до 5:",
                replyMarkup: TelegramInlineKeyboardMarkup(inlineKeyboard: [ratingButtons])
            ),
            logger: logger
        )

        if order.bonusAwarded != true {
            let bonus = bonusFor(orderTotal: order.totalPrice, hasReview: order.reviewText != nil || order.reviewPhoto != nil)
            try await BotUserService.applyBonus(
                to: order.$client.id,
                amount: bonus,
                reason: "Заказ «\(title)»",
                on: req.db
            )
            order.bonusAwarded = true
            try await order.save(on: req.db)
        }
    }
}

// MARK: - Отмена заказа клиентом/поваром
func handleClientCancelOrderPromptCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    orderIDString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let orderID = UUID(uuidString: orderIDString) else { return }
    guard let order = try await Order.find(orderID, on: req.db) else { return }

    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          user.typedRole == .client,
          user.id == order.$client.id,
          isClientCancelable(order: order) else {
        try await answerToast("Заказ нельзя отменить", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    let title = order.dish?.title ?? "Блюдо"
    let markup = TelegramInlineKeyboardMarkup(inlineKeyboard: [
        [
            TelegramInlineKeyboardButton(text: "✅ Да, отменить", callbackData: "order:client_cancel_confirm:\(orderIDString)"),
            TelegramInlineKeyboardButton(text: "❌ Нет", callbackData: "order:cancel_noop")
        ]
    ])
    try await answerToast("Подтвердите отмену", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: chatID, text: "Отменить заказ по «\(title)»?", replyMarkup: markup),
        logger: logger
    )
}

func handleClientCancelOrderConfirmCallback(
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

    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }
    guard user.typedRole == .client else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Только для клиентов", replyMarkup: nil),
            logger: logger
        )
        return
    }

    guard user.id == order.$client.id,
          isClientCancelable(order: order) else {
        try await answerToast("Заказ нельзя отменить", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    order.status = OrderStatus.cancelled.rawValue
    try await order.save(on: req.db)

    if order.balanceUsed > 0 {
        try await BotUserService.applyBonus(
            to: user.id!,
            amount: order.balanceUsed,
            reason: "Возврат баллов за отменённый заказ",
            on: req.db
        )
    }

    try await answerToast("Заказ отменен", callbackQueryID: callbackQueryID, client: client, logger: logger)

    let title = order.dish?.title ?? "Блюдо"
    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: chatID, text: "Вы отменили заказ по \(title)", replyMarkup: nil),
        logger: logger
    )

    guard let cookTelegramID = try await findTelegramIDForUser(order.$cook.id, on: req.db) else {
        return
    }
    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: cookTelegramID, text: "Клиент отменил заказ по \(title)", replyMarkup: nil),
        logger: logger
    )
}

// MARK: - Голосовой комментарий, трекинг, жалоба, гео к заказу
func handleOrderVoiceCommentCallback(
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
    try await ConversationService.startVoiceComment(for: telegramUserID, orderID: orderID, on: req.db)
    try await answerToast("Жду голосовое", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Отправьте голосовое сообщение — оно будет передано повару.",
            replyMarkup: nil
        ),
        logger: logger
    )
}

func handleOrderTrackCallback(
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
    guard order.typedStatus == .onTheWay else {
        try await answerToast("Курьер ещё не в пути", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    try await answerToast("Запрашиваю геолокацию", callbackQueryID: callbackQueryID, client: client, logger: logger)
    guard let cookTelegramID = try await findTelegramIDForUser(order.$cook.id, on: req.db) else {
        return
    }
    let title = order.dish?.title ?? "Блюдо"
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: cookTelegramID,
            text: "📍 Клиент запросил геолокацию курьера по заказу «\(title)». Нажмите кнопку на карточке заказа, чтобы отправить её.",
            replyMarkup: nil
        ),
        logger: logger
    )
}

func handleOrderReportCallback(
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
    try await ConversationService.startReport(for: telegramUserID, orderID: orderID, on: req.db)
    try await answerToast("Жалоба", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Опишите проблему с заказом — мы передадим её повару и учтём в статистике.",
            replyMarkup: nil
        ),
        logger: logger
    )
}

func handleOrderSendGeoCallback(
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
          user.typedRole == .cook,
          order.$cook.id == user.id else {
        try await answerToast("Только для повара", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    try await ConversationService.startOrderLocation(for: telegramUserID, orderID: orderID, on: req.db)
    try await answerToast("Отправьте геолокацию", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Отправьте текущую геолокацию — она будет передана клиенту.",
            replyMarkup: nil
        ),
        logger: logger
    )
}

func handleOrderListenVoiceCallback(
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
          user.typedRole == .cook,
          order.$cook.id == user.id else {
        try await answerToast("Только для повара", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    guard let voiceNote = order.voiceNote, !voiceNote.isEmpty else {
        try await answerToast("Голосовой комментарий не найден", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    try await client.sendVoice(
        TelegramSendVoiceRequest(
            chatID: chatID,
            voice: voiceNote,
            caption: nil,
            replyMarkup: nil
        ),
        logger: logger
    )
}

// MARK: - Карточки заказа (клиентская / поварская), доставка, оплата балансом
func handleOrderClientCardCallback(
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
          user.typedRole == .cook,
          order.$cook.id == user.id else {
        try await answerToast("Только для повара", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    guard let clientUser = try await User.find(order.$client.id, on: req.db) else {
        return
    }
    var text = "👤 Клиент: \(clientUser.firstName)\n"
    if let phone = clientUser.phone, !phone.isEmpty {
        text += "📞 Телефон: \(phone)\n"
    }
    if let address = clientUser.address, !address.isEmpty {
        text += "📍 Адрес: \(address)\n"
    }
    let ordersCount = try await Order.query(on: req.db)
        .filter(\.$client.$id == clientUser.id!)
        .count()
    text += "📋 Всего заказов: \(ordersCount)"
    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: chatID, text: text, replyMarkup: nil),
        logger: logger
    )
}

func handleOrderCookCardCallback(
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
    guard let cookUser = try await User.find(order.$cook.id, on: req.db) else {
        return
    }

    var text = "👨‍🍳 \(cookUser.firstName)\n"
    if let lastName = cookUser.lastName, !lastName.isEmpty {
        text = "👨‍🍳 \(cookUser.firstName) \(lastName)\n"
    }
    let deliveredCount = try await Order.query(on: req.db)
        .filter(\.$cook.$id == cookUser.id!)
        .filter(\.$status == OrderStatus.delivered.rawValue)
        .count()
    text += "✅ Доставленных заказов: \(deliveredCount)\n"
    let avgRating = try await Order.query(on: req.db)
        .filter(\.$cook.$id == cookUser.id!)
        .filter(\.$rating != nil)
        .all()
        .compactMap { $0.rating }
    if !avgRating.isEmpty {
        let avg = Double(avgRating.reduce(0, +)) / Double(avgRating.count)
        text += "⭐ Рейтинг: \(String(format: "%.1f", avg)) (\(avgRating.count) оценок)\n"
    }
    if let address = cookUser.address, !address.isEmpty {
        text += "📍 Адрес: \(address)\n"
    }
    if let schedule = cookUser.pickupSchedule, !schedule.isEmpty {
        text += "🕐 Часы выдачи: \(schedule)\n"
    }
    let cookID = cookUser.id?.uuidString ?? ""
    var rows: [[TelegramInlineKeyboardButton]] = []
    var footer: [TelegramInlineKeyboardButton] = []
    footer.append(TelegramInlineKeyboardButton(
        text: "🗺 Карта",
        callbackData: "cook:map:\(cookID)"
    ))
    footer.append(TelegramInlineKeyboardButton(
        text: "📋 Меню повара",
        callbackData: "cook:menu:\(cookID)"
    ))
    let reviewCount = try await Order.query(on: req.db)
        .filter(\.$cook.$id == cookUser.id!)
        .filter(\.$reviewText != nil)
        .count()
    if reviewCount > 0 {
        footer.append(TelegramInlineKeyboardButton(
            text: "⭐ \(reviewCount)",
            callbackData: "cook:reviews:\(cookID)"
        ))
    }
    rows.append(footer)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: text,
            replyMarkup: TelegramInlineKeyboardMarkup(inlineKeyboard: rows)
        ),
        logger: logger
    )
}

func handleOrderDeliverCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    dishIDString: String,
    quantity: Int,
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

    guard user.typedRole == .client else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Только для клиентов", replyMarkup: nil),
            logger: logger
        )
        return
    }

    guard let dishID = UUID(uuidString: dishIDString),
          let dish = try await Dish.find(dishID, on: req.db),
          dish.isActive else {
        try await answerToast("Блюдо не найдено", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    if let address = user.address, !address.isEmpty {
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
        try await answerToast("Заказ с доставкой создан", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    try await ConversationService.startAddress(for: telegramUserID, dishID: dishID, on: req.db)
    try await ConversationService.setQuantity(for: telegramUserID, quantity: quantity, on: req.db)
    try await answerToast("Укажите адрес доставки", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Введите адрес доставки (например: г. Москва, ул. Ленина, 5) или отправьте '-' чтобы оформить самовывоз:",
            replyMarkup: nil
        ),
        logger: logger
    )
}

func handleOrderPayBalanceCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    dishIDString: String,
    quantity: Int,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          user.typedRole == .client,
          let dishID = UUID(uuidString: dishIDString),
          let dish = try await Dish.find(dishID, on: req.db),
          dish.isActive else {
        try await answerToast("Блюдо не найдено", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    let balance = user.balance ?? 0
    let totalPrice = dish.price * Double(quantity)
    guard balance > 0 else {
        try await answerToast("У вас нет баллов", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    let useBalance = min(balance, Int(totalPrice.rounded(.down)))
    try await createOrderAndNotify(
        dish: dish,
        comment: nil,
        clientUser: user,
        chatID: chatID,
        req: req,
        client: client,
        logger: logger,
        quantity: quantity,
        balanceUsed: useBalance
    )
    try await answerToast("Заказ создан, списано \(useBalance) баллов", callbackQueryID: callbackQueryID, client: client, logger: logger)
}

func handleOrderCommentCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    dishIDString: String,
    quantity: Int,
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

    guard user.typedRole == .client else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Только для клиентов", replyMarkup: nil),
            logger: logger
        )
        return
    }

    guard let dishID = UUID(uuidString: dishIDString),
          let dish = try await Dish.find(dishID, on: req.db),
          dish.isActive else {
        try await answerToast("Блюдо не найдено", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    try await ConversationService.startOrderComment(for: telegramUserID, dishID: dishID, on: req.db)
    try await ConversationService.setQuantity(for: telegramUserID, quantity: quantity, on: req.db)

    try await answerToast("Добавьте комментарий к заказу", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Введите комментарий к заказу (или '-' чтобы пропустить):",
            replyMarkup: nil
        ),
        logger: logger
    )
}

// MARK: - Фото блюда, избранное, отметки «сегодня»
func handleDishPhotoCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    dishIDString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }

    guard let dishID = UUID(uuidString: dishIDString),
          let dish = try await Dish.find(dishID, on: req.db),
          dish.$cook.id == user.id else {
        try await answerToast("Блюдо не найдено", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    try await ConversationService.startDishPhoto(for: telegramUserID, dishID: dishID, on: req.db)

    try await answerToast("Отправьте фото", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Отправьте фото блюда «\(dish.title)» (или '-' чтобы без фото):",
            replyMarkup: nil
        ),
        logger: logger
    )
}

func handleFavoriteToggleCallback(
    telegramUserID: Int64,
    callbackQueryID: String,
    dishIDString: String,
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
    guard let dishID = UUID(uuidString: dishIDString),
          try await Dish.find(dishID, on: req.db) != nil else {
        try await answerToast("Блюдо не найдено", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    if let existing = try await Favorite.query(on: req.db)
        .filter(\.$client.$id == userID)
        .filter(\.$dish.$id == dishID)
        .first() {
        try await existing.delete(on: req.db)
        try await answerToast("Убрано из избранного", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    let favorite = Favorite(clientID: userID, dishID: dishID)
    try await favorite.save(on: req.db)
    try await answerToast("Добавлено в избранное", callbackQueryID: callbackQueryID, client: client, logger: logger)
}

func handleDishTodayCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    dishIDString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }
    guard let dishID = UUID(uuidString: dishIDString),
          let dish = try await Dish.find(dishID, on: req.db),
          dish.$cook.id == user.id else {
        try await answerToast("Блюдо не найдено", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    try await ConversationService.startPortions(for: telegramUserID, dishID: dishID, on: req.db)

    try await answerToast("На сегодня", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Сколько порций «\(dish.title)» готовите сегодня? (числом, например: 5; или '-' без лимита)",
            replyMarkup: nil
        ),
        logger: logger
    )
}

func handleDishUntodayCallback(
    telegramUserID: Int64,
    callbackQueryID: String,
    dishIDString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }
    guard let dishID = UUID(uuidString: dishIDString),
          let dish = try await Dish.find(dishID, on: req.db),
          dish.$cook.id == user.id else {
        try await answerToast("Блюдо не найдено", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    dish.cookedDate = nil
    dish.portionsTotal = nil
    dish.portionsLeft = nil
    try await dish.save(on: req.db)

    try await answerToast("Убрано с сегодня", callbackQueryID: callbackQueryID, client: client, logger: logger)
}

// MARK: - Выбор типа блюда при заказе
func handleDishTypeCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    dishIDString: String,
    typeRaw: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }
    guard let dishID = UUID(uuidString: dishIDString),
          let dish = try await Dish.find(dishID, on: req.db),
          dish.$cook.id == user.id else {
        try await answerToast("Блюдо не найдено", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    if typeRaw != "skip" {
        dish.dishType = typeRaw
        try await dish.save(on: req.db)
    }

    if let state = try await ConversationService.getState(for: telegramUserID, on: req.db) {
        state.step = ConversationStep.waitingDishPhoto.rawValue
        try await state.save(on: req.db)
    }

    let typeLine = dishTypeTitle(dish.dishType).map { "\nКатегория: \($0)" } ?? ""
    try await answerToast("Категория сохранена", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Блюдо «\(dish.title)»\(typeLine). Теперь отправьте фото (или '-' чтобы без фото):",
            replyMarkup: nil
        ),
        logger: logger
    )
}

func handleCookCancelOrderPromptCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    orderIDString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let orderID = UUID(uuidString: orderIDString) else { return }
    guard let order = try await Order.find(orderID, on: req.db) else { return }

    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          user.typedRole == .cook,
          user.id == order.$cook.id,
          let currentStatus = order.typedStatus,
          isClientCancelable(status: currentStatus) else {
        try await answerToast("Заказ нельзя отменить", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    let title = order.dish?.title ?? "Блюдо"
    let markup = TelegramInlineKeyboardMarkup(inlineKeyboard: [
        [
            TelegramInlineKeyboardButton(text: "✅ Да, отменить", callbackData: "order:cook_cancel_confirm:\(orderIDString)"),
            TelegramInlineKeyboardButton(text: "❌ Нет", callbackData: "order:cancel_noop")
        ]
    ])
    try await answerToast("Подтвердите отмену", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: chatID, text: "Отменить заказ по «\(title)»?", replyMarkup: markup),
        logger: logger
    )
}

func handleCookCancelOrderConfirmCallback(
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

    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }
    guard user.typedRole == .cook else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Только для повара", replyMarkup: nil),
            logger: logger
        )
        return
    }

    guard user.id == order.$cook.id,
          let currentStatus = order.typedStatus,
          isClientCancelable(status: currentStatus) else {
        try await answerToast("Заказ нельзя отменить", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    order.status = OrderStatus.cancelled.rawValue
    try await order.save(on: req.db)

    try await answerToast("Заказ отменен", callbackQueryID: callbackQueryID, client: client, logger: logger)

    let title = order.dish?.title ?? "Блюдо"
    guard let clientTelegramID = try await findTelegramIDForUser(order.$client.id, on: req.db) else {
        return
    }
    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: clientTelegramID, text: "Повар отменил заказ по \(title)", replyMarkup: nil),
        logger: logger
    )
}

// MARK: - Оценка заказа, окно забора, время, самовывоз
func handleRateOrderCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    data: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    let parts = data.split(separator: ":").map(String.init)
    guard parts.count == 4,
          let orderID = UUID(uuidString: parts[2]),
          let rating = Int(parts[3]),
          (1...5).contains(rating) else {
        return
    }

    guard let order = try await Order.find(orderID, on: req.db) else {
        return
    }

    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }
    guard user.typedRole == .client else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Только для клиентов", replyMarkup: nil),
            logger: logger
        )
        return
    }

    guard user.id == order.$client.id,
          order.typedStatus == .delivered,
          order.rating == nil else {
        return
    }

    order.rating = rating
    try await order.save(on: req.db)

    try await answerToast("Спасибо за оценку!", callbackQueryID: callbackQueryID, client: client, logger: logger)

    guard let orderID = order.id else { return }
    try await ConversationService.startReviewText(for: telegramUserID, orderID: orderID, on: req.db)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Напишите отзыв о блюде текстом (или '-' чтобы пропустить):",
            replyMarkup: nil
        ),
        logger: logger
    )
}

func handleOrderWindowCallback(
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

    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }
    guard user.typedRole == .cook else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Только для повара", replyMarkup: nil),
            logger: logger
        )
        return
    }

    try await answerToast("Укажите окно выдачи", callbackQueryID: callbackQueryID, client: client, logger: logger)

    let cook = try await User.find(order.$cook.id, on: req.db)
    let current = order.pickupWindow ?? cook?.pickupSchedule
    let currentLine = current.map { "\nТекущее окно: \($0)" } ?? ""
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Введите окно выдачи для заказа (например: 12:00-14:00)\(currentLine)\nОтправьте '-' чтобы убрать:",
            replyMarkup: nil
        ),
        logger: logger
    )
    try await ConversationService.startOrderWindow(for: telegramUserID, orderID: orderID, on: req.db)
}

func handleOrderTimeCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    data: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    let parts = data.split(separator: ":").map(String.init)
    guard parts.count == 4,
          let orderID = UUID(uuidString: parts[2]),
          let order = try await Order.find(orderID, on: req.db) else {
        return
    }

    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }
    guard user.typedRole == .client else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Только для клиентов", replyMarkup: nil),
            logger: logger
        )
        return
    }
    guard order.typedStatus == .ready else {
        try await answerToast("Заказ ещё не готов", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    if parts[3] == "custom" {
        try await ConversationService.startPickupTime(for: telegramUserID, orderID: orderID, on: req.db)
        try await answerToast("Укажите время", callbackQueryID: callbackQueryID, client: client, logger: logger)
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "К какому времени заберёте заказ? (например: 14:30 или отправьте '-' чтобы пропустить)",
                replyMarkup: nil
            ),
            logger: logger
        )
        return
    }

    guard let minutes = Int(parts[3]), [15, 30, 60].contains(minutes) else {
        return
    }
    let pickupTime = formatTime(Date().addingTimeInterval(TimeInterval(minutes * 60)))
    order.pickupTime = pickupTime
    try await order.save(on: req.db)

    try await answerToast("Время сохранено", callbackQueryID: callbackQueryID, client: client, logger: logger)

    guard let cookTelegramID = try await findTelegramIDForUser(order.$cook.id, on: req.db) else {
        return
    }
    let shortID = String(order.id?.uuidString.prefix(8) ?? "")
    let deliveryAction = order.isDelivery == true ? "Доставить заказ" : "Клиент заберёт заказ"
    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: cookTelegramID, text: "\(deliveryAction) #\(shortID) к \(pickupTime)", replyMarkup: nil),
        logger: logger
    )
}

func handleOrderPickupCallback(
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

    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }
    guard user.typedRole == .client else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Только для клиентов", replyMarkup: nil),
            logger: logger
        )
        return
    }
    guard order.typedStatus == .ready else {
        try await answerToast("Заказ ещё не готов", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

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

    try await answerToast("Отлично! Приятного аппетита", callbackQueryID: callbackQueryID, client: client, logger: logger)

    let title = order.dish?.title ?? "Блюдо"
    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: chatID, text: "Вы забрали заказ по \(title). Спасибо!", replyMarkup: nil),
        logger: logger
    )

    guard let cookTelegramID = try await findTelegramIDForUser(order.$cook.id, on: req.db) else {
        return
    }
    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: cookTelegramID, text: "Клиент забрал заказ по \(title)", replyMarkup: nil),
        logger: logger
    )

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

// MARK: - Изменение адреса заказа
func handleOrderRescheduleCallback(
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
    let title = order.dish?.title ?? "Блюдо"
    let days = nextDays(count: 7)
    let buttons = days.map { day in
        TelegramInlineKeyboardButton(
            text: dayLabel(day),
            callbackData: "order:reschedule_date:\(orderID.uuidString):\(formatDate(day))"
        )
    }
    var rows: [[TelegramInlineKeyboardButton]] = stride(from: 0, to: buttons.count, by: 2).map { sliceStart in
        Array(buttons[sliceStart..<min(sliceStart + 2, buttons.count)])
    }
    rows.append([
        TelegramInlineKeyboardButton(text: "Отмена", callbackData: "order:create_cancel")
    ])
    try await answerToast("Выберите новую дату", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Перенести заказ «\(title)» на какой день?",
            replyMarkup: TelegramInlineKeyboardMarkup(inlineKeyboard: rows)
        ),
        logger: logger
    )
}

func handleOrderRescheduleDateCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    orderIDString: String,
    dateString: String,
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
    guard order.typedStatus != .cancelled, order.typedStatus != .delivered else {
        try await answerToast("Нельзя перенести", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    order.rescheduleTo = dateString
    order.scheduledDate = dateString
    try await order.save(on: req.db)
    try await answerToast("Перенесено на \(dateString)", callbackQueryID: callbackQueryID, client: client, logger: logger)

    let title = order.dish?.title ?? "Блюдо"
    if let cookTelegramID = try await findTelegramIDForUser(order.$cook.id, on: req.db) {
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: cookTelegramID,
                text: "📅 Заказ «\(title)» перенесён клиентом на \(dateString).",
                replyMarkup: nil
            ),
            logger: logger
        )
    }
}

func handleOrderChangeAddressCallback(
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
    let title = order.dish?.title ?? "Блюдо"
    try await answerToast("Адрес", callbackQueryID: callbackQueryID, client: client, logger: logger)

    let saved = try await Address.query(on: req.db)
        .filter(\.$user.$id == order.$client.id)
        .all()
    if !saved.isEmpty {
        var rows: [[TelegramInlineKeyboardButton]] = saved.map { address in
            [TelegramInlineKeyboardButton(
                text: "✅ \(address.name) — \(address.text)",
                callbackData: "order:pick_address:\(orderID.uuidString):\(address.id?.uuidString ?? "")"
            )]
        }
        rows.append([
            TelegramInlineKeyboardButton(
                text: "+ Добавить адрес",
                callbackData: "order:add_address:\(orderID.uuidString)"
            )
        ])
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "Выберите адрес для заказа «\(title)»:",
                replyMarkup: TelegramInlineKeyboardMarkup(inlineKeyboard: rows)
            ),
            logger: logger
        )
    } else {
        try await ConversationService.startOrderAddress(for: telegramUserID, orderID: orderID, on: req.db)
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "Введите адрес доставки для заказа «\(title)»:",
                replyMarkup: nil
            ),
            logger: logger
        )
    }
}

func handleOrderPickAddressCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    orderIDString: String,
    addressIDString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let orderID = UUID(uuidString: orderIDString),
          let order = try await Order.find(orderID, on: req.db) else {
        return
    }
    guard let address = try await Address.find(UUID(uuidString: addressIDString), on: req.db) else {
        try await answerToast("Адрес не найден", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    order.shippingAddress = address.text
    order.isDelivery = true
    try await order.save(on: req.db)
    try await answerToast("✅ Доставка к \(address.name)", callbackQueryID: callbackQueryID, client: client, logger: logger)

    let title = order.dish?.title ?? "Блюдо"
    if let cookTelegramID = try await findTelegramIDForUser(order.$cook.id, on: req.db) {
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: cookTelegramID,
                text: "🚚 Заказ «\(title)»: доставка по адресу \(address.text).",
                replyMarkup: nil
            ),
            logger: logger
        )
    }
}

func handleOrderAddAddressCallback(
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
    try await ConversationService.startOrderAddress(for: telegramUserID, orderID: orderID, on: req.db)
    try await answerToast("Введите адрес", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Введите адрес доставки для заказа «\(order.dish?.title ?? "Блюдо")»:",
            replyMarkup: nil
        ),
        logger: logger
    )
}

// MARK: - Чат с заказчиком, подписки на повара
func handleOrderChatCallback(
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
    let title = order.dish?.title ?? "Блюдо"
    try await answerToast("Чат", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await ConversationService.startChatMessage(for: telegramUserID, orderID: orderID, on: req.db)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "✍️ Напишите сообщение повару по заказу «\(title)» (или '-' чтобы отменить).",
            replyMarkup: nil
        ),
        logger: logger
    )
}

func handleCookSubscribeCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    cookIDString: String,
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
    guard let cookID = UUID(uuidString: cookIDString),
          let cook = try await User.find(cookID, on: req.db) else {
        try await answerToast("Повар не найден", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    if let existing = try await Subscription.query(on: req.db)
        .filter(\.$client.$id == userID)
        .filter(\.$cook.$id == cookID)
        .first() {
        try await existing.delete(on: req.db)
        try await answerToast("Вы отписались от \(cook.firstName)", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    let subscription = Subscription(clientID: userID, cookID: cookID)
    try await subscription.save(on: req.db)
    try await answerToast("Вы следите за \(cook.firstName)", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Теперь вы узнаете, когда \(cook.firstName) готовит сегодня. Управление — в «Мои повара».",
            replyMarkup: nil
        ),
        logger: logger
    )
}

func handleCookUnsubscribeCallback(
    telegramUserID: Int64,
    callbackQueryID: String,
    cookIDString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          let userID = user.id else {
        return
    }
    guard let cookID = UUID(uuidString: cookIDString),
          let cook = try await User.find(cookID, on: req.db) else {
        try await answerToast("Повар не найден", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    if let existing = try await Subscription.query(on: req.db)
        .filter(\.$client.$id == userID)
        .filter(\.$cook.$id == cookID)
        .first() {
        try await existing.delete(on: req.db)
    }
    try await answerToast("Вы отписались от \(cook.firstName)", callbackQueryID: callbackQueryID, client: client, logger: logger)
}

// MARK: - Меню повара, фото отзывов, сюрприз, карта, отзывы
func handleCookMenuCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    cookIDString: String,
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
    guard let cookID = UUID(uuidString: cookIDString),
          let clientLatitude = user.latitude,
          let clientLongitude = user.longitude else {
        try await answerToast("Сначала поделитесь геолокацией", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    let menus = try await collectNearbyMenus(
        clientLatitude: clientLatitude,
        clientLongitude: clientLongitude,
        req: req
    )
    guard let menu = menus.first(where: { $0.cook.id == cookID }) else {
        try await answerToast("Повар сейчас не готовит", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    try await answerToast("Меню", callbackQueryID: callbackQueryID, client: client, logger: logger)

    let subscriptions = try await Subscription.query(on: req.db)
        .filter(\.$client.$id == userID)
        .all()
    let subscribedCookIDs = Set(subscriptions.compactMap { $0.$cook.id })
    try await sendMenuMessage(
        menu: menu,
        subscribedCookIDs: subscribedCookIDs,
        req: req,
        chatID: chatID,
        client: client,
        logger: logger
    )
}

func handleReviewPhotosCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    cookIDString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }
    guard user.typedRole == .client else {
        try await answerToast("Только для клиентов", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    guard let cookID = UUID(uuidString: cookIDString) else {
        return
    }

    let reviewOrders = try await Order.query(on: req.db)
        .filter(\.$cook.$id == cookID)
        .filter(\.$reviewPhoto != nil)
        .sort(\.$createdAt, .descending)
        .limit(3)
        .all()

    guard !reviewOrders.isEmpty else {
        try await answerToast("Фото пока нет", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    try await answerToast("Фото от клиентов", callbackQueryID: callbackQueryID, client: client, logger: logger)
    for order in reviewOrders {
        guard let photoFileID = order.reviewPhoto else { continue }
        let ratingLine = order.rating.map { "Оценка: \($0)/5" } ?? ""
        try await client.sendPhoto(
            TelegramSendPhotoRequest(chatID: chatID, photo: photoFileID, caption: ratingLine, replyMarkup: nil),
            logger: logger
        )
    }
}

func handleSurpriseAgainCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let state = try await ConversationService.getState(for: telegramUserID, on: req.db),
          state.typedStep == .waitingSurpriseBudget,
          let budgetString = state.draftTitle,
          let budget = Double(budgetString) else {
        try await answerToast("Укажите бюджет", callbackQueryID: callbackQueryID, client: client, logger: logger)
        try await ConversationService.startSurpriseBudget(for: telegramUserID, budget: nil, on: req.db)
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "Введите ваш бюджет в рублях, например: 500",
                replyMarkup: nil
            ),
            logger: logger
        )
        return
    }

    try await answerToast("Ещё раз", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await sendSurprise(
        telegramUserID: telegramUserID,
        chatID: chatID,
        budget: budget,
        req: req,
        client: client,
        logger: logger
    )
}

func handleCookMapCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    cookIDString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let cook = try await User.find(UUID(uuidString: cookIDString), on: req.db),
          let lat = cook.latitude, let lng = cook.longitude else {
        try await answerToast("Геопозиция повара неизвестна", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    try await answerToast("Карта", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await client.sendLocation(
        TelegramSendLocationRequest(
            chatID: chatID,
            latitude: lat,
            longitude: lng,
            title: "Кухня \(cook.firstName)",
            address: cook.address
        ),
        logger: logger
    )
}

func handleCookReviewsCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    cookIDString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let cookID = UUID(uuidString: cookIDString) else {
        try await answerToast("Повар не найден", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    let reviewOrders = try await Order.query(on: req.db)
        .filter(\.$cook.$id == cookID)
        .filter(\.$rating != nil)
        .with(\.$client)
        .with(\.$dish)
        .sort(\.$createdAt, .descending)
        .all()

    guard !reviewOrders.isEmpty else {
        try await answerToast("Отзывов пока нет", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    try await answerToast("Отзывы", callbackQueryID: callbackQueryID, client: client, logger: logger)
    for order in reviewOrders {
        let title = order.dish?.title ?? "Блюдо"
        let clientName = order.client.firstName
        let ratingLine = order.rating.map { "⭐ \($0)/5" } ?? ""
        let textLine = order.reviewText.map { "\n\($0)" } ?? ""
        let photoButton = order.reviewPhoto.map { _ in
            TelegramInlineKeyboardMarkup(inlineKeyboard: [[
                TelegramInlineKeyboardButton(text: "📷 Фото", callbackData: "cook:review_photos:\(order.cook.id?.uuidString ?? "")")
            ]])
        }
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "\(clientName) оценил «\(title)» \(ratingLine)\(textLine)",
                replyMarkup: photoButton
            ),
            logger: logger
        )
    }
}

// MARK: - Ответ на заказ, лист ожидания
func handleOrderReplyCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    orderIDString: String,
    fromTelegramID: Int64,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let orderID = UUID(uuidString: orderIDString),
          let order = try await Order.find(orderID, on: req.db) else {
        return
    }
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          let userID = user.id,
          order.$cook.id == userID || order.$client.id == userID else {
        try await answerToast("Только для участников этого заказа", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    try await answerToast("Пишите ответ…", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await ConversationService.startChatMessage(for: telegramUserID, orderID: orderID, on: req.db)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Введите ответ (собеседник получит ваше сообщение):",
            replyMarkup: nil
        ),
        logger: logger
    )
}

func handleOrderReplyDoneCallback(
    telegramUserID: Int64,
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
          user.typedRole == .cook,
          order.$cook.id == user.id else {
        try await answerToast("Только для повара", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    let title = order.dish?.title ?? "Блюдо"
    let shortID = order.id?.uuidString.prefix(8) ?? ""
    try await answerToast("Готово", callbackQueryID: callbackQueryID, client: client, logger: logger)
    guard let clientTelegramID = try await findTelegramIDForUser(order.$client.id, on: req.db) else {
        return
    }
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: clientTelegramID,
            text: "🛑 Повар закрыл чат по заказу #\(shortID) «\(title)». Если что — пишите в поддержку.",
            replyMarkup: nil
        ),
        logger: logger
    )
}

func handleOrderWaitlistCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    dishIDString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }
    guard user.typedRole == .client else {
        try await answerToast("Только для клиентов", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    guard let dishID = UUID(uuidString: dishIDString),
          let dish = try await Dish.find(dishID, on: req.db) else {
        try await answerToast("Блюдо не найдено", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }
    guard let userID = user.id else { return }

    if let existing = try await WaitlistEntry.query(on: req.db)
        .filter(\.$dish.$id == dishID)
        .filter(\.$client.$id == userID)
        .first() {
        try await existing.delete(on: req.db)
        try await answerToast("Вы удалены из списка ожидания", callbackQueryID: callbackQueryID, client: client, logger: logger)
        return
    }

    let entry = WaitlistEntry(dishID: dishID, clientID: userID, quantity: 1)
    try await entry.save(on: req.db)
    try await answerToast("Вы в списке ожидания 👍", callbackQueryID: callbackQueryID, client: client, logger: logger)
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Когда повар пополнит порции «\(dish.title)» — мы вас уведомим. Отпишитесь через кнопку снова.",
            replyMarkup: nil
        ),
        logger: logger
    )

    if let cookTelegramID = try await findTelegramIDForUser(dish.$cook.id, on: req.db) {
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: cookTelegramID,
                text: "👥 Кто‑то ждёт ваше блюдо «\(dish.title)» в списке ожидания.",
                replyMarkup: nil
            ),
            logger: logger
        )
    }
}

func notifyWaitlistOnRestock(
    dish: Dish,
    addedPortions: Int,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    let entries = try await WaitlistEntry.query(on: req.db)
        .filter(\.$dish.$id == (dish.id ?? UUID()))
        .filter(\.$notified == false)
        .sort(\.$createdAt)
        .all()
    guard !entries.isEmpty else { return }

    for entry in entries {
        guard let clientTelegramID = try await findTelegramIDForUser(entry.$client.id, on: req.db) else {
            continue
        }
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: clientTelegramID,
                text: "🔥 «\(dish.title)» пополнилось! Быстро заберите — ваше место в очереди.",
                replyMarkup: nil
            ),
            logger: logger
        )
        entry.notified = true
        try await entry.save(on: req.db)
    }
}

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
