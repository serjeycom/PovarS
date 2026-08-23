import Fluent

struct AddSearchFiltersToUser: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(User.schema)
            .field("search_keyword", .string)
            .update()
        try await database.schema(User.schema)
            .field("search_max_price", .double)
            .update()
        try await database.schema(User.schema)
            .field("search_dish_type", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(User.schema)
            .deleteField("search_keyword")
            .deleteField("search_max_price")
            .deleteField("search_dish_type")
            .update()
    }
}
