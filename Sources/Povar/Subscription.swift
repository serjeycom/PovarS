import Fluent
import Vapor

final class Subscription: Model, @unchecked Sendable {
    static let schema = "subscriptions"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "client_id")
    var client: User

    @Parent(key: "cook_id")
    var cook: User

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, clientID: UUID, cookID: UUID) {
        self.id = id
        self.$client.id = clientID
        self.$cook.id = cookID
    }
}
