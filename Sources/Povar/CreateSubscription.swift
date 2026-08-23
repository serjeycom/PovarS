import Fluent

struct CreateSubscription: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(Subscription.schema)
            .id()
            .field("client_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("cook_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("created_at", .datetime)
            .unique(on: "client_id", "cook_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(Subscription.schema).delete()
    }
}
