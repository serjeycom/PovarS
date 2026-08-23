import Fluent
import Foundation

final class WaitlistEntry: Model, @unchecked Sendable {
    static let schema = "waitlist_entries"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "dish_id")
    var dish: Dish

    @Parent(key: "client_id")
    var client: User

    @Field(key: "quantity")
    var quantity: Int

    @OptionalField(key: "notified")
    var notified: Bool?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, dishID: UUID, clientID: UUID, quantity: Int) {
        self.id = id
        self.$dish.id = dishID
        self.$client.id = clientID
        self.quantity = quantity
    }
}

struct CreateWaitlistEntry: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(WaitlistEntry.schema)
            .id()
            .field("dish_id", .uuid, .references(Dish.schema, .id))
            .field("client_id", .uuid, .references(User.schema, .id))
            .field("quantity", .int)
            .field("notified", .bool)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(WaitlistEntry.schema).delete()
    }
}
