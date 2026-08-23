import Fluent

struct AddDishPhotoAndCookStatus: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(Dish.schema)
            .field("photo_file_id", .string)
            .update()
        try await database.schema(User.schema)
            .field("is_accepting_orders", .bool)
            .update()
        try await database.schema(Order.schema)
            .field("pickup_reminder_sent", .bool)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(Dish.schema)
            .deleteField("photo_file_id")
            .update()
        try await database.schema(User.schema)
            .deleteField("is_accepting_orders")
            .update()
        try await database.schema(Order.schema)
            .deleteField("pickup_reminder_sent")
            .update()
    }
}
