import Fluent
import Vapor
import Crypto

// MARK: - Authenticatable wrapper для telegram_id

struct MiniAppUserID: Authenticatable {
    let value: Int64
}

// MARK: - Auth Middleware

struct MiniAppAuthMiddleware: AsyncMiddleware {
    func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let initData = req.headers.first(name: "X-Telegram-Init-Data")
            ?? req.headers.first(name: "Authorization")?.replacingOccurrences(of: "tma ", with: "")
            ?? req.query[String.self, at: "initData"]
        if let data = initData, !data.isEmpty {
            let (userId, authDate) = try validateInitData(data)
            if Date().timeIntervalSince1970 - authDate > 86400 * 2 {
                throw Abort(.unauthorized, reason: "initData expired")
            }
            req.auth.login(MiniAppUserID(value: userId))
            return try await next.respond(to: req)
        }
        if let telegramId: Int64 = req.session.data["telegram_id"].flatMap({ Int64($0) }) {
            req.auth.login(MiniAppUserID(value: telegramId))
            return try await next.respond(to: req)
        }
        throw Abort(.unauthorized, reason: "Missing initData")
    }
}

/// Опциональная авторизация для публичных endpoint'ов (например, /browse):
/// если клиент передал initData — логиним его, чтобы персонализировать
/// ответ (расстояния, избранное); иначе отвечаем анонимно.
struct MiniAppOptionalAuthMiddleware: AsyncMiddleware {
    func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let initData = req.headers.first(name: "X-Telegram-Init-Data")
            ?? req.query[String.self, at: "initData"]
        if let data = initData, !data.isEmpty,
           let (userId, authDate) = try? validateInitData(data),
           Date().timeIntervalSince1970 - authDate <= 86400 * 2 {
            req.auth.login(MiniAppUserID(value: userId))
        } else if let telegramId: Int64 = req.session.data["telegram_id"].flatMap({ Int64($0) }) {
            req.auth.login(MiniAppUserID(value: telegramId))
        }
        return try await next.respond(to: req)
    }
}

// MARK: - Enriched dish with cook info (not a model, just a wrapper)

struct EnrichedDish {
    let dish: Dish
    let cookName: String
    let distance: Double?
    let rating: Double?
    let reviewCount: Int
    let isFavorite: Bool
}

// MARK: - MiniAppController

struct MiniAppController {
    private let app: Application

    init(app: Application) {
        self.app = app
    }

    func boot() {
        app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

        app.get("app") { req async throws -> Response in
            let path = req.application.directory.publicDirectory + "app/index.html"
            return try await req.fileio.asyncStreamFile(at: path)
        }

        app.get("auth", "telegram") { req async throws -> Response in
            let query: TelegramLoginQuery
            if let rawResult: String = req.query["tgAuthResult"] {
                query = try TelegramLoginQuery.fromtgAuthResult(rawResult)
            } else if let id: Int64 = req.query["id"], let authDate: String = req.query["auth_date"] {
                // Telegram Login Widget (data-onauth) передаёт параметры напрямую
                query = TelegramLoginQuery(
                    id: id,
                    first_name: req.query["first_name"],
                    last_name: req.query["last_name"],
                    username: req.query["username"],
                    photo_url: req.query["photo_url"],
                    auth_date: authDate,
                    hash: req.query["hash"] ?? ""
                )
            } else {
                throw Abort(.badRequest, reason: "Missing tgAuthResult")
            }
            let userId = try validateTelegramLogin(query)
            if try await User.query(on: req.db).filter(\.$telegramID == userId).first() == nil {
                let user = User(telegramID: userId, firstName: query.first_name ?? "User", lastName: nil, username: query.username)
                try await user.create(on: req.db)
            }
            req.session.data["telegram_id"] = String(userId)
            return req.redirect(to: "/app", redirectType: .normal)
        }

        app.get("auth", "logout") { req async throws -> Response in
            req.session.destroy()
            return req.redirect(to: "/", redirectType: .normal)
        }

        let publicApi = app.grouped("api", "v1")
        let personalizedApi = publicApi.grouped(MiniAppOptionalAuthMiddleware())
        personalizedApi.get("browse") { req async throws -> BrowseResponseDTO in
            try await self.browse(req)
        }

        publicApi.get("cities") { req async throws -> [String] in
            let cooks = try await User.query(on: req.db)
                .filter(\.$role == "cook")
                .all()
            let cities = Set(cooks.compactMap { $0.city }.filter { !$0.isEmpty })
            return Array(cities).sorted()
        }

        // Telegram photo proxy: resolves a file_id and streams the file
        publicApi.get("uploads", ":fileId") { req async throws -> Response in
            try await self.proxyPhoto(req)
        }

        let api = publicApi.grouped(MiniAppAuthMiddleware())

        api.get("me") { req async throws -> UserProfileDTO in
            try await self.getProfile(req)
        }

        api.put("me") { req async throws -> UserProfileDTO in
            try await self.updateProfile(req)
        }

        api.post("me", "photo") { req async throws -> UserProfileDTO in
            try await self.uploadProfilePhoto(req)
        }

        api.get("notification-settings") { req async throws -> NotificationSettingsDTO in
            try await self.getNotificationSettings(req)
        }

        api.put("notification-settings") { req async throws -> NotificationSettingsDTO in
            try await self.updateNotificationSettings(req)
        }

        api.get("dishes", ":id") { req async throws -> DishDTO in
            try await self.getDish(req)
        }

        api.post("dishes") { req async throws -> DishDTO in
            try await self.createDish(req)
        }

        // Cook tools
        api.get("my-dishes") { req async throws -> [DishDTO] in
            try await self.getMyDishes(req)
        }

        api.put("dishes", ":id") { req async throws -> DishDTO in
            try await self.updateDish(req)
        }

        api.delete("dishes", ":id") { req async throws -> HTTPStatus in
            try await self.deleteDish(req)
            return .ok
        }

        api.post("dishes", ":id", "today") { req async throws -> DishDTO in
            try await self.markDishToday(req)
        }

        api.post("dishes", ":id", "untoday") { req async throws -> DishDTO in
            try await self.unmarkDishToday(req)
        }

        api.post("dishes", ":id", "toggle") { req async throws -> DishDTO in
            try await self.toggleDish(req)
        }

        api.post("dishes", ":id", "photo") { req async throws -> DishDTO in
            try await self.uploadDishPhoto(req)
        }

        api.post("dishes", ":id", "waitlist") { req async throws -> HTTPStatus in
            try await self.toggleWaitlist(req)
            return .ok
        }

        api.post("orders", ":id", "rate") { req async throws -> OrderDTO in
            try await self.rateOrder(req)
        }

        api.get("cook-orders") { req async throws -> [OrderDTO] in
            try await self.getCookOrders(req)
        }

        api.post("orders", ":id", "status") { req async throws -> OrderDTO in
            try await self.updateOrderStatus(req)
        }

        api.get("promos") { req async throws -> [PromoDTO] in
            try await self.getPromos(req)
        }

        api.post("promos") { req async throws -> PromoDTO in
            try await self.createPromo(req)
        }

        api.post("promos", ":id", "toggle") { req async throws -> PromoDTO in
            try await self.togglePromo(req)
        }

        api.get("cook-stats") { req async throws -> CookStatsDTO in
            try await self.getCookStats(req)
        }

        api.post("cook", ":id", "subscribe") { req async throws -> HTTPStatus in
            try await self.subscribeToCook(req)
            return .ok
        }

        api.post("cook", ":id", "unsubscribe") { req async throws -> HTTPStatus in
            try await self.unsubscribeFromCook(req)
            return .ok
        }

        api.get("cart") { req async throws -> [CartItemDTO] in
            try await self.getCart(req)
        }

        api.post("cart") { req async throws -> CartItemDTO in
            try await self.addToCart(req)
        }

        api.put("cart", ":id") { req async throws -> CartItemDTO in
            try await self.updateCartItem(req)
        }

        api.delete("cart", ":id") { req async throws -> HTTPStatus in
            try await self.removeFromCart(req)
            return .ok
        }

        api.post("orders") { req async throws -> [OrderDTO] in
            try await self.createOrder(req)
        }

        api.get("orders") { req async throws -> [OrderDTO] in
            try await self.getOrders(req)
        }

        api.post("orders", ":id", "cancel") { req async throws -> OrderDTO in
            try await self.cancelOrder(req)
        }

        api.put("location") { req async throws -> HTTPStatus in
            try await self.updateLocation(req)
            return .ok
        }

        api.get("favorites") { req async throws -> [DishDTO] in
            try await self.getFavorites(req)
        }

        api.post("favorites", ":id") { req async throws -> HTTPStatus in
            try await self.toggleFavorite(req)
            return .ok
        }

        api.get("cook", ":id") { req async throws -> CookDTO in
            try await self.getCook(req)
        }

        // КБЖУ: поиск продукта в открытой базе Open Food Facts
        api.get("nutrition", "search") { req async throws -> [NutritionProductDTO] in
            try await self.searchNutrition(req)
        }

        // Адреса (Nominatim) и маршрут по дорогам (OSRM)
        api.get("geo", "search") { req async throws -> [GeoPlaceDTO] in
            try await self.searchAddress(req)
        }

        api.get("geo", "route") { req async throws -> RouteDTO in
            try await self.routeInfo(req)
        }

        // Маршрут повар → адрес доставки конкретного заказа
        api.get("orders", ":id", "route") { req async throws -> RouteDTO in
            try await self.orderRoute(req)
        }
    }

    // MARK: - Helpers

    private func getUser(_ req: Request) async throws -> (User, Int64) {
        let miniAppID = try req.auth.require(MiniAppUserID.self)
        guard let user = try await User.query(on: req.db)
            .filter(\.$telegramID == miniAppID.value)
            .first() else {
            throw Abort(.notFound, reason: "User not found")
        }
        return (user, miniAppID.value)
    }

    /// Расстояние по прямой от повара до адреса доставки (км).
    /// nil, если координаты доставки не сохранились (старые заказы).
    private func deliveryDistance(order: Order, cook: User?) -> Double? {
        guard let lat = order.deliveryLat, let lon = order.deliveryLon,
              let cookLat = cook?.latitude, let cookLon = cook?.longitude else { return nil }
        return (calculateDistance(lat1: cookLat, lon1: cookLon, lat2: lat, lon2: lon) * 10).rounded() / 10
    }

