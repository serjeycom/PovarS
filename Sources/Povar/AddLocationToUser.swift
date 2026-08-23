import Fluent

struct AddLocationToUser: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(User.schema)
            .field("latitude", .double)
            .update()
        try await database.schema(User.schema)
            .field("longitude", .double)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(User.schema)
            .deleteField("latitude")
            .deleteField("longitude")
            .update()
    }
}
