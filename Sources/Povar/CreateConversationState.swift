import Fluent

struct CreateConversationState: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(ConversationState.schema)
            .id()
            .field("telegram_id", .int64, .required)
            .field("step", .string, .required)
            .field("draft_title", .string)
            .field("draft_details", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "telegram_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(ConversationState.schema).delete()
    }
}
