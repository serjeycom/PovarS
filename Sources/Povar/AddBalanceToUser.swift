import Fluent

struct AddBalanceToUser: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(User.schema)
            .field("balance", .int, .sql(raw: "DEFAULT 0"))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(User.schema)
            .deleteField("balance")
            .update()
    }
}