    private func calculateDistance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let R = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat/2) * sin(dLat/2) + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon/2) * sin(dLon/2)
        let c = 2 * atan2(sqrt(a), sqrt(1-a))
        return R * c
    }

    /// Streams a Telegram photo (by file_id) through the server so images work in the Mini App.
    private func proxyPhoto(_ req: Request) async throws -> Response {
        guard let fileId = req.parameters.get("fileId"), !fileId.isEmpty else {
            throw Abort(.badRequest, reason: "Missing file id")
        }
        guard let token = Environment.get("TELEGRAM_BOT_TOKEN"), !token.isEmpty else {
            throw Abort(.serviceUnavailable, reason: "Bot token not configured")
        }
        let tgClient = TelegramBotClient(app: app, botToken: token)
        guard let urlString = try await tgClient.resolveFileURL(fileId, logger: req.logger) else {
            throw Abort(.notFound, reason: "Photo not found")
        }
        let url = URI(string: urlString)
        let response = try await app.client.get(url)
        guard response.status == .ok, let body = response.body else {
            throw Abort(.notFound, reason: "Photo not found")
        }
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: response.headers.first(name: .contentType) ?? "image/jpeg")
        headers.add(name: .cacheControl, value: "public, max-age=86400")
        return Response(status: .ok, headers: headers, body: .init(buffer: body))
    }

    /// Собирает DishDTO из загруженных данных (без лишних запросов к БД).
    private func dishDTO(_ dish: Dish, cook: User?, rating: Double?, reviewCount: Int, distance: Double?, isFavorite: Bool) -> DishDTO {
        DishDTO(
            id: dish.id?.uuidString ?? "",
            title: dish.title,
            details: dish.details,
            price: dish.price,
            category: dish.dishType ?? "lunch",
            photoUrl: photoURL(path: dish.photoPath, fileID: dish.photoFileID),
            isToday: isToday(dish),
            portionsLeft: dish.portionsLeft,
            portionsTotal: dish.portionsTotal,
            cook: CookSummaryDTO(
                id: cook?.id?.uuidString ?? "",
                name: cook?.firstName ?? "Повар",
                rating: rating,
                reviewCount: reviewCount,
                distance: distance
            ),
            isFavorite: isFavorite,
            createdAt: dish.createdAt.map { ISO8601DateFormatter().string(from: $0) },
            nutrition: NutritionDTO.from(dish)
        )
    }

    private func enrichDish(_ dish: Dish, req: Request, favorites: Set<UUID> = []) async throws -> DishDTO {
        let cook = try await User.find(dish.$cook.id, on: req.db)
        let rating = try await calculateCookRating(cookID: dish.$cook.id, on: req.db)
        let reviewCount = try await Order.query(on: req.db)
            .filter(\.$cook.$id == dish.$cook.id)
            .filter(\.$reviewText != nil)
            .count()
        return dishDTO(dish, cook: cook, rating: rating, reviewCount: reviewCount, distance: nil, isFavorite: favorites.contains(dish.id ?? UUID()))
    }

    // MARK: - Browse

    private func browse(_ req: Request) async throws -> BrowseResponseDTO {
        let tgID: Int64? = try? req.auth.require(MiniAppUserID.self).value
        let category = req.query[String.self, at: "category"]
        let maxPrice = req.query[Double.self, at: "maxPrice"]
        let sort = req.query[String.self, at: "sort"] ?? "distance"
        let todayOnly = req.query[Bool.self, at: "todayOnly"] ?? false
        let photoOnly = req.query[Bool.self, at: "photoOnly"] ?? false
        let city = req.query[String.self, at: "city"]
        let keyword = req.query[String.self, at: "q"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let page = req.query[Int.self, at: "page"] ?? 0
        let limit = 20

        var userLat: Double? = nil
        var userLon: Double? = nil
        if let tgID {
            if let user = try await User.query(on: req.db).filter(\.$telegramID == tgID).first() {
                userLat = user.latitude
                userLon = user.longitude
            }
        }

        var q = Dish.query(on: req.db)
            .filter(\.$isActive == true)
        if let category, !category.isEmpty { q = q.filter(\.$dishType == category) }
        if let maxPrice { q = q.filter(\.$price <= maxPrice) }
        if photoOnly { q = q.filter(\.$photoFileID != nil) }

        var dishes = try await q.all()

        // Keyword search over title and details
        if let keyword, !keyword.isEmpty {
            let lowered = keyword.lowercased()
            dishes = dishes.filter { dish in
                dish.title.lowercased().contains(lowered)
                    || (dish.details ?? "").lowercased().contains(lowered)
            }
        }

        if let city, !city.isEmpty {
            let cookIDs = dishes.map { $0.$cook.id }
            let cooks = try await User.query(on: req.db)
                .filter(\.$id ~~ cookIDs)
                .filter(\.$city == city)
                .all()
            let cityCookIDs = Set(cooks.compactMap { $0.id })
            dishes = dishes.filter { dish in
                let cookID = dish.$cook.id
                return cityCookIDs.contains(cookID)
            }
        }

        if todayOnly {
            dishes = dishes.filter { isToday($0) }
        }

        // Build favorites set
        var favorites: Set<UUID> = []
        if let tgID,
           let user = try await User.query(on: req.db).filter(\.$telegramID == tgID).first(),
           let userID = user.id {
            let favs = try await Favorite.query(on: req.db).filter(\.$client.$id == userID).all()
            favorites = Set(favs.compactMap { $0.$dish.id })
        }

        // Batch-загрузка поваров, рейтингов и числа отзывов — без N+1 запросов
        let cookIDs = Array(Set(dishes.map { $0.$cook.id }))
        let cooks = try await User.query(on: req.db).filter(\.$id ~~ cookIDs).all()
        let cooksByID = Dictionary(uniqueKeysWithValues: cooks.compactMap { c in c.id.map { ($0, c) } })

        let ratedOrders = try await Order.query(on: req.db)
            .filter(\.$cook.$id ~~ cookIDs)
            .filter(\.$rating != nil)
            .all()
        var ratingSum: [UUID: Int] = [:]
        var ratingCount: [UUID: Int] = [:]
        for order in ratedOrders {
            let cid = order.$cook.id
            ratingSum[cid, default: 0] += order.rating ?? 0
            ratingCount[cid, default: 0] += 1
        }

        let reviewedOrders = try await Order.query(on: req.db)
            .filter(\.$cook.$id ~~ cookIDs)
            .filter(\.$reviewText != nil)
            .all()
        var reviewCounts: [UUID: Int] = [:]
        for order in reviewedOrders {
            reviewCounts[order.$cook.id, default: 0] += 1
        }

        // Enrich with cook info and distance
        var enriched: [(dto: DishDTO, distance: Double?)] = []
        for dish in dishes {
            let cook = cooksByID[dish.$cook.id]
            var distance: Double? = nil
            if let cookLat = cook?.latitude, let cookLon = cook?.longitude,
               let userLat, let userLon {
                distance = calculateDistance(lat1: userLat, lon1: userLon, lat2: cookLat, lon2: cookLon)
            }
            let count = ratingCount[dish.$cook.id] ?? 0
            let rating: Double? = count > 0 ? Double(ratingSum[dish.$cook.id] ?? 0) / Double(count) : nil
            let dto = dishDTO(
                dish,
                cook: cook,
                rating: rating,
                reviewCount: reviewCounts[dish.$cook.id] ?? 0,
                distance: distance,
                isFavorite: favorites.contains(dish.id ?? UUID())
            )
            enriched.append((dto, distance))
        }

        // Sort. "distance" falls back to newest when the user has no location.
        switch sort {
        case "price":
            enriched.sort { $0.dto.price < $1.dto.price }
        case "rating":
            enriched.sort { ($0.dto.cook.rating ?? 0) > ($1.dto.cook.rating ?? 0) }
        case "new":
            enriched.sort { ($0.dto.createdAt ?? "") > ($1.dto.createdAt ?? "") }
        default:
            if userLat != nil, userLon != nil {
                enriched.sort { ($0.distance ?? .infinity) < ($1.distance ?? .infinity) }
            } else {
                enriched.sort { ($0.dto.createdAt ?? "") > ($1.dto.createdAt ?? "") }
            }
        }

        let total = enriched.count
        let offset = page * limit
        let pageItems = offset < total ? Array(enriched[offset..<min(offset + limit, total)]) : []

        return BrowseResponseDTO(
            dishes: pageItems.map { $0.dto },
            page: page,
            hasPrev: page > 0,
            hasNext: (page + 1) * limit < total
        )
    }

    // MARK: - Profile

    private func getProfile(_ req: Request) async throws -> UserProfileDTO {
        let (user, _) = try await getUser(req)
        return try await self.profileDTO(for: user, on: req.db)
    }

    private func profileDTO(for user: User, on db: Database) async throws -> UserProfileDTO {
        let userID = user.id ?? UUID()
        let orderCount = try await Order.query(on: db)
            .filter(\.$client.$id == userID)
            .count()
        return UserProfileDTO(
            id: user.telegramID,
            firstName: user.firstName,
            username: user.username,
            role: user.role ?? "none",
            balance: user.balance ?? 0,
            referralCode: user.referralCode,
            ordersCount: orderCount,
            rating: nil,
            city: user.city,
            bio: user.bio,
            specialization: user.specialization,
            pickupSchedule: user.pickupSchedule,
            cookingDays: user.cookingDays,
            address: user.address,
            phone: user.phone,
            isAcceptingOrders: user.isAcceptingOrders ?? true,
            hasLocation: user.latitude != nil && user.longitude != nil,
            utcOffsetMinutes: user.utcOffsetMinutes,
            photoUrl: photoURL(path: user.profilePhotoPath, fileID: user.profilePhotoFileID)
        )
    }

    // MARK: - Dishes

    private func getDish(_ req: Request) async throws -> DishDTO {
        guard let id = req.parameters.get("id", as: UUID.self),
              let dish = try await Dish.find(id, on: req.db) else {
            throw Abort(.notFound)
        }
        return try await enrichDish(dish, req: req)
    }

    private func createDish(_ req: Request) async throws -> DishDTO {
        let (user, _) = try await getUser(req)
        guard user.typedRole == .cook else {
            throw Abort(.forbidden, reason: "Только повар может добавлять блюда")
        }
        let dto = try req.content.decode(CreateDishDTO.self)
        guard let userID = user.id else { throw Abort(.notFound) }
        let title = dto.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw Abort(.badRequest, reason: "Название блюда не может быть пустым")
        }
        guard dto.price > 0 else {
            throw Abort(.badRequest, reason: "Цена должна быть больше нуля")
        }

        let dish = Dish(
            cookID: userID,
            title: title,
            details: dto.details,
            price: dto.price,
            isActive: true
        )
        dish.dishType = dto.category
        dish.portionsTotal = dto.portionsTotal
        dish.portionsLeft = dto.portionsTotal
        dish.photoFileID = dto.photoFileId
        if dto.isToday == true {
            dish.cookedDate = formatDate(Date())
        }
        applyNutrition(
            to: dish,
            calories: dto.caloriesPer100g, protein: dto.proteinPer100g,
            fat: dto.fatPer100g, carbs: dto.carbsPer100g, portionWeight: dto.portionWeightG
        )

        try await dish.save(on: req.db)

        return try await enrichDish(dish, req: req)
    }

    /// Проставляет КБЖУ с валидацией: отрицательные значения и абсурдные
    /// калории отбрасываем, чтобы в базе не появилось «-5 ккал».
    private func applyNutrition(
        to dish: Dish,
        calories: Double?, protein: Double?, fat: Double?, carbs: Double?, portionWeight: Int?
    ) {
        func clean(_ value: Double?, max: Double) -> Double? {
            guard let value, value >= 0, value <= max else { return nil }
            return (value * 10).rounded() / 10
        }
        dish.caloriesPer100g = clean(calories, max: 900)
        dish.proteinPer100g = clean(protein, max: 100)
        dish.fatPer100g = clean(fat, max: 100)
        dish.carbsPer100g = clean(carbs, max: 100)
        if let portionWeight, portionWeight > 0, portionWeight <= 5000 {
            dish.portionWeightG = portionWeight
        } else {
            dish.portionWeightG = nil
        }
    }

    // MARK: - Cart

    private func getCart(_ req: Request) async throws -> [CartItemDTO] {
        let (user, _) = try await getUser(req)
        guard let userID = user.id else { throw Abort(.notFound) }
        let items = try await CartItem.query(on: req.db)
            .filter(\.$client.$id == userID)
            .with(\.$dish)
            .sort(\.$createdAt)
            .all()

        // Batch-загрузка поваров
        let cookIDs = Array(Set(items.map { $0.dish.$cook.id }))
        let cooks = try await User.query(on: req.db).filter(\.$id ~~ cookIDs).all()
        let cooksByID = Dictionary(uniqueKeysWithValues: cooks.compactMap { c in c.id.map { ($0, c) } })

        var result: [CartItemDTO] = []
        for item in items {
            let cook = cooksByID[item.dish.$cook.id]
            result.append(CartItemDTO(
                id: item.id?.uuidString ?? "",
                dishId: item.dish.id?.uuidString ?? "",
                dish: DishDTO(
                    id: item.dish.id?.uuidString ?? "",
                    title: item.dish.title,
                    details: item.dish.details,
                    price: item.dish.price,
                    category: item.dish.dishType ?? "lunch",
                    photoUrl: photoURL(path: item.dish.photoPath, fileID: item.dish.photoFileID),
                    isToday: isToday(item.dish),
                    portionsLeft: item.dish.portionsLeft,
                    portionsTotal: item.dish.portionsTotal,
                    cook: CookSummaryDTO(id: cook?.id?.uuidString ?? "", name: cook?.firstName ?? "Повар", rating: nil, reviewCount: 0, distance: nil),
                    isFavorite: false,
                    createdAt: nil,
                    nutrition: NutritionDTO.from(item.dish)
                ),
                quantity: item.quantity
            ))
        }
        return result
    }

    private func addToCart(_ req: Request) async throws -> CartItemDTO {
        let (user, _) = try await getUser(req)
        guard let userID = user.id else { throw Abort(.notFound) }
        let dto = try req.content.decode(AddToCartDTO.self)
        guard let dishID = UUID(uuidString: dto.dishId),
              let dish = try await Dish.find(dishID, on: req.db) else {
            throw Abort(.notFound, reason: "Dish not found")
        }

        if let existing = try await CartItem.query(on: req.db)
            .filter(\.$client.$id == userID)
            .filter(\.$dish.$id == dishID)
            .first() {
            existing.quantity += dto.quantity
            try await existing.save(on: req.db)
            let cook = try await User.find(dish.$cook.id, on: req.db)
            return CartItemDTO(
                id: existing.id?.uuidString ?? "",
                dishId: dishID.uuidString,
                dish: DishDTO(
                    id: dish.id?.uuidString ?? "",
                    title: dish.title,
                    details: dish.details,
                    price: dish.price,
                    category: dish.dishType ?? "lunch",
                    photoUrl: photoURL(path: dish.photoPath, fileID: dish.photoFileID),
                    isToday: isToday(dish),
                    portionsLeft: dish.portionsLeft,
                    portionsTotal: dish.portionsTotal,
                    cook: CookSummaryDTO(id: cook?.id?.uuidString ?? "", name: cook?.firstName ?? "Повар", rating: nil, reviewCount: 0, distance: nil),
                    isFavorite: false,
                    createdAt: nil,
                    nutrition: NutritionDTO.from(dish)
                ),
                quantity: existing.quantity
            )
        }

        let item = CartItem(clientID: userID, dishID: dishID, quantity: dto.quantity)
        try await item.save(on: req.db)
        let cook = try await User.find(dish.$cook.id, on: req.db)
        return CartItemDTO(
            id: item.id?.uuidString ?? "",
            dishId: dishID.uuidString,
            dish: DishDTO(
                id: dish.id?.uuidString ?? "",
                title: dish.title,
                details: dish.details,
                price: dish.price,
                category: dish.dishType ?? "lunch",
                photoUrl: photoURL(path: dish.photoPath, fileID: dish.photoFileID),
                isToday: isToday(dish),
                portionsLeft: dish.portionsLeft,
                portionsTotal: dish.portionsTotal,
                cook: CookSummaryDTO(id: cook?.id?.uuidString ?? "", name: cook?.firstName ?? "Повар", rating: nil, reviewCount: 0, distance: nil),
                isFavorite: false,
                createdAt: nil,
                nutrition: NutritionDTO.from(dish)
            ),
            quantity: dto.quantity
        )
    }

    private func updateCartItem(_ req: Request) async throws -> CartItemDTO {
        let (user, _) = try await getUser(req)
        guard let userID = user.id,
              let itemID = req.parameters.get("id", as: UUID.self),
              let item = try await CartItem.find(itemID, on: req.db),
              item.$client.id == userID else {
            throw Abort(.notFound)
        }
        let dto = try req.content.decode(UpdateCartItemDTO.self)
        guard dto.quantity >= 1, dto.quantity <= 20 else {
            throw Abort(.badRequest, reason: "Количество от 1 до 20")
        }
        item.quantity = dto.quantity
        try await item.save(on: req.db)

        let dishID = item.$dish.id
        let dish = try await Dish.find(dishID, on: req.db)
        let cookUser: User?
        if let dish {
            cookUser = try await User.find(dish.$cook.id, on: req.db)
        } else {
            cookUser = nil
        }

        return CartItemDTO(
            id: item.id?.uuidString ?? "",
            dishId: dishID.uuidString,
            dish: DishDTO(
                id: dish?.id?.uuidString ?? "",
                title: dish?.title ?? "",
                details: dish?.details,
                price: dish?.price ?? 0,
                category: dish?.dishType ?? "lunch",
                photoUrl: photoURL(path: dish?.photoPath, fileID: dish?.photoFileID),
                isToday: dish.map { isToday($0) } ?? false,
                portionsLeft: dish?.portionsLeft,
                portionsTotal: dish?.portionsTotal,
                cook: CookSummaryDTO(id: cookUser?.id?.uuidString ?? "", name: cookUser?.firstName ?? "Повар", rating: nil, reviewCount: 0, distance: nil),
                isFavorite: false,
                createdAt: nil,
                nutrition: dish.flatMap { NutritionDTO.from($0) }
            ),
            quantity: item.quantity
        )
    }

    private func removeFromCart(_ req: Request) async throws {
        let (user, _) = try await getUser(req)
        guard let userID = user.id,
              let itemID = req.parameters.get("id", as: UUID.self),
              let item = try await CartItem.find(itemID, on: req.db),
              item.$client.id == userID else {
            throw Abort(.notFound)
        }
        try await item.delete(on: req.db)
    }

    // MARK: - Orders

    private func createOrder(_ req: Request) async throws -> [OrderDTO] {
        let (user, _) = try await getUser(req)
        guard let userID = user.id else { throw Abort(.notFound) }
        let dto = try req.content.decode(CreateOrderDTO.self)

        // Сохраняем контактные данные, которые клиент ввёл при оформлении
        var userChanged = false
        if let phone = dto.phone?.trimmingCharacters(in: .whitespacesAndNewlines), !phone.isEmpty {
            user.phone = phone
            userChanged = true
        }
        if let address = dto.address?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty {
            user.address = address
            userChanged = true
        }
        if userChanged {
            try await user.save(on: req.db)
        }

        // Server-side cart is the source of truth; fall back to client items if cart is empty
        var cartItems = try await CartItem.query(on: req.db)
            .filter(\.$client.$id == userID)
            .with(\.$dish)
            .all()

        if cartItems.isEmpty, !dto.items.isEmpty {
            for item in dto.items {
                guard let dishID = UUID(uuidString: item.dishId),
                      let dish = try await Dish.find(dishID, on: req.db),
                      dish.isActive else { continue }
                let cartItem = CartItem(clientID: userID, dishID: dishID, quantity: max(item.quantity, 1))
                try await cartItem.save(on: req.db)
            }
            cartItems = try await CartItem.query(on: req.db)
                .filter(\.$client.$id == userID)
                .with(\.$dish)
                .all()
        }

        guard !cartItems.isEmpty else {
            throw Abort(.badRequest, reason: "Корзина пуста")
        }

        let isDelivery = dto.isDelivery ?? false
        if isDelivery, (user.address ?? "").isEmpty {
            throw Abort(.badRequest, reason: "Для доставки укажите адрес")
        }

        // Group by cook: one order per cook
        var grouped: [UUID: [CartItem]] = [:]
        for item in cartItems {
            grouped[item.dish.$cook.id, default: []].append(item)
        }

        // Validate before creating anything
        for (_, group) in grouped {
            for item in group {
                let dish = item.dish
                guard dish.isActive else {
                    throw Abort(.badRequest, reason: "Блюдо «\(dish.title)» больше недоступно")
                }
                if isToday(dish), let left = dish.portionsLeft, left < item.quantity {
                    throw Abort(.badRequest, reason: "Не хватает порций блюда «\(dish.title)»: осталось \(left)")
                }
            }
        }

        var tgClient: TelegramBotClient? = nil
        if let token = Environment.get("TELEGRAM_BOT_TOKEN"), !token.isEmpty {
            tgClient = TelegramBotClient(app: app, botToken: token)
        }

        var created: [OrderDTO] = []

        for (cookID, group) in grouped {
            guard let cook = try await User.find(cookID, on: req.db) else { continue }
            guard cook.typedRole == .cook else {
                throw Abort(.badRequest, reason: "Повар \(cook.firstName) больше не принимает заказы")
            }
            guard cook.isAcceptingOrders != false else {
                throw Abort(.badRequest, reason: "Повар \(cook.firstName) сейчас не принимает заказы")
            }

            let totalPrice = group.reduce(0.0) { $0 + $1.dish.price * Double($1.quantity) }
            let totalQuantity = group.reduce(0) { $0 + $1.quantity }

            let order = Order(
                clientID: userID,
                cookID: cookID,
                dishID: group.first?.dish.id,
                totalPrice: totalPrice,
                comment: dto.comment,
                quantity: totalQuantity
            )
            order.isDelivery = isDelivery
            if isDelivery {
                order.shippingAddress = user.address
                // Координаты выбранного адреса — чтобы потом посчитать маршрут
                if let lat = dto.addressLat, let lon = dto.addressLon,
                   (-90...90).contains(lat), (-180...180).contains(lon) {
                    order.deliveryLat = lat
                    order.deliveryLon = lon
                }
            }
            try await order.save(on: req.db)
            guard let orderID = order.id else { continue }

            var itemDTOs: [OrderItemDTO] = []
            for item in group {
                let dish = item.dish
                let orderItem = OrderItem(
                    orderID: orderID,
                    dishID: dish.id ?? UUID(),
                    dishTitle: dish.title,
                    price: dish.price,
                    quantity: item.quantity
                )
                try await orderItem.save(on: req.db)
                itemDTOs.append(OrderItemDTO(dishId: dish.id?.uuidString ?? "", title: dish.title, price: dish.price, quantity: item.quantity))

                // Reserve portions for "today" dishes
                if isToday(dish), let left = dish.portionsLeft, left >= item.quantity {
                    dish.portionsLeft = left - item.quantity
                    try await dish.save(on: req.db)
                }
            }

            // Уведомляем повара и отправляем клиенту инвойс оплаты звёздами
            if let tgClient {
                let dishList = group.map { "• \($0.dish.title) × \($0.quantity)" }.joined(separator: "\n")
                let deliveryLine = isDelivery ? "Доставка" : "Самовывоз"
                let addressLine = isDelivery ? "\nАдрес: \(user.address ?? "не указан")" : ""
                let phoneLine = user.phone.map { "\nТелефон: \($0)" } ?? ""
                let commentLine = dto.comment.map { "\nКомментарий: \($0)" } ?? ""
                let cookText = "🛒 Новый заказ из каталога!\n\(dishList)\nКлиент: \(user.firstName)\nСумма: \(formatPrice(totalPrice))₽\nСпособ: \(deliveryLine)\(addressLine)\(phoneLine)\(commentLine)"
                try? await tgClient.sendMessage(
                    TelegramSendMessageRequest(chatID: cook.telegramID, text: cookText, replyMarkup: nil),
                    logger: req.logger
                )
                // Инвойс оплаты звёздами — в чат клиента с ботом
                let invoiceTitle = group.count == 1
                    ? "Заказ «\(group.first?.dish.title ?? "Блюдо")»"
                    : "Заказ из \(group.count) блюд"
                try? await sendOrderInvoice(
                    order: order,
                    title: invoiceTitle,
                    chatID: user.telegramID,
                    client: tgClient,
                    logger: req.logger
                )
            }

            created.append(OrderDTO(
                id: orderID.uuidString,
                dish: nil,
                cook: CookSummaryDTO(id: cook.id?.uuidString ?? "", name: cook.firstName, rating: nil, reviewCount: 0, distance: nil),
                client: nil,
                quantity: totalQuantity,
                totalPrice: order.totalPrice,
                status: order.status,
                comment: order.comment,
                createdAt: order.createdAt.map { ISO8601DateFormatter().string(from: $0) },
                items: itemDTOs,
                isDelivery: order.isDelivery,
                address: order.isDelivery == true ? order.shippingAddress : nil,
                deliveryLat: order.deliveryLat,
                deliveryLon: order.deliveryLon,
                distanceKm: deliveryDistance(order: order, cook: cook)
            ))
        }

        // Clear the cart only after all orders are created
        try await CartItem.query(on: req.db)
            .filter(\.$client.$id == userID)
            .delete()

        return created
    }

    private func cancelOrder(_ req: Request) async throws -> OrderDTO {
        let (user, _) = try await getUser(req)
        guard let userID = user.id,
              let orderID = req.parameters.get("id", as: UUID.self),
              let order = try await Order.find(orderID, on: req.db),
              order.$client.id == userID else {
            throw Abort(.notFound, reason: "Заказ не найден")
        }
        guard isClientCancelable(order: order) else {
            throw Abort(.badRequest, reason: "Этот заказ уже нельзя отменить")
        }
        order.status = OrderStatus.cancelled.rawValue
        try await order.save(on: req.db)

        // Возвращаем зарезервированные порции блюду «на сегодня»
        let dish = try await order.$dish.get(on: req.db)
        if let dish, isToday(dish),
           let total = dish.portionsTotal, let left = dish.portionsLeft {
            dish.portionsLeft = min(total, left + order.quantity)
            try await dish.save(on: req.db)
        }

        if let tgClient = makeTelegramClient(app) {
            let title = dish?.title ?? "Блюдо"
            if let cookTelegramID = try? await findTelegramIDForUser(order.$cook.id, on: req.db) {
                try? await tgClient.sendMessage(
                    TelegramSendMessageRequest(
                        chatID: cookTelegramID,
                        text: "❌ Клиент отменил заказ «\(title)» (#\(order.id?.uuidString.prefix(8) ?? ""))",
                        replyMarkup: nil
                    ),
                    logger: req.logger
                )
            }
        }

        let cook = try await User.find(order.$cook.id, on: req.db)
        return OrderDTO(
            id: order.id?.uuidString ?? "",
            dish: nil,
            cook: CookSummaryDTO(id: cook?.id?.uuidString ?? "", name: cook?.firstName ?? "Повар", rating: nil, reviewCount: 0, distance: nil),
            client: nil,
            quantity: order.quantity,
            totalPrice: order.totalPrice,
            status: order.status,
            comment: order.comment,
            createdAt: order.createdAt.map { ISO8601DateFormatter().string(from: $0) },
            items: [],
            isDelivery: order.isDelivery,
            address: nil,
            deliveryLat: order.deliveryLat,
            deliveryLon: order.deliveryLon,
            distanceKm: deliveryDistance(order: order, cook: cook)
        )
    }

    private func updateLocation(_ req: Request) async throws {
        let (user, _) = try await getUser(req)
        let dto = try req.content.decode(UpdateLocationDTO.self)
        guard (-90...90).contains(dto.latitude), (-180...180).contains(dto.longitude) else {
            throw Abort(.badRequest, reason: "Некорректные координаты")
        }
        user.latitude = dto.latitude
        user.longitude = dto.longitude
        try await user.save(on: req.db)
    }

    private func getOrders(_ req: Request) async throws -> [OrderDTO] {
        let (user, _) = try await getUser(req)
        guard let userID = user.id else { throw Abort(.notFound) }
        let orders = try await Order.query(on: req.db)
            .filter(\.$client.$id == userID)
            .with(\.$client)
            .with(\.$dish)
            .with(\.$cook)
            .with(\.$items)
            .sort(\.$createdAt, .descending)
            .all()

        return orders.map { order in
            OrderDTO(
                id: order.id?.uuidString ?? "",
                dish: order.dish.map { d in
                    DishDTO(
                        id: d.id?.uuidString ?? "",
                        title: d.title,
                        details: d.details,
                        price: d.price,
                        category: d.dishType ?? "lunch",
                        photoUrl: photoURL(path: d.photoPath, fileID: d.photoFileID),
                        isToday: isToday(d),
                        portionsLeft: d.portionsLeft,
                        portionsTotal: d.portionsTotal,
                        cook: CookSummaryDTO(id: order.cook.id?.uuidString ?? "", name: order.cook.firstName, rating: nil, reviewCount: 0, distance: nil),
                        isFavorite: false,
                        createdAt: nil,
                        nutrition: NutritionDTO.from(d)
                    )
                },
                cook: CookSummaryDTO(id: order.cook.id?.uuidString ?? "", name: order.cook.firstName, rating: nil, reviewCount: 0, distance: nil),
                client: nil,
                quantity: order.quantity,
                totalPrice: order.totalPrice,
                status: order.status,
                comment: order.comment,
                createdAt: order.createdAt.map { ISO8601DateFormatter().string(from: $0) },
                items: order.items.map { OrderItemDTO(dishId: $0.$dish.id.uuidString, title: $0.dishTitle, price: $0.price, quantity: $0.quantity) },
                isDelivery: order.isDelivery,
                address: order.isDelivery == true ? (order.shippingAddress ?? order.client.address) : nil,
                deliveryLat: order.deliveryLat,
                deliveryLon: order.deliveryLon,
                distanceKm: deliveryDistance(order: order, cook: order.cook)
            )
        }
    }

    // MARK: - Favorites

    private func getFavorites(_ req: Request) async throws -> [DishDTO] {
        let (user, _) = try await getUser(req)
        guard let userID = user.id else { throw Abort(.notFound) }
        let favs = try await Favorite.query(on: req.db)
            .filter(\.$client.$id == userID)
            .with(\.$dish)
            .sort(\.$createdAt, .descending)
            .all()

        var result: [DishDTO] = []
        for fav in favs {
            let dish = fav.dish
            result.append(try await enrichDish(dish, req: req, favorites: Set([dish.id ?? UUID()])))
        }
        return result
    }

    private func toggleFavorite(_ req: Request) async throws {
        let (user, _) = try await getUser(req)
        guard let userID = user.id,
              let dishID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        if let existing = try await Favorite.query(on: req.db)
            .filter(\.$dish.$id == dishID)
            .filter(\.$client.$id == userID)
            .first() {
            try await existing.delete(on: req.db)
        } else {
            let fav = Favorite(clientID: userID, dishID: dishID)
            try await fav.create(on: req.db)
        }
    }

    // MARK: - Cook

    private func getCook(_ req: Request) async throws -> CookDTO {
        guard let id = req.parameters.get("id", as: UUID.self),
              let cook = try await User.find(id, on: req.db) else {
            throw Abort(.notFound)
        }
        let dishes = try await Dish.query(on: req.db)
            .filter(\.$cook.$id == id)
            .filter(\.$isActive == true)
            .all()
        let rating = try await calculateCookRating(cookID: id, on: req.db)
        let reviewCount = try await Order.query(on: req.db)
            .filter(\.$cook.$id == id)
            .filter(\.$reviewText != nil)
            .count()

        return CookDTO(
            id: cook.id?.uuidString ?? "",
            name: cook.firstName,
            username: cook.username,
            address: cook.address,
            pickupSchedule: cook.pickupSchedule,
            cookingDays: cook.cookingDays,
            isAcceptingOrders: cook.isAcceptingOrders ?? true,
            rating: rating,
            reviewCount: reviewCount,
            dishesCount: dishes.count,
            city: cook.city,
            bio: cook.bio,
            specialization: cook.specialization,
            profilePhotoUrl: photoURL(path: cook.profilePhotoPath, fileID: cook.profilePhotoFileID),
            latitude: cook.latitude,
            longitude: cook.longitude
        )
    }

    // MARK: - КБЖУ и гео

    /// Поиск продукта в Open Food Facts. Доступно всем авторизованным —
    /// повару для заполнения КБЖУ блюда.
    private func searchNutrition(_ req: Request) async throws -> [NutritionProductDTO] {
        _ = try await getUser(req)
        guard let query = req.query[String.self, at: "q"] else { return [] }
        return try await NutritionService.search(query: query, client: app.client, logger: req.logger)
    }

    /// Подсказки адреса через Nominatim.
    private func searchAddress(_ req: Request) async throws -> [GeoPlaceDTO] {
        _ = try await getUser(req)
        guard let query = req.query[String.self, at: "q"] else { return [] }
        return try await GeoService.search(query: query, client: app.client, logger: req.logger)
    }

    /// Расстояние по дорогам между двумя точками (OSRM).
    private func routeInfo(_ req: Request) async throws -> RouteDTO {
        _ = try await getUser(req)
        guard let fromLat = req.query[Double.self, at: "fromLat"],
              let fromLon = req.query[Double.self, at: "fromLon"],
              let toLat = req.query[Double.self, at: "toLat"],
              let toLon = req.query[Double.self, at: "toLon"],
              (-90...90).contains(fromLat), (-90...90).contains(toLat),
              (-180...180).contains(fromLon), (-180...180).contains(toLon) else {
            throw Abort(.badRequest, reason: "Некорректные координаты")
        }
        guard let route = try await GeoService.route(
            fromLat: fromLat, fromLon: fromLon,
            toLat: toLat, toLon: toLon,
            client: app.client, logger: req.logger
        ) else {
            throw Abort(.badGateway, reason: "Не удалось построить маршрут")
        }
        return route
    }

    /// Маршрут «повар → адрес доставки» по дорогам. Доступен и клиенту, и повару.
    private func orderRoute(_ req: Request) async throws -> RouteDTO {
        let (user, _) = try await getUser(req)
        guard let userID = user.id,
              let orderID = req.parameters.get("id", as: UUID.self),
              let order = try await Order.find(orderID, on: req.db) else {
            throw Abort(.notFound, reason: "Заказ не найден")
        }
        // Заказ виден только его клиенту и его повару.
        guard order.$client.id == userID || order.$cook.id == userID else {
            throw Abort(.forbidden, reason: "Нет доступа к заказу")
        }
        guard order.isDelivery == true,
              let toLat = order.deliveryLat, let toLon = order.deliveryLon else {
            throw Abort(.badRequest, reason: "У заказа нет координат доставки")
        }
        guard let cook = try await User.find(order.$cook.id, on: req.db),
              let fromLat = cook.latitude, let fromLon = cook.longitude else {
            throw Abort(.badRequest, reason: "У повара не указан адрес")
        }
        guard let route = try await GeoService.route(
            fromLat: fromLat, fromLon: fromLon,
            toLat: toLat, toLon: toLon,
            client: app.client, logger: req.logger
        ) else {
            throw Abort(.badGateway, reason: "Не удалось построить маршрут")
        }
        return route
    }

    // MARK: - Cook tools (dishes)

    private func getMyDishes(_ req: Request) async throws -> [DishDTO] {
        let (user, _) = try await getUser(req)
        guard let userID = user.id else { throw Abort(.notFound) }
        let dishes = try await Dish.query(on: req.db)
            .filter(\.$cook.$id == userID)
            .sort(\.$createdAt, .descending)
            .all()
        var result: [DishDTO] = []
        for dish in dishes {
            result.append(try await enrichDish(dish, req: req))
        }
        return result
    }

    private func updateDish(_ req: Request) async throws -> DishDTO {
        let (user, _) = try await getUser(req)
        guard user.typedRole == .cook, let userID = user.id else {
            throw Abort(.forbidden, reason: "Только для повара")
        }
        guard let dishID = req.parameters.get("id", as: UUID.self),
              let dish = try await Dish.find(dishID, on: req.db),
              dish.$cook.id == userID else {
            throw Abort(.notFound, reason: "Блюдо не найдено")
        }
        let dto = try req.content.decode(UpdateDishInput.self)
        let title = dto.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? dish.title
        guard !title.isEmpty else { throw Abort(.badRequest, reason: "Название блюда не может быть пустым") }
        if let price = dto.price, price <= 0 {
            throw Abort(.badRequest, reason: "Цена должна быть больше нуля")
        }
        dish.title = title
        if let details = dto.details { dish.details = details }
        if let price = dto.price { dish.price = price }
        if let category = dto.category, DishType.from(category) != nil { dish.dishType = category }
        if let portionsTotal = dto.portionsTotal {
            if portionsTotal > 0 {
                dish.portionsTotal = portionsTotal
                if dish.portionsLeft == nil || (dish.portionsLeft ?? 0) > portionsTotal {
                    dish.portionsLeft = portionsTotal
                }
            } else {
                dish.portionsTotal = nil
                dish.portionsLeft = nil
            }
        }
        if let isToday = dto.isToday {
            dish.cookedDate = isToday ? formatDate(Date()) : nil
        }
        // КБЖУ перезаписываем только если поле пришло в запросе.
        if dto.caloriesPer100g != nil || dto.proteinPer100g != nil
            || dto.fatPer100g != nil || dto.carbsPer100g != nil
            || dto.portionWeightG != nil {
            applyNutrition(
                to: dish,
                calories: dto.caloriesPer100g ?? dish.caloriesPer100g,
                protein: dto.proteinPer100g ?? dish.proteinPer100g,
                fat: dto.fatPer100g ?? dish.fatPer100g,
                carbs: dto.carbsPer100g ?? dish.carbsPer100g,
                portionWeight: dto.portionWeightG ?? dish.portionWeightG
            )
        }
        try await dish.save(on: req.db)
        return try await enrichDish(dish, req: req)
    }

    private func deleteDish(_ req: Request) async throws {
        let (user, _) = try await getUser(req)
        guard user.typedRole == .cook, let userID = user.id else {
            throw Abort(.forbidden, reason: "Только для повара")
        }
        guard let dishID = req.parameters.get("id", as: UUID.self),
              let dish = try await Dish.find(dishID, on: req.db),
              dish.$cook.id == userID else {
            throw Abort(.notFound, reason: "Блюдо не найдено")
        }

        // Clean up references
        try await Favorite.query(on: req.db).filter(\.$dish.$id == dishID).delete()
        try await CartItem.query(on: req.db).filter(\.$dish.$id == dishID).delete()
        try await WaitlistEntry.query(on: req.db).filter(\.$dish.$id == dishID).delete()

        let orderItems = try await OrderItem.query(on: req.db).filter(\.$dish.$id == dishID).count()
        if orderItems > 0 {
            // История заказов ссылается на блюдо — скрываем вместо удаления
            dish.isActive = false
            dish.cookedDate = nil
            dish.portionsLeft = 0
            try await dish.save(on: req.db)
        } else {
            try await dish.delete(on: req.db)
        }
    }

    private func markDishToday(_ req: Request) async throws -> DishDTO {
        let (user, _) = try await getUser(req)
        guard user.typedRole == .cook, let userID = user.id else {
            throw Abort(.forbidden, reason: "Только для повара")
        }
        guard let dishID = req.parameters.get("id", as: UUID.self),
              let dish = try await Dish.find(dishID, on: req.db),
              dish.$cook.id == userID else {
            throw Abort(.notFound, reason: "Блюдо не найдено")
        }
        let dto = try req.content.decode(MarkTodayInput.self)
        dish.cookedDate = formatDate(Date())
        if let portions = dto.portions, portions > 0 {
            dish.portionsTotal = portions
            dish.portionsLeft = portions
        } else {
            dish.portionsTotal = nil
            dish.portionsLeft = nil
        }
        try await dish.save(on: req.db)
        try await self.notifySubscribersAndWaitlist(dish: dish, req: req)
        return try await enrichDish(dish, req: req)
    }

    private func unmarkDishToday(_ req: Request) async throws -> DishDTO {
        let (user, _) = try await getUser(req)
        guard user.typedRole == .cook, let userID = user.id else {
            throw Abort(.forbidden, reason: "Только для повара")
        }
        guard let dishID = req.parameters.get("id", as: UUID.self),
              let dish = try await Dish.find(dishID, on: req.db),
              dish.$cook.id == userID else {
            throw Abort(.notFound, reason: "Блюдо не найдено")
        }
        dish.cookedDate = nil
        try await dish.save(on: req.db)
        return try await enrichDish(dish, req: req)
    }

    private func toggleDish(_ req: Request) async throws -> DishDTO {
        let (user, _) = try await getUser(req)
        guard user.typedRole == .cook, let userID = user.id else {
            throw Abort(.forbidden, reason: "Только для повара")
        }
        guard let dishID = req.parameters.get("id", as: UUID.self),
              let dish = try await Dish.find(dishID, on: req.db),
              dish.$cook.id == userID else {
            throw Abort(.notFound, reason: "Блюдо не найдено")
        }
        dish.isActive.toggle()
        try await dish.save(on: req.db)
        return try await enrichDish(dish, req: req)
    }

    /// Загрузка фото блюда из Mini App (base64 data URL), файл хранится в Public/uploads.
    /// Сохраняет base64-фото в Public/uploads и возвращает имя файла.
    private func storeUploadedPhoto(_ rawInput: String) throws -> String {
        let raw = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw Abort(.badRequest, reason: "Фото не передано")
        }

        var base64 = raw
        var ext = "jpg"
        if raw.hasPrefix("data:") {
            // формат: data:image/jpeg;base64,....
            guard let comma = raw.firstIndex(of: ",") else {
                throw Abort(.badRequest, reason: "Некорректный формат фото")
            }
            let header = String(raw[..<comma])
            if header.contains("image/png") { ext = "png" }
            else if header.contains("image/webp") { ext = "webp" }
            else if header.contains("image/gif") { ext = "gif" }
            base64 = String(raw[raw.index(after: comma)...])
        }

        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), !data.isEmpty else {
            throw Abort(.badRequest, reason: "Не удалось декодировать фото")
        }
        guard data.count <= 8 * 1024 * 1024 else {
            throw Abort(.badRequest, reason: "Фото слишком большое (максимум 8 МБ)")
        }

        let uploadsDir = app.directory.publicDirectory + "uploads/"
        try? FileManager.default.createDirectory(atPath: uploadsDir, withIntermediateDirectories: true)
        let filename = UUID().uuidString + "." + ext
        try data.write(to: URL(fileURLWithPath: uploadsDir + filename))
        return filename
    }

    private func uploadDishPhoto(_ req: Request) async throws -> DishDTO {
        let (user, _) = try await getUser(req)
        guard user.typedRole == .cook, let userID = user.id else {
            throw Abort(.forbidden, reason: "Только для повара")
        }
        guard let dishID = req.parameters.get("id", as: UUID.self),
              let dish = try await Dish.find(dishID, on: req.db),
              dish.$cook.id == userID else {
            throw Abort(.notFound, reason: "Блюдо не найдено")
        }
        let dto = try req.content.decode(UploadPhotoInput.self)
        let filename = try storeUploadedPhoto(dto.photo)

        // Удаляем старый локальный файл, если был
        if let oldPath = dish.photoPath, !oldPath.isEmpty {
            try? FileManager.default.removeItem(atPath: app.directory.publicDirectory + "uploads/" + oldPath)
        }
        dish.photoPath = filename
        try await dish.save(on: req.db)
        return try await enrichDish(dish, req: req)
    }

    /// Фото профиля (аватар) из Mini App.
    private func uploadProfilePhoto(_ req: Request) async throws -> UserProfileDTO {
        let (user, _) = try await getUser(req)
        let dto = try req.content.decode(UploadPhotoInput.self)
        let filename = try storeUploadedPhoto(dto.photo)

        if let oldPath = user.profilePhotoPath, !oldPath.isEmpty {
            try? FileManager.default.removeItem(atPath: app.directory.publicDirectory + "uploads/" + oldPath)
        }
        user.profilePhotoPath = filename
        try await user.save(on: req.db)
        return try await self.profileDTO(for: user, on: req.db)
    }

    /// Оценка заказа клиентом после получения.
    private func rateOrder(_ req: Request) async throws -> OrderDTO {
        let (user, _) = try await getUser(req)
        guard let userID = user.id,
              let orderID = req.parameters.get("id", as: UUID.self),
              let order = try await Order.find(orderID, on: req.db),
              order.$client.id == userID else {
            throw Abort(.notFound, reason: "Заказ не найден")
        }
        guard order.typedStatus == .delivered else {
            throw Abort(.badRequest, reason: "Оценить можно только полученный заказ")
        }
        let dto = try req.content.decode(RateOrderInput.self)
        guard (1...5).contains(dto.rating) else {
            throw Abort(.badRequest, reason: "Оценка от 1 до 5")
        }
        order.rating = dto.rating
        order.reviewText = dto.reviewText?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await order.save(on: req.db)

        // Начисляем бонусные баллы один раз
        if order.bonusAwarded != true {
            let bonus = bonusFor(orderTotal: order.totalPrice, hasReview: order.reviewText != nil)
            try await BotUserService.applyBonus(to: userID, amount: bonus, reason: "Отзыв на заказ", on: req.db)
            order.bonusAwarded = true
            try await order.save(on: req.db)
        }

        if let tgClient = makeTelegramClient(app),
           let cookTelegramID = try? await findTelegramIDForUser(order.$cook.id, on: req.db) {
            let title = (try? await order.$dish.get(on: req.db))?.title ?? "Блюдо"
            let reviewLine = order.reviewText.map { "\n«\($0)»" } ?? ""
            try? await tgClient.sendMessage(
                TelegramSendMessageRequest(
                    chatID: cookTelegramID,
                    text: "⭐ Новый отзыв на «\(title)»: \(dto.rating)/5\(reviewLine)",
                    replyMarkup: nil
                ),
                logger: req.logger
            )
        }

        let cook = try await User.find(order.$cook.id, on: req.db)
        return OrderDTO(
            id: order.id?.uuidString ?? "",
            dish: nil,
            cook: CookSummaryDTO(id: cook?.id?.uuidString ?? order.$cook.id.uuidString, name: cook?.firstName ?? "Повар", rating: nil, reviewCount: 0, distance: nil),
            client: nil,
            quantity: order.quantity,
            totalPrice: order.totalPrice,
            status: order.status,
            comment: order.comment,
            createdAt: order.createdAt.map { ISO8601DateFormatter().string(from: $0) },
            items: [],
            isDelivery: order.isDelivery,
            address: nil,
            deliveryLat: order.deliveryLat,
            deliveryLon: order.deliveryLon,
            distanceKm: deliveryDistance(order: order, cook: cook)
        )
    }

    /// Подписка/отписка от листа ожидания блюда.
    private func toggleWaitlist(_ req: Request) async throws {
        let (user, _) = try await getUser(req)
        guard user.typedRole == .client, let userID = user.id else {
            throw Abort(.forbidden, reason: "Только для клиента")
        }
        guard let dishID = req.parameters.get("id", as: UUID.self),
              let dish = try await Dish.find(dishID, on: req.db) else {
            throw Abort(.notFound, reason: "Блюдо не найдено")
        }

        if let existing = try await WaitlistEntry.query(on: req.db)
            .filter(\.$dish.$id == dishID)
            .filter(\.$client.$id == userID)
            .first() {
            try await existing.delete(on: req.db)
            return
        }

        let entry = WaitlistEntry(dishID: dishID, clientID: userID, quantity: 1)
        try await entry.save(on: req.db)

        // Сообщаем повару, что его блюдо ждут
        if let tgClient = makeTelegramClient(app),
           let cookTelegramID = try? await findTelegramIDForUser(dish.$cook.id, on: req.db) {
            try? await tgClient.sendMessage(
                TelegramSendMessageRequest(
                    chatID: cookTelegramID,
                    text: "👥 Клиент ждёт ваше блюдо «\(dish.title)» в списке ожидания.",
                    replyMarkup: nil
                ),
                logger: req.logger
            )
        }
    }

    // MARK: - Cook tools (orders)

    private func getCookOrders(_ req: Request) async throws -> [OrderDTO] {
        let (user, _) = try await getUser(req)
        guard user.typedRole == .cook, let userID = user.id else {
            throw Abort(.forbidden, reason: "Только для повара")
        }
        let orders = try await Order.query(on: req.db)
            .filter(\.$cook.$id == userID)
            .with(\.$client)
            .with(\.$cook)
            .with(\.$dish)
            .with(\.$items)
            .sort(\.$createdAt, .descending)
            .all()

        return orders.map { order in
            OrderDTO(
                id: order.id?.uuidString ?? "",
                dish: order.dish.map { d in
                    DishDTO(
                        id: d.id?.uuidString ?? "",
                        title: d.title,
                        details: d.details,
                        price: d.price,
                        category: d.dishType ?? "lunch",
                        photoUrl: photoURL(path: d.photoPath, fileID: d.photoFileID),
                        isToday: isToday(d),
                        portionsLeft: d.portionsLeft,
                        portionsTotal: d.portionsTotal,
                        cook: CookSummaryDTO(id: order.cook.id?.uuidString ?? "", name: order.cook.firstName, rating: nil, reviewCount: 0, distance: nil),
                        isFavorite: false,
                        createdAt: nil,
                        nutrition: NutritionDTO.from(d)
                    )
                },
                cook: CookSummaryDTO(id: order.cook.id?.uuidString ?? "", name: order.cook.firstName, rating: nil, reviewCount: 0, distance: nil),
                client: ClientSummaryDTO(
                    id: order.client.id?.uuidString ?? "",
                    name: order.client.firstName,
                    phone: order.client.phone,
                    username: order.client.username
                ),
                quantity: order.quantity,
                totalPrice: order.totalPrice,
                status: order.status,
                comment: order.comment,
                createdAt: order.createdAt.map { ISO8601DateFormatter().string(from: $0) },
                items: order.items.map { OrderItemDTO(dishId: $0.$dish.id.uuidString, title: $0.dishTitle, price: $0.price, quantity: $0.quantity) },
                isDelivery: order.isDelivery,
                address: order.isDelivery == true ? (order.shippingAddress ?? order.client.address) : nil,
                deliveryLat: order.deliveryLat,
                deliveryLon: order.deliveryLon,
                distanceKm: deliveryDistance(order: order, cook: order.cook)
            )
        }
    }

    private func updateOrderStatus(_ req: Request) async throws -> OrderDTO {
        let (user, _) = try await getUser(req)
        guard user.typedRole == .cook, let userID = user.id else {
            throw Abort(.forbidden, reason: "Только для повара")
        }
        guard let orderID = req.parameters.get("id", as: UUID.self),
              let order = try await Order.find(orderID, on: req.db),
              order.$cook.id == userID else {
            throw Abort(.notFound, reason: "Заказ не найден")
        }
        let dto = try req.content.decode(UpdateOrderStatusInput.self)
        guard let newStatus = OrderStatus(rawValue: dto.status) else {
            throw Abort(.badRequest, reason: "Неизвестный статус")
        }
        let current = order.typedStatus ?? .new
        if newStatus != .cancelled, newStatus != current, !isAllowedTransition(from: current, to: newStatus) {
            throw Abort(.badRequest, reason: "Нельзя сменить статус «\(statusTitle(current))» на «\(statusTitle(newStatus))»")
        }
        order.status = newStatus.rawValue
        try await order.save(on: req.db)

        let orderDish = try await order.$dish.get(on: req.db)

        // При отмене возвращаем зарезервированные порции блюду «на сегодня»
        if newStatus == .cancelled, let dish = orderDish, isToday(dish),
           let total = dish.portionsTotal, let left = dish.portionsLeft {
            dish.portionsLeft = min(total, left + order.quantity)
            try await dish.save(on: req.db)
        }

        // Уведомляем клиента в Telegram
        if let tgClient = makeTelegramClient(app),
           let clientTelegramID = try? await findTelegramIDForUser(order.$client.id, on: req.db) {
            let title = orderDish?.title ?? "Блюдо"
            let shortID = String(order.id?.uuidString.prefix(8) ?? "")
            var text = "📦 Заказ #\(shortID) «\(title)»: \(statusTitle(newStatus))"
            if newStatus == .ready {
                text += order.isDelivery == true ? ". Курьер скоро выедет." : ". Можно забирать!"
            }
            if newStatus == .cancelled {
                text += " Если это ошибка, напишите нам."
            }
            try? await tgClient.sendMessage(
                TelegramSendMessageRequest(chatID: clientTelegramID, text: text, replyMarkup: nil),
                logger: req.logger
            )
        }

        let cook = try await User.find(order.$cook.id, on: req.db)
        return OrderDTO(
            id: order.id?.uuidString ?? "",
            dish: nil,
            cook: CookSummaryDTO(id: cook?.id?.uuidString ?? "", name: cook?.firstName ?? "Повар", rating: nil, reviewCount: 0, distance: nil),
            client: nil,
            quantity: order.quantity,
            totalPrice: order.totalPrice,
            status: order.status,
            comment: order.comment,
            createdAt: order.createdAt.map { ISO8601DateFormatter().string(from: $0) },
            items: [],
            isDelivery: order.isDelivery,
            address: nil,
            deliveryLat: order.deliveryLat,
            deliveryLon: order.deliveryLon,
            distanceKm: deliveryDistance(order: order, cook: cook)
        )
    }

    // MARK: - Cook tools (promos & stats)

    private func getPromos(_ req: Request) async throws -> [PromoDTO] {
        let (user, _) = try await getUser(req)
        guard user.typedRole == .cook, let userID = user.id else {
            throw Abort(.forbidden, reason: "Только для повара")
        }
        let codes = try await PromoCode.query(on: req.db)
            .filter(\.$cook.$id == userID)
            .sort(\.$createdAt, .descending)
            .all()
        return codes.map { PromoDTO(promo: $0) }
    }

    private func createPromo(_ req: Request) async throws -> PromoDTO {
        let (user, _) = try await getUser(req)
        guard user.typedRole == .cook, let userID = user.id else {
            throw Abort(.forbidden, reason: "Только для повара")
        }
        let dto = try req.content.decode(PromoInput.self)
        let code = dto.code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count >= 3, code.count <= 20 else {
            throw Abort(.badRequest, reason: "Код должен быть от 3 до 20 символов")
        }
        guard (1...90).contains(dto.discountPercent) else {
            throw Abort(.badRequest, reason: "Скидка от 1 до 90%")
        }
        if let existing = try await PromoCode.query(on: req.db)
            .filter(\.$code == code)
            .filter(\.$cook.$id == userID)
            .first() {
            existing.discountPercent = dto.discountPercent
            existing.isActive = true
            try await existing.save(on: req.db)
            return PromoDTO(promo: existing)
        }
        let promo = PromoCode(cookID: userID, code: code, discountPercent: dto.discountPercent)
        try await promo.save(on: req.db)
        return PromoDTO(promo: promo)
    }

    private func togglePromo(_ req: Request) async throws -> PromoDTO {
        let (user, _) = try await getUser(req)
        guard user.typedRole == .cook, let userID = user.id else {
            throw Abort(.forbidden, reason: "Только для повара")
        }
        guard let promoID = req.parameters.get("id", as: UUID.self),
              let promo = try await PromoCode.find(promoID, on: req.db),
              promo.$cook.id == userID else {
            throw Abort(.notFound, reason: "Промокод не найден")
        }
        promo.isActive.toggle()
        try await promo.save(on: req.db)
        return PromoDTO(promo: promo)
    }

    private func getCookStats(_ req: Request) async throws -> CookStatsDTO {
        let (user, _) = try await getUser(req)
        guard user.typedRole == .cook, let userID = user.id else {
            throw Abort(.forbidden, reason: "Только для повара")
        }
        let orders = try await Order.query(on: req.db)
            .filter(\.$cook.$id == userID)
            .all()
        let delivered = orders.filter { $0.typedStatus == .delivered }
        let active = orders.filter {
            guard let status = $0.typedStatus else { return false }
            return status != .delivered && status != .cancelled
        }
        let today = orders.filter { order in
            guard let createdAt = order.createdAt else { return false }
            return Calendar.current.isDateInToday(createdAt)
        }
        let ratings = orders.compactMap { $0.rating }
        let avgRating = ratings.isEmpty ? nil : Double(ratings.reduce(0, +)) / Double(ratings.count)
        let dishesCount = try await Dish.query(on: req.db).filter(\.$cook.$id == userID).count()

        return CookStatsDTO(
            totalOrders: orders.count,
            activeOrders: active.count,
            deliveredOrders: delivered.count,
            todayOrders: today.count,
            revenue: delivered.reduce(0) { $0 + $1.totalPrice },
            avgRating: avgRating,
            dishesCount: dishesCount
        )
    }

    // MARK: - Subscriptions

    private func subscribeToCook(_ req: Request) async throws {
        let (user, _) = try await getUser(req)
        guard user.typedRole == .client, let userID = user.id else {
            throw Abort(.forbidden, reason: "Только для клиента")
        }
        guard let cookID = req.parameters.get("id", as: UUID.self),
              let cook = try await User.find(cookID, on: req.db),
              cook.typedRole == .cook else {
            throw Abort(.notFound, reason: "Повар не найден")
        }
        let existing = try await Subscription.query(on: req.db)
            .filter(\.$client.$id == userID)
            .filter(\.$cook.$id == cookID)
            .first()
        if existing == nil {
            let sub = Subscription(clientID: userID, cookID: cookID)
            try await sub.save(on: req.db)
        }
    }

    private func unsubscribeFromCook(_ req: Request) async throws {
        let (user, _) = try await getUser(req)
        guard let userID = user.id else { throw Abort(.notFound) }
        guard let cookID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        try await Subscription.query(on: req.db)
            .filter(\.$client.$id == userID)
            .filter(\.$cook.$id == cookID)
            .delete()
    }

    // MARK: - Profile & settings

    private func updateProfile(_ req: Request) async throws -> UserProfileDTO {
        let (user, _) = try await getUser(req)
        let dto = try req.content.decode(UpdateProfileInput.self)

        if let role = dto.role, (role == "client" || role == "cook") {
            let changed = user.role != role
            let wasCook = user.typedRole == .cook
            user.role = role
            if user.referralCode == nil {
                user.referralCode = generateReferralCode()
            }
            if changed {
                // Повар сменил роль на клиента — скрываем его блюда из каталога
                if wasCook, role != "cook", let userID = user.id {
                    try await Dish.query(on: req.db)
                        .filter(\.$cook.$id == userID)
                        .set(\.$isActive, to: false)
                        .update()
                }
                try await self.activatePendingReferral(user, on: req.db)
            }
        }
        if let firstName = dto.firstName?.trimmingCharacters(in: .whitespacesAndNewlines), !firstName.isEmpty {
            user.firstName = firstName
        }
        if let city = dto.city { user.city = city.isEmpty ? nil : city }
        if let bio = dto.bio { user.bio = bio.isEmpty ? nil : bio }
        if let specialization = dto.specialization { user.specialization = specialization.isEmpty ? nil : specialization }
        if let pickupSchedule = dto.pickupSchedule { user.pickupSchedule = pickupSchedule.isEmpty ? nil : pickupSchedule }
        if let cookingDays = dto.cookingDays { user.cookingDays = cookingDays.isEmpty ? nil : cookingDays }
        if let address = dto.address { user.address = address.isEmpty ? nil : address }
        if let isAcceptingOrders = dto.isAcceptingOrders { user.isAcceptingOrders = isAcceptingOrders }
        if let phone = dto.phone { user.phone = phone.isEmpty ? nil : phone }
        if let utcOffset = dto.utcOffsetMinutes, (-14 * 60...14 * 60).contains(utcOffset) {
            user.utcOffsetMinutes = utcOffset
        }

        try await user.save(on: req.db)
        return try await self.profileDTO(for: user, on: req.db)
    }

    private func activatePendingReferral(_ user: User, on db: Database) async throws {
        guard let code = user.pendingReferral, user.referredBy == nil else { return }
        guard let referrer = try await User.query(on: db)
            .filter(\.$referralCode == code)
            .first(),
            referrer.id != user.id else {
            user.pendingReferral = nil
            try await user.save(on: db)
            return
        }
        user.referredBy = referrer.id
        user.pendingReferral = nil
        try await user.save(on: db)
        if let userID = user.id {
            try await BotUserService.applyBonus(to: userID, amount: 100, reason: "Реферальный бонус", on: db)
        }
        if let referrerID = referrer.id {
            try await BotUserService.applyBonus(to: referrerID, amount: 100, reason: "Пригласили друга", on: db)
        }
        if let client = makeTelegramClient(app) {
            try? await client.sendMessage(
                TelegramSendMessageRequest(
                    chatID: referrer.telegramID,
                    text: "🎉 \(user.firstName) зарегистрировался по вашему коду. Вам начислено 100 баллов!",
                    replyMarkup: nil
                ),
                logger: app.logger
            )
        }
    }

    private func getNotificationSettings(_ req: Request) async throws -> NotificationSettingsDTO {
        let (user, _) = try await getUser(req)
        return NotificationSettingsDTO(
            enabled: user.notificationsEnabled != false,
            quietHoursStart: user.quietHoursStart,
            quietHoursEnd: user.quietHoursEnd
        )
    }

    private func updateNotificationSettings(_ req: Request) async throws -> NotificationSettingsDTO {
        let (user, _) = try await getUser(req)
        let dto = try req.content.decode(UpdateNotificationSettingsInput.self)
        if let enabled = dto.enabled { user.notificationsEnabled = enabled }
        if dto.clearQuietHours == true {
            user.quietHoursStart = nil
            user.quietHoursEnd = nil
        } else if let start = dto.quietHoursStart, let end = dto.quietHoursEnd,
                  (0...23).contains(start), (0...23).contains(end) {
            user.quietHoursStart = start
            user.quietHoursEnd = end
        }
        try await user.save(on: req.db)
        return NotificationSettingsDTO(
            enabled: user.notificationsEnabled != false,
            quietHoursStart: user.quietHoursStart,
            quietHoursEnd: user.quietHoursEnd
        )
    }

    // MARK: - Notifications

    /// Уведомляет подписчиков о блюде «на сегодня» и клиентов из листа ожидания.
    private func notifySubscribersAndWaitlist(dish: Dish, req: Request) async throws {
        guard let tgClient = makeTelegramClient(app) else { return }
        let cook = try await User.find(dish.$cook.id, on: req.db)

        let subscriptions = try await Subscription.query(on: req.db)
            .filter(\.$cook.$id == dish.$cook.id)
            .all()
        if !subscriptions.isEmpty, let cook {
            let portionsLine = dish.portionsLeft.map { ", осталось \($0) порций" } ?? ""
            let text = "🔥 \(cook.firstName) готовит сегодня: «\(dish.title)»\(portionsLine)"
            for subscription in subscriptions {
                guard let subscriber = try await User.find(subscription.$client.id, on: req.db),
                      NotificationPreferenceService.shouldSendProactiveNotification(to: subscriber) else {
                    continue
                }
                try? await tgClient.sendMessage(
                    TelegramSendMessageRequest(chatID: subscriber.telegramID, text: text, replyMarkup: nil),
                    logger: req.logger
                )
            }
        }

        let entries = try await WaitlistEntry.query(on: req.db)
            .filter(\.$dish.$id == (dish.id ?? UUID()))
            .filter(\.$notified == false)
            .sort(\.$createdAt)
            .all()
        for entry in entries {
            guard let clientTelegramID = try? await findTelegramIDForUser(entry.$client.id, on: req.db) else { continue }
            try? await tgClient.sendMessage(
                TelegramSendMessageRequest(
                    chatID: clientTelegramID,
                    text: "🔥 «\(dish.title)» пополнилось! Успейте заказать.",
                    replyMarkup: nil
                ),
                logger: req.logger
            )
            entry.notified = true
            try? await entry.save(on: req.db)
        }
    }

    // MARK: - Helpers

    private func calculateCookRating(cookID: UUID, on db: Database) async throws -> Double? {
        let rated = try await Order.query(on: db)
            .filter(\.$cook.$id == cookID)
            .filter(\.$rating != nil)
            .all()
        guard !rated.isEmpty else { return nil }
        let sum = rated.reduce(0.0) { $0 + Double($1.rating ?? 0) }
        return sum / Double(rated.count)
    }
}

