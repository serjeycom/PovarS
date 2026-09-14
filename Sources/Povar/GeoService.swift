import Vapor

/// Найденный адрес.
struct GeoPlaceDTO: Content {
    let label: String
    let lat: Double
    let lon: Double
}

/// Маршрут по дорогам.
struct RouteDTO: Content {
    let distanceKm: Double
    let durationMin: Double
    /// Расстояние по прямой — чтобы показать разницу, если она существенная.
    let straightKm: Double
}

/// Геокодинг через OpenStreetMap Nominatim и маршруты через OSRM.
/// Оба сервиса бесплатные и без ключей, но у Nominatim жёсткое правило:
/// не чаще 1 запроса в секунду и обязательный User-Agent. Соблюдаем оба.
enum GeoService {
    private static let userAgent = "Povar/1.0 (https://povar.serjey.com; contact@serjey.com)"

    /// Кэш адресов + сериализация запросов к Nominatim.
    private actor Gate {
        static let shared = Gate()
        private var cache: [String: (date: Date, items: [GeoPlaceDTO])] = [:]
        private var lastRequest: Date = .distantPast
        private let ttl: TimeInterval = 24 * 60 * 60
        private let minInterval: TimeInterval = 1.05

        func cached(_ key: String) -> [GeoPlaceDTO]? {
            guard let entry = cache[key], Date().timeIntervalSince(entry.date) < ttl else {
                cache[key] = nil
                return nil
            }
            return entry.items
        }

        func store(_ key: String, _ items: [GeoPlaceDTO]) {
            if cache.count >= 300 { cache.removeAll() }
            cache[key] = (Date(), items)
        }

        /// Ждём, пока с прошлого запроса пройдёт секунда.
        func waitForSlot() async {
            let elapsed = Date().timeIntervalSince(lastRequest)
            if elapsed < minInterval {
                let need = minInterval - elapsed
                try? await Task.sleep(nanoseconds: UInt64(need * 1_000_000_000))
            }
            lastRequest = Date()
        }
    }

    // MARK: - Геокодинг адреса

