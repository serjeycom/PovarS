import Fluent

struct CreateOrder: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(Order.schema)
            .id()
            .field("client_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("cook_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("dish_id", .uuid, .references(Dish.schema, .id, onDelete: .setNull))
            .field("status", .string, .required)
            .field("total_price", .double, .required)
            .field("comment", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(Order.schema).delete()
    }
}
