import Vapor

/// Продукт с КБЖУ на 100 г (результат поиска в Open Food Facts).
struct NutritionProductDTO: Content {
    let name: String
    let brand: String?
    let code: String?
    let kcalPer100g: Double?
    let proteinPer100g: Double?
    let fatPer100g: Double?
    let carbsPer100g: Double?
}

/// Поиск КБЖУ продуктов через открытую базу Open Food Facts.
/// Без API-ключа, но требует внятный User-Agent и не любит частые запросы —
/// поэтому результаты кэшируются в памяти.
enum NutritionService {
    /// Кэш ответов: запрос → (дата, продукты). Живёт 6 часов.
    private actor Cache {
        static let shared = Cache()
        private var storage: [String: (date: Date, items: [NutritionProductDTO])] = [:]
        private let ttl: TimeInterval = 6 * 60 * 60
        private let maxCount = 200

        func get(_ key: String) -> [NutritionProductDTO]? {
            guard let entry = storage[key] else { return nil }
            guard Date().timeIntervalSince(entry.date) < ttl else {
                storage[key] = nil
                return nil
            }
            return entry.items
        }

        func set(_ key: String, _ items: [NutritionProductDTO]) {
            if storage.count >= maxCount { storage.removeAll() }
            storage[key] = (Date(), items)
        }
    }

    private static let userAgent = "Povar/1.0 (https://povar.serjey.com; contact@serjey.com)"

    /// Ищет продукты по названию. Возвращает только те, у которых есть хоть какие-то КБЖУ.
    static func search(query: String, client: Client, logger: Logger) async throws -> [NutritionProductDTO] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        let key = trimmed.lowercased()

        if let cached = await Cache.shared.get(key) {
            return cached
        }

        var components = URLComponents(string: "https://world.openfoodfacts.org/cgi/search.pl")!
        components.queryItems = [
            .init(name: "search_terms", value: trimmed),
            .init(name: "search_simple", value: "1"),
            .init(name: "action", value: "process"),
            .init(name: "json", value: "1"),
            .init(name: "page_size", value: "12"),
            .init(name: "fields", value: "product_name,brands,code,nutriments"),
        ]
        guard let urlString = components.url?.absoluteString else { return [] }

        // let, а не var: замыкание ниже выполняется параллельно и требует Sendable.
        // Ключи — обычные строки: HTTPHeaders принимает словарь [String: String].
        let headers: HTTPHeaders = [
            "User-Agent": userAgent,
            "Accept": "application/json",
        ]

        // У внешнего API нет гарантий по скорости — обрываем на 8 секундах.
        let response = try await withTimeout(seconds: 8) {
            try await client.get(URI(string: urlString), headers: headers)
        }
        guard let response, response.status == .ok, let body = response.body else {
            logger.warning("nutrition: no response for \(key)")
            return []
        }

        let decoded = try JSONDecoder().decode(OFFSearchResponse.self, from: Data(buffer: body))
        let items = decoded.products.compactMap { product -> NutritionProductDTO? in
            let name = (product.productName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let n = product.nutriments
            let kcal = n?.energyKcal100g ?? n?.energy100g.map { $0 / 4.184 }
            let protein = n?.proteins100g
            let fat = n?.fat100g
            let carbs = n?.carbohydrates100g
            // Продукты без единой цифры бесполезны.
            guard kcal != nil || protein != nil || fat != nil || carbs != nil else { return nil }
            return NutritionProductDTO(
                name: name,
                brand: (product.brands ?? "").trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                code: product.code,
                kcalPer100g: kcal.map { ($0 * 10).rounded() / 10 },
                proteinPer100g: protein.map { ($0 * 10).rounded() / 10 },
                fatPer100g: fat.map { ($0 * 10).rounded() / 10 },
                carbsPer100g: carbs.map { ($0 * 10).rounded() / 10 }
            )
        }

        await Cache.shared.set(key, items)
        return items
    }
}

private struct OFFSearchResponse: Decodable {
    let products: [OFFProduct]
}

private struct OFFProduct: Decodable {
    let productName: String?
    let brands: String?
    let code: String?
    let nutriments: OFFNutriments?

    enum CodingKeys: String, CodingKey {
        case productName = "product_name"
        case brands, code, nutriments
    }
}

private struct OFFNutriments: Decodable {
    let energyKcal100g: Double?
    let energy100g: Double?
    let proteins100g: Double?
    let fat100g: Double?
    let carbohydrates100g: Double?

    enum CodingKeys: String, CodingKey {
        case energyKcal100g = "energy-kcal_100g"
        case energy100g = "energy_100g"
        case proteins100g = "proteins_100g"
        case fat100g = "fat_100g"
        case carbohydrates100g = "carbohydrates_100g"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
