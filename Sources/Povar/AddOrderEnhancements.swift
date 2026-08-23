import Fluent

struct AddOrderEnhancements: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(Order.schema)
            .field("review_text", .string)
            .update()
        try await database.schema(Order.schema)
            .field("scheduled_date", .string)
            .update()
        try await database.schema(Order.schema)
            .field("payment_status", .string)
            .update()
        try await database.schema(Order.schema)
            .field("stars_amount", .int)
            .update()
        try await database.schema(Order.schema)
            .field("paid_at", .datetime)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(Order.schema)
            .deleteField("review_text")
            .deleteField("scheduled_date")
            .deleteField("payment_status")
            .deleteField("stars_amount")
            .deleteField("paid_at")
            .update()
    }
}
