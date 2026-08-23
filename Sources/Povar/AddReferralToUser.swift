import Fluent

struct AddReferralToUser: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(User.schema)
            .field("referral_code", .string)
            .update()
        try await database.schema(User.schema)
            .field("referred_by", .uuid)
            .update()
        try await database.schema(User.schema)
            .field("pending_referral", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(User.schema)
            .deleteField("referral_code")
            .deleteField("referred_by")
            .deleteField("pending_referral")
            .update()
    }
}
