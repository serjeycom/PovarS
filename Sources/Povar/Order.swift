import Fluent
import Vapor

enum OrderStatus: String, Codable {
    case new
    case accepted
    case cooking
    case ready
    case onTheWay
    case delivered
    case cancelled
}

final class Order: Model, Content, @unchecked Sendable {
    static let schema = "orders"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "client_id")
    var client: User

    @Parent(key: "cook_id")
    var cook: User

    @OptionalParent(key: "dish_id")
    var dish: Dish?

    @Field(key: "status")
    var status: String

    @Field(key: "total_price")
    var totalPrice: Double

    @OptionalField(key: "comment")
    var comment: String?

    @OptionalField(key: "rating")
    var rating: Int?

    @OptionalField(key: "pickup_window")
    var pickupWindow: String?

    @OptionalField(key: "pickup_time")
    var pickupTime: String?

    @OptionalField(key: "is_delivery")
    var isDelivery: Bool?

    @Field(key: "quantity")
    var quantity: Int

    @OptionalField(key: "pickup_reminder_sent")
    var pickupReminderSent: Bool?

    @OptionalField(key: "review_photo")
    var reviewPhoto: String?

    @OptionalField(key: "review_text")
    var reviewText: String?

    @OptionalField(key: "scheduled_date")
    var scheduledDate: String?

    @OptionalField(key: "shipping_address")
    var shippingAddress: String?

    @OptionalField(key: "reschedule_to")
    var rescheduleTo: String?

    @OptionalField(key: "payment_status")
    var paymentStatus: String?

    @OptionalField(key: "stars_amount")
    var starsAmount: Int?

    @OptionalField(key: "paid_at")
    var paidAt: Date?

    @OptionalField(key: "bonus_awarded")
    var bonusAwarded: Bool?

    @Field(key: "balance_used")
    var balanceUsed: Int

    @OptionalField(key: "voice_note")
    var voiceNote: String?

    @OptionalField(key: "promo_code")
    var promoCode: String?

    @OptionalField(key: "promo_discount")
    var promoDiscount: Double?

    @OptionalField(key: "complaint_text")
    var complaintText: String?

    @Children(for: \.$order)
    var items: [OrderItem]

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        clientID: UUID,
        cookID: UUID,
        dishID: UUID? = nil,
        status: OrderStatus = .new,
        totalPrice: Double,
        comment: String? = nil,
        quantity: Int = 1
    ) {
        self.id = id
        self.$client.id = clientID
        self.$cook.id = cookID
        self.$dish.id = dishID
        self.status = status.rawValue
        self.totalPrice = totalPrice
        self.comment = comment
        self.quantity = quantity
        self.balanceUsed = 0
    }

    var typedStatus: OrderStatus? {
        OrderStatus(rawValue: status)
    }
}