// MARK: - DTOs

struct DishDTO: Content {
    let id: String
    let title: String
    let details: String?
    let price: Double
    let category: String
    let photoUrl: String?
    let isToday: Bool
    let portionsLeft: Int?
    let portionsTotal: Int?
    let cook: CookSummaryDTO
    let isFavorite: Bool
    let createdAt: String?
    let nutrition: NutritionDTO?
}

/// КБЖУ блюда: на 100 г и на порцию (если указан вес порции).
struct NutritionDTO: Content {
    let kcalPer100g: Double?
    let proteinPer100g: Double?
    let fatPer100g: Double?
    let carbsPer100g: Double?
    let portionWeightG: Int?
    let kcalPerPortion: Double?
    let proteinPerPortion: Double?
    let fatPerPortion: Double?
    let carbsPerPortion: Double?

    /// Собирает DTO из полей блюда. Возвращает nil, если КБЖУ не заполнено.
    static func from(_ dish: Dish) -> NutritionDTO? {
        let hasAny = dish.caloriesPer100g != nil || dish.proteinPer100g != nil
            || dish.fatPer100g != nil || dish.carbsPer100g != nil
        guard hasAny else { return nil }

        let weight = dish.portionWeightG.flatMap { $0 > 0 ? Double($0) : nil }
        func perPortion(_ per100: Double?) -> Double? {
            guard let per100, let weight else { return nil }
            return ((per100 * weight / 100) * 10).rounded() / 10
        }

        return NutritionDTO(
            kcalPer100g: dish.caloriesPer100g,
            proteinPer100g: dish.proteinPer100g,
            fatPer100g: dish.fatPer100g,
            carbsPer100g: dish.carbsPer100g,
            portionWeightG: dish.portionWeightG,
            kcalPerPortion: perPortion(dish.caloriesPer100g),
            proteinPerPortion: perPortion(dish.proteinPer100g),
            fatPerPortion: perPortion(dish.fatPer100g),
            carbsPerPortion: perPortion(dish.carbsPer100g)
        )
    }
}

