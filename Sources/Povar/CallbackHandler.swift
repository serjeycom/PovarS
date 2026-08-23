import Fluent
import Foundation
import Vapor

let allOrderStatuses: [OrderStatus] = [.new, .accepted, .cooking, .ready, .onTheWay, .delivered, .cancelled]

func answerToast(
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

    // MARK: - Настройки уведомлений (вкл/выкл, тихие часы)
    case "notif":
        guard parts.count >= 2 else {
            try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
            return
        }
        switch parts[1] {
        case "toggle":
            try await handleNotificationToggleCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                req: req,
                client: client,
                logger: logger
            )
        case "quiet":
            guard parts.count == 4 else {
                try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
                return
            }
            try await handleNotificationQuietHoursCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                startString: parts[2],
                endString: parts[3],
                req: req,
                client: client,
                logger: logger
            )
        case "quiet_off":
            try await handleNotificationQuietHoursOffCallback(
                telegramUserID: telegramUserID,
                chatID: chatID,
                callbackQueryID: callbackQuery.id,
                req: req,
                client: client,
                logger: logger
            )
        default:
            try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
        }

    default:
        try await answerToast("Неизвестное действие", callbackQueryID: callbackQuery.id, client: client, logger: logger)
    }
}
