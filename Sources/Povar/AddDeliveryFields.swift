import Fluent

struct AddDeliveryFields: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(User.schema)
            .field("address", .string)
            .update()
        try await database.schema(Order.schema)
            .field("is_delivery", .bool)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(User.schema)
            .deleteField("address")
            .update()
        try await database.schema(Order.schema)
            .deleteField("is_delivery")
            .update()
    }
}