struct CookSummaryDTO: Content {
    let id: String
    let name: String
    let rating: Double?
    let reviewCount: Int
    let distance: Double?
}

struct CookDTO: Content {
    let id: String
    let name: String
    let username: String?
    let address: String?
    let pickupSchedule: String?
    let cookingDays: String?
    let isAcceptingOrders: Bool
    let rating: Double?
    let reviewCount: Int
    let dishesCount: Int
    let city: String?
    let bio: String?
    let specialization: String?
    let profilePhotoUrl: String?
    let latitude: Double?
    let longitude: Double?
}

struct BrowseResponseDTO: Content {
    let dishes: [DishDTO]
    let page: Int
    let hasPrev: Bool
    let hasNext: Bool
}

struct UserProfileDTO: Content {
    let id: Int64
    let firstName: String
    let username: String?
    let role: String
    let balance: Int
    let referralCode: String?
    let ordersCount: Int
    let rating: String?
    let city: String?
    let bio: String?
    let specialization: String?
    let pickupSchedule: String?
    let cookingDays: String?
    let address: String?
    let phone: String?
    let isAcceptingOrders: Bool
    let hasLocation: Bool
    let utcOffsetMinutes: Int?
    let photoUrl: String?
}

struct CartItemDTO: Content {
    let id: String
    let dishId: String
    let dish: DishDTO
    let quantity: Int
}

