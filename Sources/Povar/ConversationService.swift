import Fluent
import Foundation

// MARK: - ConversationService: состояние диалога (FSM)
struct ConversationService {
    static func getState(for telegramID: Int64, on db: Database) async throws -> ConversationState? {
        try await ConversationState.query(on: db)
            .filter(\.$telegramID == telegramID)
            .first()
    }

    static func startAddDish(for telegramID: Int64, on db: Database) async throws {
        if let existing = try await getState(for: telegramID, on: db) {
            existing.step = ConversationStep.waitingDishTitle.rawValue
            existing.draftTitle = nil
            existing.draftDetails = nil
            existing.draftDishID = nil
            try await existing.save(on: db)
            return
        }

        let state = ConversationState(telegramID: telegramID, step: .waitingDishTitle)
        try await state.save(on: db)
    }

    static func startOrderComment(for telegramID: Int64, dishID: UUID, on db: Database) async throws {
        let state = try await getState(for: telegramID, on: db)
            ?? ConversationState(telegramID: telegramID, step: .waitingOrderComment)
        state.step = ConversationStep.waitingOrderComment.rawValue
        state.draftTitle = nil
        state.draftDetails = nil
        state.draftDishID = dishID.uuidString
        try await state.save(on: db)
    }

    static func startEditDish(for telegramID: Int64, dishID: UUID, on db: Database) async throws {
        let state = try await getState(for: telegramID, on: db)
            ?? ConversationState(telegramID: telegramID, step: .waitingEditTitle)
        state.step = ConversationStep.waitingEditTitle.rawValue
        state.draftTitle = nil
        state.draftDetails = nil
        state.draftDishID = dishID.uuidString
        try await state.save(on: db)
    }

    static func clear(for telegramID: Int64, on db: Database) async throws {
        if let state = try await getState(for: telegramID, on: db) {
            try await state.delete(on: db)
        }
    }

    static func startPickupSchedule(for telegramID: Int64, on db: Database) async throws {
        let state = try await getState(for: telegramID, on: db)
            ?? ConversationState(telegramID: telegramID, step: .waitingPickupSchedule)
        state.step = ConversationStep.waitingPickupSchedule.rawValue
        state.draftTitle = nil
        state.draftDetails = nil
        state.draftDishID = nil
        try await state.save(on: db)
    }

    static func startOrderWindow(for telegramID: Int64, orderID: UUID, on db: Database) async throws {
        let state = try await getState(for: telegramID, on: db)
            ?? ConversationState(telegramID: telegramID, step: .waitingOrderWindow)
        state.step = ConversationStep.waitingOrderWindow.rawValue
        state.draftTitle = nil
        state.draftDetails = nil
        state.draftDishID = orderID.uuidString
        try await state.save(on: db)
    }

    static func startPickupTime(for telegramID: Int64, orderID: UUID, on db: Database) async throws {
        let state = try await getState(for: telegramID, on: db)
            ?? ConversationState(telegramID: telegramID, step: .waitingPickupTime)
        state.step = ConversationStep.waitingPickupTime.rawValue
        state.draftTitle = nil
        state.draftDetails = nil
        state.draftDishID = orderID.uuidString
        try await state.save(on: db)
    }

    static func startAddress(for telegramID: Int64, dishID: UUID?, on db: Database) async throws {
        let state = try await getState(for: telegramID, on: db)
            ?? ConversationState(telegramID: telegramID, step: .waitingAddress)
        state.step = ConversationStep.waitingAddress.rawValue
        state.draftTitle = nil
        state.draftDetails = nil
        state.draftDishID = dishID?.uuidString
        try await state.save(on: db)
    }

    static func startDishPhoto(for telegramID: Int64, dishID: UUID, on db: Database) async throws {
        let state = try await getState(for: telegramID, on: db)
            ?? ConversationState(telegramID: telegramID, step: .waitingDishPhoto)
        state.step = ConversationStep.waitingDishPhoto.rawValue
        state.draftTitle = nil
        state.draftDetails = nil
        state.draftDishID = dishID.uuidString
        try await state.save(on: db)
    }

    static func startPortions(for telegramID: Int64, dishID: UUID, on db: Database) async throws {
        let state = try await getState(for: telegramID, on: db)
            ?? ConversationState(telegramID: telegramID, step: .waitingPortions)
        state.step = ConversationStep.waitingPortions.rawValue
        state.draftTitle = nil
        state.draftDetails = nil
        state.draftDishID = dishID.uuidString
        try await state.save(on: db)
    }

