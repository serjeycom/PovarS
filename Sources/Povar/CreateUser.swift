import Fluent

struct CreateUser: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(User.schema)
            .id()
            .field("telegram_id", .int64, .required)
            .field("first_name", .string, .required)
            .field("last_name", .string)
            .field("username", .string)
            .field("phone", .string)
            .field("role", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "telegram_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(User.schema).delete()
    }
}