struct OrderDTO: Content {
    let id: String
    let dish: DishDTO?
    let cook: CookSummaryDTO
    let client: ClientSummaryDTO?
    let quantity: Int
    let totalPrice: Double
    let status: String
    let comment: String?
    let createdAt: String?
    let items: [OrderItemDTO]
    let isDelivery: Bool?
    let address: String?
    let deliveryLat: Double?
    let deliveryLon: Double?
    /// Расстояние по прямой от повара до адреса доставки (км).
    let distanceKm: Double?
}

struct ClientSummaryDTO: Content {
    let id: String
    let name: String
    let phone: String?
    let username: String?
}

struct OrderItemDTO: Content {
    let dishId: String
    let title: String
    let price: Double
    let quantity: Int
}

struct UpdateDishInput: Content {
    let title: String?
    let details: String?
    let price: Double?
    let category: String?
    let portionsTotal: Int?
    let isToday: Bool?
    let caloriesPer100g: Double?
    let proteinPer100g: Double?
    let fatPer100g: Double?
    let carbsPer100g: Double?
    let portionWeightG: Int?
}

struct MarkTodayInput: Content {
    let portions: Int?
}

struct UploadPhotoInput: Content {
    let photo: String
}

struct RateOrderInput: Content {
    let rating: Int
    let reviewText: String?
}

