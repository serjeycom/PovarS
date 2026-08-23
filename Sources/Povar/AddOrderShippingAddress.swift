import Fluent

struct AddOrderShippingAddress: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(Order.schema)
            .field("shipping_address", .string)
            .update()
        try await database.schema(Order.schema)
            .field("reschedule_to", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(Order.schema)
            .deleteField("shipping_address")
            .deleteField("reschedule_to")
            .update()
    }
}
