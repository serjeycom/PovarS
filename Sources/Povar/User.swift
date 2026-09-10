import Fluent
import Vapor

enum UserRole: String, Codable {
    case client
    case cook

    var title: String {
        switch self {
        case .client:
            return "Клиент"
        case .cook:
            return "Повар"
        }
    }
}

final class User: Model, Content, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "telegram_id")
    var telegramID: Int64

    @Field(key: "first_name")
    var firstName: String

    @OptionalField(key: "last_name")
    var lastName: String?

    @OptionalField(key: "username")
    var username: String?

    @OptionalField(key: "phone")
    var phone: String?

    @OptionalField(key: "role")
    var role: String?

    @OptionalField(key: "latitude")
    var latitude: Double?

    @OptionalField(key: "longitude")
    var longitude: Double?

    @OptionalField(key: "pickup_schedule")
    var pickupSchedule: String?

    @OptionalField(key: "address")
    var address: String?

    @OptionalField(key: "is_accepting_orders")
    var isAcceptingOrders: Bool?

    @OptionalField(key: "cooking_days")
    var cookingDays: String?

    @OptionalField(key: "balance")
    var balance: Int?

    @OptionalField(key: "referral_code")
    var referralCode: String?

    @OptionalField(key: "referred_by")
    var referredBy: UUID?

    @OptionalField(key: "pending_referral")
    var pendingReferral: String?

    @OptionalField(key: "search_keyword")
    var searchKeyword: String?

    @OptionalField(key: "search_max_price")
    var searchMaxPrice: Double?

    @OptionalField(key: "search_dish_type")
    var searchDishType: String?

    @OptionalField(key: "notifications_enabled")
    var notificationsEnabled: Bool?

    @OptionalField(key: "quiet_hours_start")
    var quietHoursStart: Int?

    @OptionalField(key: "quiet_hours_end")
    var quietHoursEnd: Int?

    @OptionalField(key: "city")
    var city: String?

    @OptionalField(key: "bio")
    var bio: String?

    @OptionalField(key: "specialization")
    var specialization: String?

    @OptionalField(key: "profile_photo_file_id")
    var profilePhotoFileID: String?

    @OptionalField(key: "profile_photo_path")
    var profilePhotoPath: String?

    @OptionalField(key: "utc_offset_minutes")
    var utcOffsetMinutes: Int?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        telegramID: Int64,
        firstName: String,
        lastName: String?,
        username: String?,
        phone: String? = nil,
        role: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        self.id = id
        self.telegramID = telegramID
        self.firstName = firstName
        self.lastName = lastName
        self.username = username
        self.phone = phone
        self.role = role
        self.latitude = latitude
        self.longitude = longitude
    }

    var typedRole: UserRole? {
        guard let role else { return nil }
        return UserRole(rawValue: role)
    }
}
