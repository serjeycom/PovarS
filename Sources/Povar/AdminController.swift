import Fluent
import Vapor

// MARK: - Аутентификация админ-панели по токену из переменной ADMIN_TOKEN

struct AdminAuthMiddleware: AsyncMiddleware {
    func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard let expected = Environment.get("ADMIN_TOKEN"), !expected.isEmpty else {
            throw Abort(.serviceUnavailable, reason: "ADMIN_TOKEN не настроен на сервере")
        }
        let provided = req.headers.first(name: .authorization)?
            .replacingOccurrences(of: "Bearer ", with: "")
            ?? req.query[String.self, at: "token"]
        guard let provided, provided == expected else {
            throw Abort(.unauthorized, reason: "Неверный admin-токен")
        }
        return try await next.respond(to: req)
    }
}

struct AdminController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // Страница админ-панели
        routes.get("admin") { req async throws -> Response in
            let path = req.application.directory.publicDirectory + "admin/index.html"
            return try await req.fileio.asyncStreamFile(at: path)
        }

        // API админки: /api/v1/admin/*, доступ только по ADMIN_TOKEN
        let admin = routes.grouped("api", "v1", "admin").grouped(AdminAuthMiddleware())

        admin.get("stats") { req async throws -> AdminStatsDTO in
            try await getStats(req)
        }

        admin.get("users") { req async throws -> [UserAdminDTO] in
            try await getUsers(req)
        }
        admin.put("users", ":id") { req async throws -> UserAdminDTO in
            try await updateUser(req)
        }
        admin.delete("users", ":id") { req async throws -> HTTPStatus in
            try await deleteUser(req)
        }

        admin.get("dishes") { req async throws -> [DishAdminDTO] in
            try await getDishes(req)
        }
        admin.put("dishes", ":id") { req async throws -> DishAdminDTO in
            try await updateDish(req)
        }
        admin.delete("dishes", ":id") { req async throws -> HTTPStatus in
            try await deleteDish(req)
        }

        admin.get("orders") { req async throws -> [OrderAdminDTO] in
            try await getOrders(req)
        }
        admin.put("orders", ":id") { req async throws -> OrderAdminDTO in
            try await updateOrder(req)
        }
        admin.delete("orders", ":id") { req async throws -> HTTPStatus in
            try await deleteOrder(req)
        }

        admin.post("seed") { req async throws -> String in
            try await seedData(req)
        }

        // Реклама: рассылка сообщения в чат бота
        admin.post("broadcast") { req async throws -> BroadcastResultDTO in
            try await broadcast(req)
        }
    }

    /// Рассылка сообщения (рекламы) пользователям в чат бота.
    private func broadcast(_ req: Request) async throws -> BroadcastResultDTO {
        let dto = try req.content.decode(BroadcastDTO.self)
        let text = dto.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw Abort(.badRequest, reason: "Текст сообщения пуст")
        }
        guard text.count <= 4000 else {
            throw Abort(.badRequest, reason: "Сообщение слишком длинное (максимум 4000 символов)")
        }
        guard let token = Environment.get("TELEGRAM_BOT_TOKEN"), !token.isEmpty else {
            throw Abort(.serviceUnavailable, reason: "TELEGRAM_BOT_TOKEN не настроен")
        }

        var query = User.query(on: req.db)
        switch dto.audience {
        case "clients":
            query = query.filter(\.$role == UserRole.client.rawValue)
        case "cooks":
            query = query.filter(\.$role == UserRole.cook.rawValue)
        default:
            break // all
        }
        let users = try await query.all()

        let client = TelegramBotClient(app: req.application, botToken: token)
        let logger = req.logger
        var sent = 0
        var skipped = 0
        var failed = 0

        // Отправляем пачками по 10 параллельно и паузой между пачками
        // (~25 сообщений/сек — в пределах лимитов Telegram).
        let chunkSize = 10
        var index = 0
        while index < users.count {
            let chunk = Array(users[index..<min(index + chunkSize, users.count)])
            index += chunkSize

            let results = await withTaskGroup(of: (ok: Bool, skippedUser: Bool).self) { group in
                for user in chunk {
                    group.addTask {
                        if dto.respectQuietHours != false,
                           !NotificationPreferenceService.shouldSendProactiveNotification(to: user) {
                            return (false, true)
                        }
                        let ok = (try? await client.sendMessage(
                            TelegramSendMessageRequest(chatID: user.telegramID, text: text, replyMarkup: nil),
                            logger: logger
                        )) ?? false
                        return (ok, false)
                    }
                }
                var collected: [(ok: Bool, skippedUser: Bool)] = []
                for await result in group {
                    collected.append(result)
                }
                return collected
            }

            for result in results {
                if result.skippedUser {
                    skipped += 1
                } else if result.ok {
                    sent += 1
                } else {
                    failed += 1
                }
            }

            if index < users.count {
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }

        req.logger.info("broadcast finished", metadata: [
            "sent": "\(sent)",
            "skipped": "\(skipped)",
            "failed": "\(failed)"
        ])

        return BroadcastResultDTO(total: users.count, sent: sent, skipped: skipped, failed: failed)
    }

    private func getStats(_ req: Request) async throws -> AdminStatsDTO {
        let users = try await User.query(on: req.db).count()
        let cooks = try await User.query(on: req.db).filter(\.$role == "cook").count()
        let clients = try await User.query(on: req.db).filter(\.$role == "client").count()
        let dishes = try await Dish.query(on: req.db).count()
        let activeDishes = try await Dish.query(on: req.db).filter(\.$isActive == true).count()
        let orders = try await Order.query(on: req.db).count()
        let cancelledOrders = try await Order.query(on: req.db).filter(\.$status == OrderStatus.cancelled.rawValue).count()
        let totalRevenue = try await Order.query(on: req.db).sum(\.$totalPrice) ?? 0
        let avgOrderPrice = orders > 0 ? Double(totalRevenue) / Double(orders) : 0
        return AdminStatsDTO(
            totalUsers: users,
            totalCooks: cooks,
            totalClients: clients,
            totalDishes: dishes,
            activeDishes: activeDishes,
            totalOrders: orders,
            totalRevenue: totalRevenue,
            avgOrderPrice: avgOrderPrice,
            cancelledOrders: cancelledOrders
        )
    }

    private func getUsers(_ req: Request) async throws -> [UserAdminDTO] {
        let users = try await User.query(on: req.db).sort(\.$createdAt, .descending).all()
        return users.map { UserAdminDTO(user: $0) }
    }

    private func updateUser(_ req: Request) async throws -> UserAdminDTO {
        guard let id = req.parameters.get("id", as: UUID.self),
              let user = try await User.find(id, on: req.db) else {
            throw Abort(.notFound)
        }
        if let body = try? req.content.decode(UpdateUserDTO.self) {
            if let role = body.role { user.role = role }
            if let city = body.city { user.city = city }
            if let bio = body.bio { user.bio = bio }
            if let specialization = body.specialization { user.specialization = specialization }
            if let isAcceptingOrders = body.isAcceptingOrders { user.isAcceptingOrders = isAcceptingOrders }
            if let balance = body.balance { user.balance = balance }
            if let firstName = body.firstName { user.firstName = firstName }
            if let lastName = body.lastName { user.lastName = lastName }
            if let phone = body.phone { user.phone = phone }
            if let address = body.address { user.address = address }
            if let cookingDays = body.cookingDays { user.cookingDays = cookingDays }
            if let pickupSchedule = body.pickupSchedule { user.pickupSchedule = pickupSchedule }
        }
        try await user.save(on: req.db)
        return UserAdminDTO(user: user)
    }

    private func deleteUser(_ req: Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("id", as: UUID.self),
              let user = try await User.find(id, on: req.db) else {
            throw Abort(.notFound)
        }
        try await user.delete(on: req.db)
        return .ok
    }

    private func getDishes(_ req: Request) async throws -> [DishAdminDTO] {
        let dishes = try await Dish.query(on: req.db).sort(\.$createdAt, .descending).all()
        var result: [DishAdminDTO] = []
        for dish in dishes {
            let cook = try await User.find(dish.$cook.id, on: req.db)
            result.append(DishAdminDTO(dish: dish, cookName: cook?.firstName))
        }
        return result
    }

    private func updateDish(_ req: Request) async throws -> DishAdminDTO {
        guard let id = req.parameters.get("id", as: UUID.self),
              let dish = try await Dish.find(id, on: req.db) else {
            throw Abort(.notFound)
        }
        if let body = try? req.content.decode(UpdateDishDTO.self) {
            if let title = body.title { dish.title = title }
            if let details = body.details { dish.details = details }
            if let price = body.price { dish.price = price }
            if let isActive = body.isActive { dish.isActive = isActive }
            if let dishType = body.dishType { dish.dishType = dishType }
            if let portionsTotal = body.portionsTotal { dish.portionsTotal = portionsTotal }
            if let portionsLeft = body.portionsLeft { dish.portionsLeft = portionsLeft }
            if let cookedDate = body.cookedDate { dish.cookedDate = cookedDate }
        }
        try await dish.save(on: req.db)
        let cook = try await User.find(dish.$cook.id, on: req.db)
        return DishAdminDTO(dish: dish, cookName: cook?.firstName)
    }

    private func deleteDish(_ req: Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("id", as: UUID.self),
              let dish = try await Dish.find(id, on: req.db) else {
            throw Abort(.notFound)
        }
        try await dish.delete(on: req.db)
        return .ok
    }

    private func getOrders(_ req: Request) async throws -> [OrderAdminDTO] {
        let orders = try await Order.query(on: req.db).sort(\.$createdAt, .descending).all()
        var result: [OrderAdminDTO] = []
        for order in orders {
            let cook = try await User.find(order.$cook.id, on: req.db)
            let client = try await User.find(order.$client.id, on: req.db)
            let dishTitle = order.dish?.title
            result.append(OrderAdminDTO(order: order, cookName: cook?.firstName, clientName: client?.firstName, dishTitle: dishTitle))
        }
        return result
    }

    private func updateOrder(_ req: Request) async throws -> OrderAdminDTO {
        guard let id = req.parameters.get("id", as: UUID.self),
              let order = try await Order.find(id, on: req.db) else {
            throw Abort(.notFound)
        }
        if let body = try? req.content.decode(UpdateOrderDTO.self) {
            if let status = body.status { order.status = status }
            if let comment = body.comment { order.comment = comment }
            if let rating = body.rating { order.rating = rating }
            if let pickupTime = body.pickupTime { order.pickupTime = pickupTime }
            if let shippingAddress = body.shippingAddress { order.shippingAddress = shippingAddress }
            if let paymentStatus = body.paymentStatus { order.paymentStatus = paymentStatus }
            if let complaintText = body.complaintText { order.complaintText = complaintText }
        }
        try await order.save(on: req.db)
        let cook = try await User.find(order.$cook.id, on: req.db)
        let client = try await User.find(order.$client.id, on: req.db)
        let dishTitle = order.dish?.title
        return OrderAdminDTO(order: order, cookName: cook?.firstName, clientName: client?.firstName, dishTitle: dishTitle)
    }

    private func deleteOrder(_ req: Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("id", as: UUID.self),
              let order = try await Order.find(id, on: req.db) else {
            throw Abort(.notFound)
        }
        try await order.delete(on: req.db)
        return .ok
    }

    // MARK: - Seed Data

    private func seedData(_ req: Request) async throws -> String {
        let existing = try await User.query(on: req.db).count()
        guard existing == 0 else { return "Database already has \(existing) users. Clear DB first or skip." }

        // Moscow coordinates: 55.7558, 37.6173
        let cities = ["Москва", "Санкт-Петербург", "Новосибирск", "Казань", "Екатеринбург"]

        let cookData: [(first: String, last: String, city: String, bio: String, spec: String, addr: String, lat: Double, lon: Double)] = [
            ("Анна", "Петрова", "Москва", "Готовлю домашнюю еду 15 лет. Люблю эксперименты с восточной кухней.", "Восточная кухня", "ул. Тверская, 12", 55.764, 37.606),
            ("Мария", "Иванова", "Москва", "Мастер пирогов и выпечки. Все рецепты от бабушки.", "Выпечка и десерты", "ул. Арбат, 25", 55.752, 37.594),
            ("Елена", "Сидорова", "Санкт-Петербург", "Вегетарианская и сыроедческая кухня. Здоровое питание — мой конёк.", "Вегетарианская кухня", "Невский пр., 88", 59.932, 30.360),
            ("Дмитрий", "Козлов", "Москва", "Шеф-повар ресторана, готовлю дома на заказ. Гриль и мясо.", "Мясо и гриль", "ул. Арбат, 3", 55.751, 37.600),
            ("Ольга", "Новикова", "Казань", "Татарская кухня: эчпочмаки, кыстыбый, бешбармак. Настоящий вкус!", "Татарская кухня", "ул. Баумана, 15", 55.790, 49.114),
            ("Сергей", "Морозов", "Новосибирск", "Готовлю суши и роллы дома. Свежая рыба каждое утро.", "Суши и роллы", "Красный пр., 60", 55.030, 82.920),
            ("Ирина", "Волкова", "Екатеринбург", "Домашние обеды для всей семьи. Щи, борщ, котлеты — как у мамы.", "Домашняя кухня", "ул. Малышева, 36", 56.838, 60.597),
            ("Татьяна", "Соколова", "Москва", "Кондитер. Торты на заказ, капкейки, десерты для праздников.", "Кондитерская", "ул. Покровка, 17", 55.759, 37.645),
        ]

        var cookIDs: [UUID] = []
        for (i, cd) in cookData.enumerated() {
            let user = User(
                telegramID: Int64(900000 + i),
                firstName: cd.first,
                lastName: cd.last,
                username: "cook_\(cd.first.lowercased())",
                role: "cook"
            )
            user.city = cd.city
            user.bio = cd.bio
            user.specialization = cd.spec
            user.address = cd.addr
            user.latitude = cd.lat
            user.longitude = cd.lon
            user.isAcceptingOrders = true
            user.pickupSchedule = "10:00–21:00"
            user.cookingDays = "Пн, Ср, Пт, Сб"
            user.balance = Int.random(in: 0...500)
            user.referralCode = String(UUID().uuidString.prefix(8))
            try await user.save(on: req.db)
            cookIDs.append(user.id!)
        }

        // 5 client users
        let clientNames: [(first: String, last: String, city: String)] = [
            ("Алексей", "Смирнов", "Москва"),
            ("Екатерина", "Попова", "Санкт-Петербург"),
            ("Николай", "Васильев", "Москва"),
            ("Юлия", "Морозова", "Казань"),
            ("Максим", "Новиков", "Екатеринбург"),
        ]
        var clientIDs: [UUID] = []
        for (i, cn) in clientNames.enumerated() {
            let user = User(
                telegramID: Int64(800000 + i),
                firstName: cn.first,
                lastName: cn.last,
                username: "client_\(cn.first.lowercased())",
                role: "client"
            )
            user.city = cn.city
            try await user.save(on: req.db)
            clientIDs.append(user.id!)
        }

        // Dishes
        let dishData: [(title: String, details: String, price: Double, type: String, portions: Int)] = [
            ("Борщ украинский", "Классический борщ со сметаной и чесночными пампушками. Подаётся горячим.", 280, "lunch", 10),
            ("Пельмени домашние", "Ручная лепка, начинка из говядины и свинины. 25 штук в порции.", 320, "dinner", 8),
            ("Тирамису", "Итальянский десерт с маскарпоне и кофе. Порция на 2-3 человека.", 450, "dessert", 5),
            ("Суши сет «Классик»", "8 роллов: Филадельфия, Калифорния, Маки с лососем. Соевый соус, васаби.", 580, "lunch", 6),
            ("Эчпочмаки (5 шт)", "Татарские треуголники с мясом и картофелем. Свежие, горячие.", 250, "breakfast", 12),
            ("Курица гриль", "Целая курица на гриле с овощами и соусом. Сочный аромат.", 380, "dinner", 4),
            ("Салат «Цезарь»", "Романо, курица гриль, пармезан, крутон домашний, соус цезарь.", 220, "lunch", 7),
            ("Блины с вареньем", "Тонкие блины с клубничным и малиновым вареньем. 10 штук.", 180, "breakfast", 15),
            ("Шарлотка с яблоками", "Пышный бисквит с кислыми яблоками и корицей. Теплая.", 200, "dessert", 8),
            ("Паста Карбонара", "Спагетти с беконом, яйцом и пармезаном. Классический рецепт.", 290, "dinner", 6),
            ("Хачапури по-аджарски", "Лодочка с сулугуни, яйцом и маслом. Горячее, прямо из духовки.", 260, "lunch", 5),
            ("Морс клюквенный", "Домашний морс из свежей клюквы. Без сахара, освежающий.", 80, "drink", 20),
            ("Лагман", "Узбецкая лапша с мясом и овощами в пряном бульоне.", 310, "dinner", 5),
            ("Пирожки с капустой", "Домашние пирожки, тесто на молоке. 6 штук в порции.", 150, "breakfast", 10),
            ("Сырники со сметаной", "Пышные сырники из творога, подаются со сметаной и вареньем.", 200, "breakfast", 9),
            ("Шаурма домашняя", "Лаваш, курица, овощи, соус. Большая порция.", 250, "lunch", 8),
            ("Окрошка", "Холодный суп на квасе с огурцами, яйцом и ветчиной.", 170, "lunch", 6),
            ("Чизкейк NY", "Классический нью-йоркский чизкейк. Кремовый, нежный.", 380, "dessert", 4),
            ("Плов узбекский", "Кастрюльный плов с бараниной, морковью и рисом. Ароматный.", 340, "dinner", 7),
            ("Сок апельсиновый", "Свежевыжатый сок из апельсинов. 300мл.", 120, "drink", 15),
        ]

        let today = ISO8601DateFormatter().string(from: Date()).prefix(10)
        var dishIDs: [UUID] = []
        for (i, dd) in dishData.enumerated() {
            let cookIdx = i % cookIDs.count
            let dish = Dish(
                cookID: cookIDs[cookIdx],
                title: dd.title,
                details: dd.details,
                price: dd.price,
                isActive: true
            )
            dish.dishType = dd.type
            dish.portionsTotal = dd.portions
            dish.portionsLeft = Int.random(in: 0...dd.portions)
            dish.cookedDate = String(today)
            try await dish.save(on: req.db)
            dishIDs.append(dish.id!)
        }

        // Orders
        let statuses = ["new", "accepted", "cooking", "ready", "delivered", "cancelled"]
        let comments = [
            "Хочу пожарче, если можно!",
            "Спасибо, очень вкусно!",
            "Пора выдачи удобна",
            "Добавьте сметану, пожалуйста",
            "Доставка или самовывоз?",
            "Лучший борщ в городе!",
            "Ещё заказывала — супер!",
            "Быстро приготовили, спасибо!",
        ]
        for i in 0..<20 {
            let clientIdx = i % clientIDs.count
            let dishIdx = i % dishIDs.count
            let cookIdx = dishIdx % cookIDs.count
            let order = Order(
                clientID: clientIDs[clientIdx],
                cookID: cookIDs[cookIdx],
                dishID: dishIDs[dishIdx],
                status: OrderStatus(rawValue: statuses[i % statuses.count]) ?? .new,
                totalPrice: Double.random(in: 150...600),
                comment: comments[i % comments.count],
                quantity: Int.random(in: 1...3)
            )
            if i % statuses.count == 5 {
                order.rating = Int.random(in: 3...5)
                order.reviewText = ["Вкусно!", "Рекомендую!", "Буду заказывать ещё", "Отличное блюдо", "Немного солёновато"][i % 5]
            }
            try await order.save(on: req.db)
        }

        return "Seed complete: \(cookIDs.count) cooks, \(clientIDs.count) clients, \(dishIDs.count) dishes, 20 orders"
    }
}

