import Fluent

struct AddRatingToOrder: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(Order.schema)
            .field("rating", .int)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(Order.schema)
            .deleteField("rating")
            .update()
    }
}
