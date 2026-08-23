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

struct TelegramSendMessageReplyKeyboardRequest: Content {
    let chatID: Int64
    let text: String
    let replyMarkup: TelegramReplyKeyboardMarkup

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
    let callbackData: String

    enum CodingKeys: String, CodingKey {
        case text
        case callbackData = "callback_data"
    }
}

struct TelegramReplyKeyboardMarkup: Content {
    let keyboard: [[TelegramKeyboardButton]]
    let resizeKeyboard: Bool
    let isPersistent: Bool
    let oneTimeKeyboard: Bool

    enum CodingKeys: String, CodingKey {
        case keyboard
        case resizeKeyboard = "resize_keyboard"
        case isPersistent = "is_persistent"
        case oneTimeKeyboard = "one_time_keyboard"
    }
}

struct TelegramKeyboardButton: Content {
    let text: String
    let requestLocation: Bool?
    let requestContact: Bool?

    enum CodingKeys: String, CodingKey {
        case text
        case requestLocation = "request_location"
        case requestContact = "request_contact"
    }

    init(text: String, requestLocation: Bool? = nil, requestContact: Bool? = nil) {
        self.text = text
        self.requestLocation = requestLocation
        self.requestContact = requestContact
    }
}

struct TelegramSendPhotoRequest: Content {
    let chatID: Int64
    let photo: String
    let caption: String?
    let replyMarkup: TelegramInlineKeyboardMarkup?

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case photo
        case caption
        case replyMarkup = "reply_markup"
    }
}

struct TelegramSendVoiceRequest: Content {
    let chatID: Int64
    let voice: String
    let caption: String?
    let replyMarkup: TelegramInlineKeyboardMarkup?

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case voice
        case caption
        case replyMarkup = "reply_markup"
    }
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
            TelegramBotCommand(command: "start", description: "Начать / выбрать роль"),
            TelegramBotCommand(command: "menu", description: "Открыть меню"),
            TelegramBotCommand(command: "cancel", description: "Отменить текущее действие")
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

    func sendMessage(_ request: TelegramSendMessageRequest, logger: Logger) async throws {
        let uri = "https://api.telegram.org/bot\(botToken)/sendMessage"
        let response = try await app.client.post(URI(string: uri)) { req in
            try req.content.encode(request)
        }

        guard response.status == .ok else {
            logger.error("telegram sendMessage failed", metadata: [
                "status": "\(response.status.code)",
                "reason": "\(response.status.reasonPhrase)"
            ])
            return
        }
    }

    func sendMessageWithReplyKeyboard(
        _ request: TelegramSendMessageReplyKeyboardRequest,
        logger: Logger
    ) async throws {
        let uri = "https://api.telegram.org/bot\(botToken)/sendMessage"
        let response = try await app.client.post(URI(string: uri)) { req in
            try req.content.encode(request)
        }

        guard response.status == .ok else {
            logger.error("telegram sendMessageWithReplyKeyboard failed", metadata: [
                "status": "\(response.status.code)",
                "reason": "\(response.status.reasonPhrase)"
            ])
            return
        }
    }

    func sendPhoto(_ request: TelegramSendPhotoRequest, logger: Logger) async throws {
        let uri = "https://api.telegram.org/bot\(botToken)/sendPhoto"
        let response = try await app.client.post(URI(string: uri)) { req in
            try req.content.encode(request)
        }

        guard response.status == .ok else {
            logger.error("telegram sendPhoto failed", metadata: [
                "status": "\(response.status.code)",
                "reason": "\(response.status.reasonPhrase)"
            ])
            return
        }
    }

    func sendVoice(_ request: TelegramSendVoiceRequest, logger: Logger) async throws {
        let uri = "https://api.telegram.org/bot\(botToken)/sendVoice"
        let response = try await app.client.post(URI(string: uri)) { req in
            try req.content.encode(request)
        }

        guard response.status == .ok else {
            logger.error("telegram sendVoice failed", metadata: [
                "status": "\(response.status.code)",
                "reason": "\(response.status.reasonPhrase)"
            ])
            return
        }
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

    func sendLocation(_ request: TelegramSendLocationRequest, logger: Logger) async throws {
        let uri = "https://api.telegram.org/bot\(botToken)/sendLocation"
        let response = try await app.client.post(URI(string: uri)) { req in
            try req.content.encode(request)
        }

        guard response.status == .ok else {
            logger.error("telegram sendLocation failed", metadata: [
                "status": "\(response.status.code)",
                "reason": "\(response.status.reasonPhrase)"
            ])
            return
        }
    }
}
