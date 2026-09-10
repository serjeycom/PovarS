import Fluent

/// Фото, загруженные из Mini App, хранятся локально в Public/uploads.
struct AddDishPhotoPath: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(Dish.schema)
            .field("photo_path", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(Dish.schema)
            .deleteField("photo_path")
            .update()
    }
}