    static func startSurpriseBudget(for telegramID: Int64, budget: String?, on db: Database) async throws {
        let state = try await getState(for: telegramID, on: db)
            ?? ConversationState(telegramID: telegramID, step: .waitingSurpriseBudget)
        state.step = ConversationStep.waitingSurpriseBudget.rawValue
        state.draftTitle = budget
        state.draftDetails = nil
        state.draftDishID = nil
        try await state.save(on: db)
    }

    static func startCookingDays(for telegramID: Int64, on db: Database) async throws {
        let state = try await getState(for: telegramID, on: db)
            ?? ConversationState(telegramID: telegramID, step: .waitingCookingDays)
        state.step = ConversationStep.waitingCookingDays.rawValue
        state.draftTitle = nil
        state.draftDetails = nil
        state.draftDishID = nil
        try await state.save(on: db)
    }

    static func startReviewText(for telegramID: Int64, orderID: UUID, on db: Database) async throws {
        let state = try await getState(for: telegramID, on: db)
            ?? ConversationState(telegramID: telegramID, step: .waitingReviewText)
        state.step = ConversationStep.waitingReviewText.rawValue
        state.draftTitle = nil
        state.draftDetails = nil
        state.draftDishID = orderID.uuidString
        try await state.save(on: db)
    }

    static func startOrderQuantity(for telegramID: Int64, dishID: UUID, on db: Database) async throws {
        let state = try await getState(for: telegramID, on: db)
            ?? ConversationState(telegramID: telegramID, step: .waitingOrderQuantity)
        state.step = ConversationStep.waitingOrderQuantity.rawValue
        state.draftTitle = nil
        state.draftDetails = nil
        state.draftDishID = dishID.uuidString
        try await state.save(on: db)
    }

    static func setQuantity(for telegramID: Int64, quantity: Int, on db: Database) async throws {
        guard let state = try await getState(for: telegramID, on: db) else { return }
        state.draftDetails = "\(quantity)"
        try await state.save(on: db)
    }

    static func getQuantity(for telegramID: Int64, on db: Database) async throws -> Int {
        let qty = try await getState(for: telegramID, on: db)?.draftDetails
        return Int(qty ?? "1").flatMap { (1...20).contains($0) ? $0 : nil } ?? 1
    }

    static func startAddressName(for telegramID: Int64, addressID: UUID?, on db: Database) async throws {
        let state = try await getState(for: telegramID, on: db)
            ?? ConversationState(telegramID: telegramID, step: .waitingAddressName)
        state.step = ConversationStep.waitingAddressName.rawValue
        state.draftTitle = addressID?.uuidString
        state.draftDetails = nil
        state.draftDishID = nil
        try await state.save(on: db)
    }

    static func startAddressText(for telegramID: Int64, addressID: UUID?, on db: Database) async throws {
        let state = try await getState(for: telegramID, on: db)
            ?? ConversationState(telegramID: telegramID, step: .waitingAddressText)
        state.step = ConversationStep.waitingAddressText.rawValue
        state.draftTitle = addressID?.uuidString
        state.draftDetails = nil
        state.draftDishID = nil
        try await state.save(on: db)
    }

    static func startOrderAddress(for telegramID: Int64, orderID: UUID, on db: Database) async throws {
        let state = try await getState(for: telegramID, on: db)
            ?? ConversationState(telegramID: telegramID, step: .waitingOrderAddress)
        state.step = ConversationStep.waitingOrderAddress.rawValue
        state.draftTitle = nil
        state.draftDetails = nil
        state.draftDishID = orderID.uuidString
        try await state.save(on: db)
    }

    static func startChatMessage(for telegramID: Int64, orderID: UUID, on db: Database) async throws {
        let state = try await getState(for: telegramID, on: db)
            ?? ConversationState(telegramID: telegramID, step: .waitingChatMessage)
        state.step = ConversationStep.waitingChatMessage.rawValue
        state.draftTitle = nil
        state.draftDetails = nil
        state.draftDishID = orderID.uuidString
        try await state.save(on: db)
    }

