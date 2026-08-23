import Fluent

struct AddOrderQuantity: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(Order.schema)
            .field("quantity", .int, .sql(raw: "DEFAULT 1"))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(Order.schema)
            .deleteField("quantity")
            .update()
    }
}
