import Fluent

struct AddDraftVoiceToConversationState: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(ConversationState.schema)
            .field("draft_voice", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(ConversationState.schema)
            .deleteField("draft_voice")
            .update()
    }
}