    static func search(query: String, client: Client, logger: Logger) async throws -> [GeoPlaceDTO] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return [] }
        let key = "s:" + trimmed.lowercased()

        if let cached = await Gate.shared.cached(key) { return cached }
        await Gate.shared.waitForSlot()

        var components = URLComponents(string: "https://nominatim.openstreetmap.org/search")!
        components.queryItems = [
            .init(name: "q", value: trimmed),
            .init(name: "format", value: "jsonv2"),
            .init(name: "limit", value: "6"),
            .init(name: "addressdetails", value: "1"),
            .init(name: "accept-language", value: "ru"),
        ]
        guard let urlString = components.url?.absoluteString else { return [] }

        let items = try await fetch(urlString, client: client, logger: logger) { data in
            let raw = (try? JSONDecoder().decode([NominatimPlace].self, from: data)) ?? []
            return raw.compactMap { place -> GeoPlaceDTO? in
                guard let lat = Double(place.lat), let lon = Double(place.lon) else { return nil }
                return GeoPlaceDTO(label: shortLabel(place), lat: lat, lon: lon)
            }
        }

        await Gate.shared.store(key, items)
        return items
    }

    /// Обратный геокодинг: координаты → человекочитаемый адрес.
    static func reverse(lat: Double, lon: Double, client: Client, logger: Logger) async throws -> String? {
        let key = String(format: "r:%.4f,%.4f", lat, lon)
        if let cached = await Gate.shared.cached(key) { return cached.first?.label }
        await Gate.shared.waitForSlot()

        var components = URLComponents(string: "https://nominatim.openstreetmap.org/reverse")!
        components.queryItems = [
            .init(name: "lat", value: String(lat)),
            .init(name: "lon", value: String(lon)),
            .init(name: "format", value: "jsonv2"),
            .init(name: "accept-language", value: "ru"),
        ]
        guard let urlString = components.url?.absoluteString else { return nil }

        let places = try await fetch(urlString, client: client, logger: logger) { data -> [GeoPlaceDTO] in
            guard let raw = try? JSONDecoder().decode(NominatimPlace.self, from: data),
                  let plat = Double(raw.lat), let plon = Double(raw.lon) else { return [] }
            return [GeoPlaceDTO(label: shortLabel(raw), lat: plat, lon: plon)]
        }

        if let place = places.first { await Gate.shared.store(key, [place]) }
        return places.first?.label
    }

    // MARK: - Маршрут по дорогам

    static func route(
        fromLat: Double, fromLon: Double,
        toLat: Double, toLon: Double,
        client: Client, logger: Logger
    ) async throws -> RouteDTO? {
        let urlString = String(
            format: "https://router.project-osrm.org/route/v1/driving/%.6f,%.6f;%.6f,%.6f?overview=false",
            fromLon, fromLat, toLon, toLat
        )
        let headers: HTTPHeaders = ["User-Agent": userAgent]

        // withTimeout возвращает T?, поэтому внутри замыкания отдаём неопциональный тип.
        let route: OSRMRoute? = try await withTimeout(seconds: 8) { () -> OSRMRoute in
            let response = try await client.get(URI(string: urlString), headers: headers)
            guard response.status == .ok, let body = response.body else {
                throw Abort(.badGateway, reason: "OSRM недоступен")
            }
            let decoded = try JSONDecoder().decode(OSRMResponse.self, from: Data(buffer: body))
            guard let first = decoded.routes.first else {
                throw Abort(.badGateway, reason: "Маршрут не найден")
            }
            return first
        }

        guard let route else {
            logger.warning("geo: route timeout \(fromLat),\(fromLon) -> \(toLat),\(toLon)")
            return nil
        }
        return RouteDTO(
            distanceKm: (route.distance / 100).rounded() / 10,
            durationMin: (route.duration / 6).rounded() / 10,
            straightKm: (haversineKm(fromLat, fromLon, toLat, toLon) * 10).rounded() / 10
        )
    }

    // MARK: - Внутреннее

    /// Запрос к Nominatim с таймаутом. При любой сетевой проблеме отдаём пусто,
    /// чтобы подсказки адреса просто не появились, а не роняли запрос в 500.
    private static func fetch<T: Sendable>(
        _ urlString: String,
        client: Client,
        logger: Logger,
        decode: @Sendable (Data) throws -> T
    ) async throws -> T {
        let headers: HTTPHeaders = [
            "User-Agent": userAgent,
            "Accept": "application/json",
        ]
        do {
            let data: Data? = try await withTimeout(seconds: 8) { () -> Data in
                let response = try await client.get(URI(string: urlString), headers: headers)
                guard response.status == .ok, let body = response.body else {
                    throw Abort(.badGateway, reason: "Nominatim недоступен")
                }
                return Data(buffer: body)
            }
            guard let data else {
                logger.warning("geo: timeout for \(urlString)")
                return try decode(Data("[]".utf8))
            }
            return try decode(data)
        } catch {
            logger.warning("geo: failed \(urlString): \(error)")
            return try decode(Data("[]".utf8))
        }
    }

    /// Nominatim отдаёт длинную строку вида
    /// «Тверская, 12, Тверской район, Москва, ЦФО, Россия» — оставляем
    /// первые три значимые части, чтобы влезало в подсказку.
    private static func shortLabel(_ place: NominatimPlace) -> String {
        let parts = place.displayName
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "Россия" }
        return parts.prefix(3).joined(separator: ", ")
    }

    private static func haversineKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return r * 2 * asin(min(1, sqrt(a)))
    }
}

private struct NominatimPlace: Decodable {
    let lat: String
    let lon: String
    let displayName: String

    enum CodingKeys: String, CodingKey {
        case lat, lon
        case displayName = "display_name"
    }
}

private struct OSRMResponse: Decodable {
    let routes: [OSRMRoute]
}

private struct OSRMRoute: Decodable, Sendable {
    let distance: Double
    let duration: Double
}
