import Fluent

struct CreateDish: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(Dish.schema)
            .id()
            .field("cook_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("title", .string, .required)
            .field("details", .string)
            .field("price", .double, .required)
            .field("is_active", .bool, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(Dish.schema).delete()
    }
}
