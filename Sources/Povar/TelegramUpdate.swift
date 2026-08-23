import Vapor

struct TelegramUpdate: Content {
    let updateID: Int
    let message: TelegramMessage?
    let callbackQuery: TelegramCallbackQuery?
    let preCheckoutQuery: TelegramPreCheckoutQuery?

    enum CodingKeys: String, CodingKey {
        case updateID = "update_id"
        case message
        case callbackQuery = "callback_query"
        case preCheckoutQuery = "pre_checkout_query"
    }
}

struct TelegramMessage: Content {
    let messageID: Int
    let from: TelegramUser?
    let chat: TelegramChat
    let date: Int
    let text: String?
    let location: TelegramLocation?
    let photo: [TelegramPhotoSize]?
    let contact: TelegramContact?
    let successfulPayment: TelegramSuccessfulPayment?
    let voice: TelegramVoice?

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case from
        case chat
        case date
        case text
        case location
        case photo
        case contact
        case successfulPayment = "successful_payment"
        case voice
    }
}

struct TelegramVoice: Content {
    let fileID: String
    let duration: Int

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case duration
    }
}

struct TelegramPreCheckoutQuery: Content {
    let id: String
    let from: TelegramUser
    let currency: String
    let totalAmount: Int
    let invoicePayload: String

    enum CodingKeys: String, CodingKey {
        case id
        case from
        case currency
        case totalAmount = "total_amount"
        case invoicePayload = "invoice_payload"
    }
}

struct TelegramSuccessfulPayment: Content {
    let currency: String
    let totalAmount: Int
    let invoicePayload: String
    let telegramPaymentChargeID: String

    enum CodingKeys: String, CodingKey {
        case currency
        case totalAmount = "total_amount"
        case invoicePayload = "invoice_payload"
        case telegramPaymentChargeID = "telegram_payment_charge_id"
    }
}

struct TelegramPhotoSize: Content {
    let fileID: String
    let width: Int
    let height: Int
    let fileSize: Int?

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case width
        case height
        case fileSize = "file_size"
    }
}

struct TelegramContact: Content {
    let phoneNumber: String
    let firstName: String
    let userID: Int64?

    enum CodingKeys: String, CodingKey {
        case phoneNumber = "phone_number"
        case firstName = "first_name"
        case userID = "user_id"
    }
}

struct TelegramLocation: Content {
    let latitude: Double
    let longitude: Double
}

struct TelegramUser: Content {
    let id: Int64
    let isBot: Bool
    let firstName: String
    let lastName: String?
    let username: String?

    enum CodingKeys: String, CodingKey {
        case id
        case isBot = "is_bot"
        case firstName = "first_name"
        case lastName = "last_name"
        case username
    }
}

struct TelegramChat: Content {
    let id: Int64
    let type: String
}

struct TelegramCallbackQuery: Content {
    let id: String
    let from: TelegramUser
    let message: TelegramMessage?
    let data: String?
}
