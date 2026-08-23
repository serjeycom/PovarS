import Fluent
import Vapor

final class Favorite: Model, @unchecked Sendable {
    static let schema = "favorites"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "client_id")
    var client: User

    @Parent(key: "dish_id")
    var dish: Dish

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, clientID: UUID, dishID: UUID) {
        self.id = id
        self.$client.id = clientID
        self.$dish.id = dishID
    }
}
