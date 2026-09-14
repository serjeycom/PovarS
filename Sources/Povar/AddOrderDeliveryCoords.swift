import Fluent

/// Координаты адреса доставки в заказе (нужны для расчёта маршрута).
/// SQLite добавляет по одной колонке за оператор.
struct AddOrderDeliveryCoords: AsyncMigration {
    private let columns = ["delivery_lat", "delivery_lon"]

    func prepare(on database: Database) async throws {
        for name in columns {
            try await database.schema(Order.schema)
                .field(.init(stringLiteral: name), .double)
                .update()
        }
    }

    func revert(on database: Database) async throws {
        for name in columns {
            try await database.schema(Order.schema)
                .deleteField(.init(stringLiteral: name))
                .update()
        }
    }
}
