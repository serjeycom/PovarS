import Fluent
import Foundation

enum ConversationStep: String, Codable {
    case waitingDishTitle
    case waitingDishDetails
    case waitingDishPrice
    case waitingOrderComment
    case waitingEditTitle
    case waitingEditDetails
    case waitingEditPrice
    case waitingPickupSchedule
    case waitingOrderWindow
    case waitingPickupTime
    case waitingAddress
    case waitingDishPhoto
    case waitingPortions
    case waitingSurpriseBudget
    case waitingCookingDays
    case waitingReviewText
    case waitingReviewPhoto
    case waitingOrderQuantity
    case waitingAddressName
    case waitingAddressText
    case waitingOrderAddress
    case waitingChatMessage
    case waitingSearchKeyword
    case waitingSearchMaxPrice
    case waitingReferralCode
    case waitingDishType
    case waitingOrderLocation
    case waitingReport
    case waitingVoiceComment
    case waitingPromoCode
    case waitingPromoCreate
}

final class ConversationState: Model, @unchecked Sendable {
    static let schema = "conversation_states"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "telegram_id")
    var telegramID: Int64

    @Field(key: "step")
    var step: String

    @OptionalField(key: "draft_title")
    var draftTitle: String?

    @OptionalField(key: "draft_details")
    var draftDetails: String?

    @OptionalField(key: "draft_dish_id")
    var draftDishID: String?

    @OptionalField(key: "draft_voice")
    var draftVoice: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        telegramID: Int64,
        step: ConversationStep,
        draftTitle: String? = nil,
        draftDetails: String? = nil,
        draftDishID: String? = nil
    ) {
        self.id = id
        self.telegramID = telegramID
        self.step = step.rawValue
        self.draftTitle = draftTitle
        self.draftDetails = draftDetails
        self.draftDishID = draftDishID
    }

    var typedStep: ConversationStep? {
        ConversationStep(rawValue: step)
    }
}
