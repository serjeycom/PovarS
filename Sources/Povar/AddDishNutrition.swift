import Fluent

/// Добавляет поля КБЖУ (на 100 г) и вес порции к блюдам.
/// ВАЖНО: SQLite умеет добавлять только одну колонку за оператор,
/// поэтому каждая колонка — отдельный `.update()`.
struct AddDishNutrition: AsyncMigration {
    private let columns: [(String, DatabaseSchema.DataType)] = [
        ("calories_per_100g", .double),
        ("protein_per_100g", .double),
        ("fat_per_100g", .double),
        ("carbs_per_100g", .double),
        ("portion_weight_g", .int),
    ]

    func prepare(on database: Database) async throws {
        for (name, type) in columns {
            try await database.schema(Dish.schema)
                .field(.init(stringLiteral: name), type)
                .update()
        }
    }

    func revert(on database: Database) async throws {
        for (name, _) in columns {
            try await database.schema(Dish.schema)
                .deleteField(.init(stringLiteral: name))
                .update()
        }
    }
}