struct UpdateOrderStatusInput: Content {
    let status: String
}

struct PromoInput: Content {
    let code: String
    let discountPercent: Int
}

struct PromoDTO: Content {
    let id: String
    let code: String
    let discountPercent: Int
    let isActive: Bool
    let usesCount: Int

    init(promo: PromoCode) {
        self.id = promo.id?.uuidString ?? ""
        self.code = promo.code
        self.discountPercent = promo.discountPercent
        self.isActive = promo.isActive
        self.usesCount = promo.usesCount
    }
}

struct CookStatsDTO: Content {
    let totalOrders: Int
    let activeOrders: Int
    let deliveredOrders: Int
    let todayOrders: Int
    let revenue: Double
    let avgRating: Double?
    let dishesCount: Int
}

struct UpdateProfileInput: Content {
    let role: String?
    let firstName: String?
    let city: String?
    let bio: String?
    let specialization: String?
    let pickupSchedule: String?
    let cookingDays: String?
    let address: String?
    let isAcceptingOrders: Bool?
    let phone: String?
    let utcOffsetMinutes: Int?
}

struct NotificationSettingsDTO: Content {
    let enabled: Bool
    let quietHoursStart: Int?
    let quietHoursEnd: Int?
}

struct UpdateNotificationSettingsInput: Content {
    let enabled: Bool?
    let quietHoursStart: Int?
    let quietHoursEnd: Int?
    let clearQuietHours: Bool?
}

