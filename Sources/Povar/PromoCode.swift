import Fluent
import Vapor

final class PromoCode: Model, @unchecked Sendable {
    static let schema = "promo_codes"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "cook_id")
    var cook: User

    @Field(key: "code")
    var code: String

    @Field(key: "discount_percent")
    var discountPercent: Int

    @Field(key: "is_active")
    var isActive: Bool

    @Field(key: "uses_count")
    var usesCount: Int

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, cookID: UUID, code: String, discountPercent: Int, isActive: Bool = true) {
        self.id = id
        self.$cook.id = cookID
        self.code = code
        self.discountPercent = discountPercent
        self.isActive = isActive
        self.usesCount = 0
    }
}

struct CreatePromoCode: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(PromoCode.schema)
            .id()
            .field("cook_id", .uuid, .references(User.schema, .id))
            .field("code", .string)
            .field("discount_percent", .int)
            .field("is_active", .bool)
            .field("uses_count", .int)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(PromoCode.schema).delete()
    }
}