// MARK: - DTOs

struct AdminStatsDTO: Content {
    let totalUsers: Int
    let totalCooks: Int
    let totalClients: Int
    let totalDishes: Int
    let activeDishes: Int
    let totalOrders: Int
    let totalRevenue: Double
    let avgOrderPrice: Double
    let cancelledOrders: Int
}

struct BroadcastDTO: Content {
    let text: String
    let audience: String?
    let respectQuietHours: Bool?
}

struct BroadcastResultDTO: Content {
    let total: Int
    let sent: Int
    let skipped: Int
    let failed: Int
}

struct UserAdminDTO: Content {
    let id: String
    let telegramID: Int64
    let firstName: String
    let lastName: String?
    let username: String?
    let phone: String?
    let role: String?
    let city: String?
    let bio: String?
    let specialization: String?
    let address: String?
    let isAcceptingOrders: Bool?
    let cookingDays: String?
    let pickupSchedule: String?
    let balance: Int?
    let referralCode: String?
    let latitude: Double?
    let longitude: Double?
    let createdAt: String?

    init(user: User) {
        self.id = user.id?.uuidString ?? ""
        self.telegramID = user.telegramID
        self.firstName = user.firstName
        self.lastName = user.lastName
        self.username = user.username
        self.phone = user.phone
        self.role = user.role
        self.city = user.city
        self.bio = user.bio
        self.specialization = user.specialization
        self.address = user.address
        self.isAcceptingOrders = user.isAcceptingOrders
        self.cookingDays = user.cookingDays
        self.pickupSchedule = user.pickupSchedule
        self.balance = user.balance
        self.referralCode = user.referralCode
        self.latitude = user.latitude
        self.longitude = user.longitude
        self.createdAt = user.createdAt.map { ISO8601DateFormatter().string(from: $0) }
    }
}