struct CreateDishDTO: Content {
    let title: String
    let details: String?
    let price: Double
    let category: String?
    let portionsTotal: Int?
    let photoFileId: String?
    let isToday: Bool?
    let caloriesPer100g: Double?
    let proteinPer100g: Double?
    let fatPer100g: Double?
    let carbsPer100g: Double?
    let portionWeightG: Int?
}

struct AddToCartDTO: Content {
    let dishId: String
    let quantity: Int
}

struct UpdateCartItemDTO: Content {
    let quantity: Int
}

struct CreateOrderDTO: Content {
    let items: [OrderItemInput]
    let comment: String?
    let isDelivery: Bool?
    let phone: String?
    let address: String?
    /// Координаты выбранного адреса (если клиент выбрал подсказку).
    let addressLat: Double?
    let addressLon: Double?
}

struct OrderItemInput: Content {
    let dishId: String
    let quantity: Int
}

struct UpdateLocationDTO: Content {
    let latitude: Double
    let longitude: Double
}

// MARK: - Login helpers

struct TelegramLoginQuery {
    let id: Int64
    let first_name: String?
    let last_name: String?
    let username: String?
    let photo_url: String?
    let auth_date: String
    let hash: String

    static func fromtgAuthResult(_ base64: String) throws -> TelegramLoginQuery {
        var padded = base64
            .replacingOccurrences(of: " ", with: "+")
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded.append("=") }
        guard let data = Data(base64Encoded: padded) else {
            throw Abort(.badRequest, reason: "Invalid tgAuthResult (base64)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Abort(.badRequest, reason: "Invalid tgAuthResult (json)")
        }
        guard let id = obj["id"] as? Int64 else {
            throw Abort(.badRequest, reason: "Missing id in tgAuthResult")
        }
        return TelegramLoginQuery(
            id: id,
            first_name: obj["first_name"] as? String,
            last_name: obj["last_name"] as? String,
            username: obj["username"] as? String,
            photo_url: obj["photo_url"] as? String,
            auth_date: "\(obj["auth_date"] ?? "")",
            hash: obj["hash"] as? String ?? ""
        )
    }
}

