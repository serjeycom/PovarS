import Fluent
import Vapor

final class Address: Model, @unchecked Sendable {
    static let schema = "addresses"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "name")
    var name: String

    @OptionalField(key: "latitude")
    var latitude: Double?

    @OptionalField(key: "longitude")
    var longitude: Double?

    @Field(key: "text")
    var text: String

    @OptionalField(key: "is_default")
    var isDefault: Bool?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, userID: UUID, name: String, latitude: Double?, longitude: Double?, text: String, isDefault: Bool? = nil) {
        self.id = id
        self.$user.id = userID
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.text = text
        self.isDefault = isDefault
    }
}

struct CreateAddress: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(Address.schema)
            .id()
            .field("user_id", .uuid, .references(User.schema, .id))
            .field("name", .string)
            .field("latitude", .double)
            .field("longitude", .double)
            .field("text", .string)
            .field("is_default", .bool)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(Address.schema).delete()
    }
}