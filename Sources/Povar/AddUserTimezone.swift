import Fluent

/// Часовой пояс пользователя (смещение от UTC в минутах) для корректных тихих часов.
struct AddUserTimezone: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(User.schema)
            .field("utc_offset_minutes", .int)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(User.schema)
            .deleteField("utc_offset_minutes")
            .update()
    }
}

/// Локальный файл фото профиля, загруженный из Mini App.
struct AddProfilePhotoPath: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(User.schema)
            .field("profile_photo_path", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(User.schema)
            .deleteField("profile_photo_path")
            .update()
    }
}