func validateInitData(_ initData: String) throws -> (Int64, TimeInterval) {
    let botToken = Environment.get("TELEGRAM_BOT_TOKEN") ?? ""
    guard !botToken.isEmpty else { throw Abort(.internalServerError, reason: "Bot token not configured") }

    let params = initData.split(separator: "&").map(String.init)
    var dict: [String: String] = [:]
    for p in params {
        let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
        if kv.count == 2 { dict[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
    }

    guard let hash = dict.removeValue(forKey: "hash"),
          let authDateStr = dict["auth_date"],
          let authDate = TimeInterval(authDateStr),
          let userJSON = dict["user"],
          let userData = userJSON.data(using: .utf8),
          let user = try? JSONDecoder().decode(TGWebAppUser.self, from: userData) else {
        throw Abort(.unauthorized, reason: "Invalid initData format")
    }

    let dataCheckString = dict.keys.sorted().map { "\($0)=\(dict[$0]!)" }.joined(separator: "\n")
    let secretKey = HMAC<SHA256>.authenticationCode(for: Data(botToken.utf8), using: SymmetricKey(data: Data("WebAppData".utf8)))
    let calculatedHash = HMAC<SHA256>.authenticationCode(for: Data(dataCheckString.utf8), using: SymmetricKey(data: Data(secretKey)))
        .map { String(format: "%02x", $0) }.joined()

    guard calculatedHash == hash else {
        throw Abort(.unauthorized, reason: "Invalid initData hash")
    }

    return (user.id, authDate)
}

func validateTelegramLogin(_ q: TelegramLoginQuery) throws -> Int64 {
    let botToken = Environment.get("TELEGRAM_BOT_TOKEN") ?? ""
    guard !botToken.isEmpty else { throw Abort(.internalServerError, reason: "Bot token not configured") }
    var dict: [String: String] = [
        "id": String(q.id),
        "auth_date": q.auth_date
    ]
    if let v = q.first_name { dict["first_name"] = v }
    if let v = q.last_name { dict["last_name"] = v }
    if let v = q.username { dict["username"] = v }
    if let v = q.photo_url { dict["photo_url"] = v }
    let dataCheckString = dict.keys.sorted().map { "\($0)=\(dict[$0]!)" }.joined(separator: "\n")
    let secretKey = Data(SHA256.hash(data: Data(botToken.utf8)))
    let mac = Crypto.HMAC<SHA256>.authenticationCode(for: Data(dataCheckString.utf8), using: SymmetricKey(data: secretKey))
    let calcHash = mac.map { String(format: "%02x", $0) }.joined()
    guard calcHash == q.hash else { throw Abort(.unauthorized, reason: "Invalid Telegram hash") }
    if let authDate = TimeInterval(q.auth_date), Date().timeIntervalSince1970 - authDate > 86400 {
        throw Abort(.unauthorized, reason: "Auth expired")
    }
    return q.id
}

struct TGWebAppUser: Codable {
    let id: Int64
    let first_name: String?
    let last_name: String?
    let username: String?
    let language_code: String?
    let is_premium: Bool?
    let photo_url: String?
}
