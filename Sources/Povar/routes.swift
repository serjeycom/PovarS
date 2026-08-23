import Fluent
import Vapor

func routes(_ app: Application) throws {
    app.get { _ async in
        ["status": "ok", "service": "povar-bot-api"]
    }

    app.post("telegram", "webhook") { req async throws -> HTTPStatus in
        try await handleTelegramWebhook(req)
    }

    app.post("telegram", "webhook", ":secret") { req async throws -> HTTPStatus in
        try await handleTelegramWebhook(req)
    }
}

private func handleTelegramWebhook(_ req: Request) async throws -> HTTPStatus {
    if let expectedSecret = Environment.get("TELEGRAM_WEBHOOK_SECRET") {
        let providedSecret = req.parameters.get("secret")
        guard providedSecret == expectedSecret else {
            throw Abort(.unauthorized)
        }
    }

    let update = try req.content.decode(TelegramUpdate.self)
    guard let botToken = Environment.get("TELEGRAM_BOT_TOKEN"), !botToken.isEmpty else {
        req.logger.warning("telegram update ignored: TELEGRAM_BOT_TOKEN is missing")
        return .ok
    }

    let client = TelegramBotClient(app: req.application, botToken: botToken)

    if let message = update.message {
        try await handleMessage(message, req: req, client: client, logger: req.logger)
    }

    if let callbackQuery = update.callbackQuery {
        try await handleCallbackQuery(callbackQuery, req: req, client: client, logger: req.logger)
    }

    return .ok
}
