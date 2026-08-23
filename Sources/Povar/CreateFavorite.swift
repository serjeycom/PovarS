import Fluent

struct CreateFavorite: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(Favorite.schema)
            .id()
            .field("client_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("dish_id", .uuid, .required, .references(Dish.schema, "id", onDelete: .cascade))
            .field("created_at", .datetime)
            .unique(on: "client_id", "dish_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(Favorite.schema).delete()
    }
}
