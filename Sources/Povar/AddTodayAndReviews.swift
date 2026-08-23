import Fluent

struct AddTodayAndReviews: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(Dish.schema)
            .field("cooked_date", .string)
            .update()
        try await database.schema(Dish.schema)
            .field("portions_total", .int)
            .update()
        try await database.schema(Dish.schema)
            .field("portions_left", .int)
            .update()
        try await database.schema(User.schema)
            .field("cooking_days", .string)
            .update()
        try await database.schema(Order.schema)
            .field("review_photo", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(Dish.schema)
            .deleteField("cooked_date")
            .update()
        try await database.schema(Dish.schema)
            .deleteField("portions_total")
            .update()
        try await database.schema(Dish.schema)
            .deleteField("portions_left")
            .update()
        try await database.schema(User.schema)
            .deleteField("cooking_days")
            .update()
        try await database.schema(Order.schema)
            .deleteField("review_photo")
            .update()
    }
}
