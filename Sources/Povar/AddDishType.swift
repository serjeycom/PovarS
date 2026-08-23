import Fluent

struct AddDishType: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(Dish.schema)
            .field("dish_type", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(Dish.schema)
            .deleteField("dish_type")
            .update()
    }
}