    static func startReviewPhoto(for telegramID: Int64, orderID: UUID, on db: Database) async throws {
        let state = try await getState(for: telegramID, on: db)
            ?? ConversationState(telegramID: telegramID, step: .waitingReviewPhoto)
        state.step = ConversationStep.waitingReviewPhoto.rawValue
        state.draftTitle = nil
        state.draftDetails = nil
        state.draftDishID = orderID.uuidString
        try await state.save(on: db)
    }

    static func startSearchKeyword(for telegramID: Int64, on db: Database) async throws {
        let state = try await getState(for: telegramID, on: db)
            ?? ConversationState(telegramID: telegramID, step: .waitingSearchKeyword)
        state.step = ConversationStep.waitingSearchKeyword.rawValue
        state.draftTitle = nil
        state.draftDetails = nil
        state.draftDishID = nil
        try await state.save(on: db)
    }

    static func startSearchMaxPrice(for telegramID: Int64, on db: Database) async throws {
        let state = try await getState(for: telegramID, on: db)
            ?? ConversationState(telegramID: telegramID, step: .waitingSearchMaxPrice)
        state.step = ConversationStep.waitingSearchMaxPrice.rawValue
        state.draftTitle = nil
        state.draftDetails = nil
        state.draftDishID = nil
        try await state.save(on: db)
    }

    static func startReferralCode(for telegramID: Int64, on db: Database) async throws {
        let state = try await getState(for: telegramID, on: db)
            ?? ConversationState(telegramID: telegramID, step: .waitingReferralCode)
        state.step = ConversationStep.waitingReferralCode.rawValue
        state.draftTitle = nil
        state.draftDetails = nil
        state.draftDishID = nil
        try await state.save(on: db)
    }

    static func startDishType(for telegramID: Int64, dishID: UUID, on db: Database) async throws {
        let state = try await getState(for: telegramID, on: db)
            ?? ConversationState(telegramID: telegramID, step: .waitingDishType)
        state.step = ConversationStep.waitingDishType.rawValue
        state.draftTitle = nil
        state.draftDetails = nil
        state.draftDishID = dishID.uuidString
        try await state.save(on: db)
    }

    // MARK: - Запуск шага «геолокация пункта забора»
    static func startOrderLocation(for telegramID: Int64, orderID: UUID, on db: Database) async throws {
        let state = try await getState(for: telegramID, on: db)
            ?? ConversationState(telegramID: telegramID, step: .waitingOrderLocation)
        state.step = ConversationStep.waitingOrderLocation.rawValue
        state.draftTitle = nil
        state.draftDetails = nil
        state.draftDishID = orderID.uuidString
        try await state.save(on: db)
    }

    static func startReport(for telegramID: Int64, orderID: UUID, on db: Database) async throws {
        let state = try await getState(for: telegramID, on: db)
            ?? ConversationState(telegramID: telegramID, step: .waitingReport)
        state.step = ConversationStep.waitingReport.rawValue
        state.draftTitle = nil
        state.draftDetails = nil
        state.draftDishID = orderID.uuidString
        try await state.save(on: db)
    }

    static func startVoiceComment(for telegramID: Int64, orderID: UUID, on db: Database) async throws {
        let state = try await getState(for: telegramID, on: db)
            ?? ConversationState(telegramID: telegramID, step: .waitingVoiceComment)
        state.step = ConversationStep.waitingVoiceComment.rawValue
        state.draftTitle = nil
        state.draftDetails = nil
        state.draftDishID = orderID.uuidString
        try await state.save(on: db)
    }

    static func startPromoCode(for telegramID: Int64, dishID: UUID, quantity: Int, on db: Database) async throws {
        let state = try await getState(for: telegramID, on: db)
            ?? ConversationState(telegramID: telegramID, step: .waitingPromoCode)
        state.step = ConversationStep.waitingPromoCode.rawValue
        state.draftTitle = nil
        state.draftDetails = "\(quantity)"
        state.draftDishID = dishID.uuidString
        try await state.save(on: db)
    }

    static func startPromoCreate(for telegramID: Int64, on db: Database) async throws {
        let state = try await getState(for: telegramID, on: db)
            ?? ConversationState(telegramID: telegramID, step: .waitingPromoCreate)
        state.step = ConversationStep.waitingPromoCreate.rawValue
        state.draftTitle = nil
        state.draftDetails = nil
        state.draftDishID = nil
        try await state.save(on: db)
    }
}
