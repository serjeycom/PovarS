import Fluent

struct AddPickupFields: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(Order.schema)
            .field("pickup_window", .string)
            .update()
        try await database.schema(Order.schema)
            .field("pickup_time", .string)
            .update()
        try await database.schema(User.schema)
            .field("pickup_schedule", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(Order.schema)
            .deleteField("pickup_window")
            .update()
        try await database.schema(Order.schema)
            .deleteField("pickup_time")
            .update()
        try await database.schema(User.schema)
            .deleteField("pickup_schedule")
            .update()
    }
}
