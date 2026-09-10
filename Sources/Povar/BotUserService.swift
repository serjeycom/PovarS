import Fluent
import Vapor

struct BotUserService {
    static func upsertFromTelegram(
        _ telegramUser: TelegramUser,
        on db: Database
    ) async throws -> User {
        if let existing = try await User.query(on: db)
            .filter(\.$telegramID == telegramUser.id)
            .first() {
            existing.firstName = telegramUser.firstName
            existing.lastName = telegramUser.lastName
            existing.username = telegramUser.username
            try await existing.save(on: db)
            return existing
        }

        let user = User(
            telegramID: telegramUser.id,
            firstName: telegramUser.firstName,
            lastName: telegramUser.lastName,
            username: telegramUser.username
        )
        try await user.save(on: db)
        return user
    }

    static func setRole(
        telegramUserID: Int64,
        role: UserRole,
        on db: Database
    ) async throws -> User {
        guard let user = try await User.query(on: db)
            .filter(\.$telegramID == telegramUserID)
            .first() else {
            throw Abort(.notFound, reason: "User not found")
        }

        user.role = role.rawValue
        try await user.save(on: db)
        return user
    }

    static func findByTelegramID(_ telegramUserID: Int64, on db: Database) async throws -> User? {
        try await User.query(on: db)
            .filter(\.$telegramID == telegramUserID)
            .first()
    }

    static func applyBonus(
        to userID: UUID,
        amount: Int,
        reason: String,
        on db: Database
    ) async throws {
        guard amount > 0, let user = try await User.find(userID, on: db) else { return }
        let current = user.balance ?? 0
        user.balance = current + amount
        try await user.save(on: db)
    }

    static func spendBalance(
        from userID: UUID,
        amount: Int,
        on db: Database
    ) async throws -> Bool {
        guard let user = try await User.find(userID, on: db) else { return false }
        let current = user.balance ?? 0
        guard current >= amount else { return false }
        user.balance = current - amount
        try await user.save(on: db)
        return true
    }
}
