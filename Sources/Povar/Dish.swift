import Fluent
import Vapor

final class Dish: Model, Content, @unchecked Sendable {
    static let schema = "dishes"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "cook_id")
    var cook: User

    @Field(key: "title")
    var title: String

    @OptionalField(key: "details")
    var details: String?

    @Field(key: "price")
    var price: Double

    @Field(key: "is_active")
    var isActive: Bool

    @OptionalField(key: "photo_file_id")
    var photoFileID: String?

    @OptionalField(key: "photo_path")
    var photoPath: String?

    @OptionalField(key: "cooked_date")
    var cookedDate: String?

    @OptionalField(key: "portions_total")
    var portionsTotal: Int?

    @OptionalField(key: "portions_left")
    var portionsLeft: Int?

    @OptionalField(key: "dish_type")
    var dishType: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        cookID: UUID,
        title: String,
        details: String?,
        price: Double,
        isActive: Bool = true
    ) {
        self.id = id
        self.$cook.id = cookID
        self.title = title
        self.details = details
        self.price = price
        self.isActive = isActive
    }
}
