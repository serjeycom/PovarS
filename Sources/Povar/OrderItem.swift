import Fluent
import Vapor

final class OrderItem: Model, @unchecked Sendable {
    static let schema = "order_items"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "order_id")
    var order: Order

    @Parent(key: "dish_id")
    var dish: Dish

    @Field(key: "dish_title")
    var dishTitle: String

    @Field(key: "price")
    var price: Double

    @Field(key: "quantity")
    var quantity: Int

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, orderID: UUID, dishID: UUID, dishTitle: String, price: Double, quantity: Int) {
        self.id = id
        self.$order.id = orderID
        self.$dish.id = dishID
        self.dishTitle = dishTitle
        self.price = price
        self.quantity = quantity
    }
}

struct CreateOrderItem: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(OrderItem.schema)
            .id()
            .field("order_id", .uuid, .references(Order.schema, .id))
            .field("dish_id", .uuid, .references(Dish.schema, .id))
            .field("dish_title", .string)
            .field("price", .double)
            .field("quantity", .int)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(OrderItem.schema).delete()
    }
}
