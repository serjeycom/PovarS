import Fluent

struct AddOrderBalanceAndVoiceAndPromo: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(Order.schema)
            .field("balance_used", .int, .sql(unsafeRaw: "DEFAULT 0"))
            .update()
        try await database.schema(Order.schema)
            .field("voice_note", .string)
            .update()
        try await database.schema(Order.schema)
            .field("promo_code", .string)
            .update()
        try await database.schema(Order.schema)
            .field("promo_discount", .double)
            .update()
        try await database.schema(Order.schema)
            .field("complaint_text", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(Order.schema)
            .deleteField("balance_used")
            .deleteField("voice_note")
            .deleteField("promo_code")
            .deleteField("promo_discount")
            .deleteField("complaint_text")
            .update()
    }
}
