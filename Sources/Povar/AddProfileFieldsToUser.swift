import Fluent

struct AddProfileFieldsToUser: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("users")
            .field("city", .string)
            .update()
        try await database.schema("users")
            .field("bio", .string)
            .update()
        try await database.schema("users")
            .field("specialization", .string)
            .update()
        try await database.schema("users")
            .field("profile_photo_file_id", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("users")
            .deleteField("city")
            .deleteField("bio")
            .deleteField("specialization")
            .deleteField("profile_photo_file_id")
            .update()
    }
}
