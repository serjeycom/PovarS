import Vapor

struct TelegramSendMessageRequest: Content {
    let chatID: Int64
    let text: String
    let replyMarkup: TelegramInlineKeyboardMarkup?

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case text
        case replyMarkup = "reply_markup"
    }
}

struct TelegramAnswerCallbackQueryRequest: Content {
    let callbackQueryID: String
    let text: String?

    enum CodingKeys: String, CodingKey {
        case callbackQueryID = "callback_query_id"
        case text
    }
}

struct TelegramInlineKeyboardMarkup: Content {
    let inlineKeyboard: [[TelegramInlineKeyboardButton]]

    enum CodingKeys: String, CodingKey {
        case inlineKeyboard = "inline_keyboard"
    }
}

struct TelegramInlineKeyboardButton: Content {
    let text: String
    let callbackData: String?
    let webApp: TelegramWebAppInfo?

    init(text: String, callbackData: String) {
        self.text = text
        self.callbackData = callbackData
        self.webApp = nil
    }

    init(text: String, webApp: TelegramWebAppInfo) {
        self.text = text
        self.callbackData = nil
        self.webApp = webApp
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        if let callbackData { try container.encode(callbackData, forKey: .callbackData) }
        if let webApp { try container.encode(webApp, forKey: .webApp) }
    }

    enum CodingKeys: String, CodingKey {
        case text
        case callbackData = "callback_data"
        case webApp = "web_app"
    }
}

struct TelegramWebAppInfo: Content {
    let url: String
}

struct TelegramSendInvoiceRequest: Content {
    let chatID: Int64
    let title: String
    let description: String
    let payload: String
    let providerToken: String
    let currency: String
    let prices: [TelegramLabeledPrice]

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case title
        case description
        case payload
        case providerToken = "provider_token"
        case currency
        case prices
    }
}

struct TelegramLabeledPrice: Content {
    let label: String
    let amount: Int
}

struct TelegramAnswerPreCheckoutQueryRequest: Content {
    let preCheckoutQueryID: String
    let ok: Bool
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case preCheckoutQueryID = "pre_checkout_query_id"
        case ok
        case errorMessage = "error_message"
    }
}

struct TelegramSendLocationRequest: Content {
    let chatID: Int64
    let latitude: Double
    let longitude: Double
    let title: String?
    let address: String?

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case latitude
        case longitude
        case title
        case address
    }
}

struct TelegramGetFileRequest: Content {
    let fileID: String

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
    }
}

struct TelegramFile: Content {
    let filePath: String?

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
    }
}

struct TelegramGetFileResponse: Content {
    let ok: Bool
    let result: TelegramFile?
}

struct TelegramSetMyCommandsRequest: Content {
    let commands: [TelegramBotCommand]

    enum CodingKeys: String, CodingKey {
        case commands
    }
}

struct TelegramBotCommand: Content {
    let command: String
    let description: String
}

struct TelegramBotClient {
    let app: Application
    let botToken: String

    func setMyCommands(logger: Logger) async throws {
        let uri = "https://api.telegram.org/bot\(botToken)/setMyCommands"
        let request = TelegramSetMyCommandsRequest(commands: [
            TelegramBotCommand(command: "start", description: "Открыть каталог"),
            TelegramBotCommand(command: "menu", description: "Открыть каталог")
        ])
        let response = try await app.client.post(URI(string: uri)) { req in
            try req.content.encode(request)
        }

        guard response.status == .ok else {
            logger.error("telegram setMyCommands failed", metadata: [
                "status": "\(response.status.code)",
                "reason": "\(response.status.reasonPhrase)"
            ])
            return
        }
    }

    /// Отправляет сообщение. Возвращает true, если Telegram принял запрос.
    @discardableResult
    func sendMessage(_ request: TelegramSendMessageRequest, logger: Logger) async throws -> Bool {
        let delivered = try await withTimeout(seconds: 8) {
            let uri = "https://api.telegram.org/bot\(botToken)/sendMessage"
            let response = try await app.client.post(URI(string: uri)) { req in
                try req.content.encode(request)
            }
            guard response.status == .ok else {
                logger.error("telegram sendMessage failed", metadata: [
                    "status": "\(response.status.code)",
                    "reason": "\(response.status.reasonPhrase)"
                ])
                return false
            }
            return true
        }
        return delivered ?? false
    }

    func answerCallbackQuery(_ request: TelegramAnswerCallbackQueryRequest, logger: Logger) async throws {
        let uri = "https://api.telegram.org/bot\(botToken)/answerCallbackQuery"
        let response = try await app.client.post(URI(string: uri)) { req in
            try req.content.encode(request)
        }

        guard response.status == .ok else {
            logger.error("telegram answerCallbackQuery failed", metadata: [
                "status": "\(response.status.code)",
                "reason": "\(response.status.reasonPhrase)"
            ])
            return
        }
    }

    func sendInvoice(_ request: TelegramSendInvoiceRequest, logger: Logger) async throws {
        _ = try await withTimeout(seconds: 8) {
            let uri = "https://api.telegram.org/bot\(botToken)/sendInvoice"
            let response = try await app.client.post(URI(string: uri)) { req in
                try req.content.encode(request)
            }

            guard response.status == .ok else {
                logger.error("telegram sendInvoice failed", metadata: [
                    "status": "\(response.status.code)",
                    "reason": "\(response.status.reasonPhrase)"
                ])
                return
            }
        }
    }

    func answerPreCheckoutQuery(_ request: TelegramAnswerPreCheckoutQueryRequest, logger: Logger) async throws {
        let uri = "https://api.telegram.org/bot\(botToken)/answerPreCheckoutQuery"
        let response = try await app.client.post(URI(string: uri)) { req in
            try req.content.encode(request)
        }

        guard response.status == .ok else {
            logger.error("telegram answerPreCheckoutQuery failed", metadata: [
                "status": "\(response.status.code)",
                "reason": "\(response.status.reasonPhrase)"
            ])
            return
        }
    }

    /// Resolves a Telegram file_id to a downloadable file URL via getFile.
    /// Returns nil when the file cannot be resolved (bot token missing, bad id, etc.).
    func resolveFileURL(_ fileID: String, logger: Logger) async throws -> String? {
        if let cached = await PhotoURLCache.shared.get(fileID) {
            return cached
        }

        let path = try await withTimeout(seconds: 8) {
            let uri = "https://api.telegram.org/bot\(botToken)/getFile"
            let response = try await app.client.post(URI(string: uri)) { req in
                try req.content.encode(TelegramGetFileRequest(fileID: fileID))
            }

            guard response.status == .ok else {
                logger.error("telegram getFile failed", metadata: [
                    "status": "\(response.status.code)",
                    "reason": "\(response.status.reasonPhrase)"
                ])
                return nil as String?
            }
            let decoded = try response.content.decode(TelegramGetFileResponse.self)
            return decoded.result?.filePath
        }
        guard let path = path, let resolved = path, !resolved.isEmpty else { return nil }
        let url = "https://api.telegram.org/file/bot\(botToken)/\(resolved)"
        await PhotoURLCache.shared.set(fileID, url)
        return url
    }
}
