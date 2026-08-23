import Fluent

struct AddBonusAwardedToOrder: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(Order.schema)
            .field("bonus_awarded", .bool)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(Order.schema)
            .deleteField("bonus_awarded")
            .update()
    }
}
