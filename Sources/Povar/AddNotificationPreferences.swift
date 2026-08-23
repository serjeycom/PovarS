import Fluent

struct AddNotificationPreferences: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(User.schema)
            .field("notifications_enabled", .bool)
            .update()
        try await database.schema(User.schema)
            .field("quiet_hours_start", .int)
            .update()
        try await database.schema(User.schema)
            .field("quiet_hours_end", .int)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(User.schema)
            .deleteField("notifications_enabled")
            .deleteField("quiet_hours_start")
            .deleteField("quiet_hours_end")
            .update()
    }
}