struct DishAdminDTO: Content {
    let id: String
    let title: String
    let details: String?
    let price: Double
    let isActive: Bool
    let dishType: String?
    let portionsTotal: Int?
    let portionsLeft: Int?
    let cookedDate: String?
    let cookName: String?
    let cookID: String
    let createdAt: String?

    init(dish: Dish, cookName: String?) {
        self.id = dish.id?.uuidString ?? ""
        self.title = dish.title
        self.details = dish.details
        self.price = dish.price
        self.isActive = dish.isActive
        self.dishType = dish.dishType
        self.portionsTotal = dish.portionsTotal
        self.portionsLeft = dish.portionsLeft
        self.cookedDate = dish.cookedDate
        self.cookName = cookName
        self.cookID = dish.$cook.id.uuidString
        self.createdAt = dish.createdAt.map { ISO8601DateFormatter().string(from: $0) }
    }
}

struct OrderAdminDTO: Content {
    let id: String
    let status: String
    let totalPrice: Double
    let quantity: Int
    let comment: String?
    let rating: Int?
    let reviewText: String?
    let cookName: String?
    let clientName: String?
    let dishTitle: String?
    let createdAt: String?

    init(order: Order, cookName: String?, clientName: String?, dishTitle: String?) {
        self.id = order.id?.uuidString ?? ""
        self.status = order.status
        self.totalPrice = order.totalPrice
        self.quantity = order.quantity
        self.comment = order.comment
        self.rating = order.rating
        self.reviewText = order.reviewText
        self.cookName = cookName
        self.clientName = clientName
        self.dishTitle = dishTitle
        self.createdAt = order.createdAt.map { ISO8601DateFormatter().string(from: $0) }
    }
}

struct UpdateUserDTO: Content {
    let firstName: String?
    let lastName: String?
    let phone: String?
    let role: String?
    let city: String?
    let bio: String?
    let specialization: String?
    let address: String?
    let isAcceptingOrders: Bool?
    let cookingDays: String?
    let pickupSchedule: String?
    let balance: Int?
}

struct UpdateDishDTO: Content {
    let title: String?
    let details: String?
    let price: Double?
    let isActive: Bool?
    let dishType: String?
    let portionsTotal: Int?
    let portionsLeft: Int?
    let cookedDate: String?
}

struct UpdateOrderDTO: Content {
    let status: String?
    let comment: String?
    let rating: Int?
    let pickupTime: String?
    let shippingAddress: String?
    let paymentStatus: String?
    let complaintText: String?
}
