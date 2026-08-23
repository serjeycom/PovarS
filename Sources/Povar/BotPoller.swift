import Fluent
import NIOConcurrencyHelpers
import Vapor

struct TelegramGetUpdatesRequest: Content {
    let offset: Int
    let timeout: Int
    let allowedUpdates: [String]

    enum CodingKeys: String, CodingKey {
        case offset
        case timeout
        case allowedUpdates = "allowed_updates"
    }
}

struct TelegramGetUpdatesResponse: Content {
    let ok: Bool
    let result: [TelegramUpdate]?
}

final class BotPoller: @unchecked Sendable, LifecycleHandler {
    private let app: Application
    private let client: TelegramBotClient
    private let lock = NIOLock()
    private var offset: Int?
    private var task: Task<Void, Never>?
    private var reminderTask: Task<Void, Never>?

    init(app: Application, client: TelegramBotClient) {
        self.app = app
        self.client = client
    }

    func didBoot(_ application: Application) throws {
        let pollerTask = Task { await self.run() }
        let reminders = Task { await self.runReminders() }
        lock.withLock {
            task = pollerTask
            reminderTask = reminders
        }
    }

    func shutdown(_ application: Application) {
        let runningTasks = lock.withLock { () -> [Task<Void, Never>?] in
            let tasks = [task, reminderTask]
            task = nil
            reminderTask = nil
            return tasks
        }
        for runningTask in runningTasks {
            runningTask?.cancel()
        }
    }

    private func runReminders() async {
        app.logger.info("bot reminders started")
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled else { break }

            let req = Request(
                application: app,
                method: .GET,
                url: URI(string: "/"),
                on: app.eventLoopGroup.next()
            )
            do {
                let cutoff = Date().addingTimeInterval(-600)
                let orders = try await Order.query(on: req.db)
                    .filter(\.$status == OrderStatus.ready.rawValue)
                    .filter(\.$pickupTime == nil)
                    .filter(\.$pickupReminderSent != true)
                    .filter(\.$updatedAt < cutoff)
                    .all()
                for order in orders {
                    guard let clientTelegramID = try await findTelegramIDForUser(order.$client.id, on: req.db) else {
                        continue
                    }
                    let title = order.dish?.title ?? "Блюдо"
                    let orderID = order.id?.uuidString ?? ""
                    let buttons = [
                        TelegramInlineKeyboardButton(text: "Через 15 мин", callbackData: "order:time:\(orderID):15"),
                        TelegramInlineKeyboardButton(text: "Через 30 мин", callbackData: "order:time:\(orderID):30"),
                        TelegramInlineKeyboardButton(text: "Через час", callbackData: "order:time:\(orderID):60"),
                        TelegramInlineKeyboardButton(text: "Укажу сам", callbackData: "order:time:\(orderID):custom")
                    ]
                    try await client.sendMessage(
                        TelegramSendMessageRequest(
                            chatID: clientTelegramID,
                            text: "Напоминание: ваш заказ по «\(title)» готов, но время получения не указано. Когда заберёте?",
                            replyMarkup: TelegramInlineKeyboardMarkup(inlineKeyboard: [buttons])
                        ),
                        logger: app.logger
                    )
                    order.pickupReminderSent = true
                    try await order.save(on: req.db)
                    app.logger.info("pickup reminder sent", metadata: ["orderID": "\(order.id?.uuidString ?? "")"])
                }
            } catch {
                app.logger.error("bot reminders error: \(error)")
            }
        }
    }

    private func run() async {
        await deleteWebhook()
        app.logger.info("bot poller started")

        while !Task.isCancelled {
            do {
                let updates = try await fetchUpdates()
                guard !updates.isEmpty else { continue }

                for update in updates {
                    await process(update)
                    offset = update.updateID + 1
                }
            } catch {
                app.logger.error("bot poller error: \(error)")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func deleteWebhook() async {
        let uri = "https://api.telegram.org/bot\(client.botToken)/deleteWebhook"
        do {
            let response = try await app.client.get(URI(string: uri))
            if response.status != .ok {
                app.logger.warning("telegram deleteWebhook failed", metadata: ["status": "\(response.status.code)"])
            } else {
                app.logger.info("telegram webhook deleted")
            }
        } catch {
            app.logger.error("telegram deleteWebhook error: \(error)")
        }
    }

    private func fetchUpdates() async throws -> [TelegramUpdate] {
        let uri = "https://api.telegram.org/bot\(client.botToken)/getUpdates"
        let body = TelegramGetUpdatesRequest(
            offset: offset ?? 0,
            timeout: 10,
            allowedUpdates: ["message", "callback_query", "pre_checkout_query"]
        )
        let response = try await app.client.post(URI(string: uri)) { req in
            try req.content.encode(body)
        }
        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "getUpdates status \(response.status.code)")
        }
        let decoded = try response.content.decode(TelegramGetUpdatesResponse.self)
        return decoded.result ?? []
    }

    private func process(_ update: TelegramUpdate) async {
        app.logger.info("bot poller processing update", metadata: ["updateID": "\(update.updateID)"])
        let req = Request(
            application: app,
            method: .GET,
            url: URI(string: "/"),
            on: app.eventLoopGroup.next()
        )
        do {
            if let message = update.message {
                try await handleMessage(message, req: req, client: client, logger: app.logger)
            }
            if let callbackQuery = update.callbackQuery {
                try await handleCallbackQuery(callbackQuery, req: req, client: client, logger: app.logger)
            }
            if let preCheckoutQuery = update.preCheckoutQuery {
                try await handlePreCheckoutQuery(
                    query: preCheckoutQuery,
                    req: req,
                    client: client,
                    logger: app.logger
                )
            }
        } catch {
            app.logger.error("bot poller update handling failed", metadata: [
                "updateID": "\(update.updateID)",
                "error": "\(error)"
            ])
        }
    }
}
