import Fluent

struct AddDraftDishIDToConversationState: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(ConversationState.schema)
            .field("draft_dish_id", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(ConversationState.schema)
            .deleteField("draft_dish_id")
            .update()
    }
}
