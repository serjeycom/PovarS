import Fluent
import Vapor

final class CartItem: Model, @unchecked Sendable {
    static let schema = "cart_items"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "client_id")
    var client: User

    @Parent(key: "dish_id")
    var dish: Dish

    @Field(key: "quantity")
    var quantity: Int

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, clientID: UUID, dishID: UUID, quantity: Int) {
        self.id = id
        self.$client.id = clientID
        self.$dish.id = dishID
        self.quantity = quantity
    }
}

struct CreateCartItem: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(CartItem.schema)
            .id()
            .field("client_id", .uuid, .references(User.schema, .id))
            .field("dish_id", .uuid, .references(Dish.schema, .id))
            .field("quantity", .int)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(CartItem.schema).delete()
    }
}
