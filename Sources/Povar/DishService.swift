import Fluent
import Foundation
import Vapor

struct NearbyMenu {
    var cook: User
    var distance: Double
    var rating: Double?
    var dishes: [Dish]
    var reviewPhotoCount: Int
}

struct SearchFilters {
    var keyword: String?
    var maxPrice: Double?
    var dishType: String?

    init(keyword: String? = nil, maxPrice: Double? = nil, dishType: String? = nil) {
        self.keyword = keyword
        self.maxPrice = maxPrice
        self.dishType = dishType
    }

    static func fromUser(_ user: User) -> SearchFilters {
        SearchFilters(
            keyword: user.searchKeyword,
            maxPrice: user.searchMaxPrice,
            dishType: user.searchDishType
        )
    }
}

func isSoldOut(_ dish: Dish) -> Bool {
    dish.portionsLeft == 0
}

func collectNearbyMenus(
    clientLatitude: Double,
    clientLongitude: Double,
    req: Vapor.Request,
    filters: SearchFilters = SearchFilters()
) async throws -> [NearbyMenu] {
    let maxDistance = 10.0
    let cooks = try await User.query(on: req.db)
        .filter(\.$role == UserRole.cook.rawValue)
        .all()

    let todayName = todayWeekdayName()
    var menus: [NearbyMenu] = []

    for cook in cooks {
        guard let cookID = cook.id,
              let latitude = cook.latitude,
              let longitude = cook.longitude,
              cook.isAcceptingOrders != false else { continue }
        let distance = LocationService.distance(
            from: clientLatitude, longitude1: clientLongitude,
            to: latitude, longitude2: longitude
        )
        guard distance <= maxDistance else { continue }

        let allDishes = try await Dish.query(on: req.db)
            .filter(\.$cook.$id == cookID)
            .filter(\.$isActive == true)
            .all()

        let todayDishes = allDishes.filter { isToday($0) && !isSoldOut($0) }
        var servesToday = true
        if let days = cook.cookingDays, !days.isEmpty {
            servesToday = days.contains(todayName) || !todayDishes.isEmpty
        }
        guard servesToday else { continue }

        let shown = (todayDishes + allDishes.filter { !isToday($0) && !isSoldOut($0) })
            .filter { dish in
                if let keyword = filters.keyword, !keyword.isEmpty {
                    let haystack = "\(dish.title) \(dish.details ?? "")".lowercased()
                    guard haystack.contains(keyword.lowercased()) else { return false }
                }
                if let maxPrice = filters.maxPrice, dish.price > maxPrice { return false }
                if let type = filters.dishType, !type.isEmpty {
                    guard dish.dishType == type else { return false }
                }
                return true
            }
            .sorted { a, b in
                if isToday(a) != isToday(b) { return isToday(a) }
                return (a.createdAt ?? .distantPast) > (b.createdAt ?? .distantPast)
            }
        guard !shown.isEmpty else { continue }

        let rated = try await Order.query(on: req.db)
            .filter(\.$cook.$id == cookID)
            .filter(\.$rating != nil)
            .all()
        let rating: Double?
        if !rated.isEmpty {
            let sum = rated.reduce(0.0) { $0 + Double($1.rating ?? 0) }
            rating = sum / Double(rated.count)
        } else {
            rating = nil
        }

        let reviewPhotos = try await Order.query(on: req.db)
            .filter(\.$cook.$id == cookID)
            .filter(\.$reviewPhoto != nil)
            .all()

        menus.append(NearbyMenu(
            cook: cook,
            distance: distance,
            rating: rating,
            dishes: shown,
            reviewPhotoCount: reviewPhotos.count
        ))
    }
    return menus
}

func sendDishesForClient(
    telegramUserID: Int64,
    chatID: Int64,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          let userID = user.id else {
        try await sendRoleSelection(
            telegramUserID: telegramUserID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )
        return
    }

    guard user.typedRole == .client else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Только для клиентов", replyMarkup: nil),
            logger: logger
        )
        return
    }

    guard let clientLatitude = user.latitude, let clientLongitude = user.longitude else {
        let keyboard = TelegramReplyKeyboardMarkup(
            keyboard: [[TelegramKeyboardButton(text: "📍 Поделиться геолокацией", requestLocation: true)]],
            resizeKeyboard: true,
            isPersistent: true,
            oneTimeKeyboard: false
        )
        try await client.sendMessageWithReplyKeyboard(
            TelegramSendMessageReplyKeyboardRequest(
                chatID: chatID,
                text: "Чтобы найти блюда рядом, поделитесь вашей геолокацией:",
                replyMarkup: keyboard
            ),
            logger: logger
        )
        return
    }

    let menus = try await collectNearbyMenus(
        clientLatitude: clientLatitude,
        clientLongitude: clientLongitude,
        req: req,
        filters: SearchFilters.fromUser(user)
    )

    guard !menus.isEmpty else {
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "В радиусе 10 км сейчас никто не готовит. Загляните позже.",
                replyMarkup: nil
            ),
            logger: logger
        )
        return
    }

    let subscriptions = try await Subscription.query(on: req.db)
        .filter(\.$client.$id == userID)
        .all()
    let subscribedCookIDs = Set(subscriptions.compactMap { $0.$cook.id })

    let filterLine: String
    var filterParts: [String] = []
    if let keyword = user.searchKeyword, !keyword.isEmpty {
        filterParts.append("«\(keyword)»")
    }
    if let maxPrice = user.searchMaxPrice {
        filterParts.append("до \(Int(maxPrice))₽")
    }
    if let typeRaw = user.searchDishType, let typeTitle = dishTypeTitle(typeRaw) {
        filterParts.append(typeTitle)
    }
    filterLine = filterParts.isEmpty ? "" : "\n🔍 Фильтры: \(filterParts.joined(separator: ", "))"

    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: chatID, text: "Доступные блюда:\(filterLine)", replyMarkup: nil),
        logger: logger
    )

    for menu in menus {
        try await sendMenuMessage(
            menu: menu,
            subscribedCookIDs: subscribedCookIDs,
            req: req,
            chatID: chatID,
            client: client,
            logger: logger
        )
    }
}

func sendMenuMessage(
    menu: NearbyMenu,
    subscribedCookIDs: Set<UUID>,
    req: Vapor.Request,
    chatID: Int64,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    var header = "Меню \(menu.cook.firstName) (\(LocationService.formatDistance(menu.distance)))"
    if let rating = menu.rating {
        header += " ⭐\(String(format: "%.1f", rating))"
    }
    if menu.reviewPhotoCount > 0 {
        header += " 📷 \(menu.reviewPhotoCount)"
    }

    let cappedDishes = Array(menu.dishes.prefix(8))
    var lines: [String] = []
    for (index, dish) in cappedDishes.enumerated() {
        var line = "\(index + 1). \(dish.title) — \(formatPrice(dish.price))₽"
        if let typeTitle = dishTypeTitle(dish.dishType) {
            line += " (\(typeTitle))"
        }
        if isToday(dish) {
            line += " 🔥"
            if let left = dish.portionsLeft {
                line += " (осталось \(left))"
            }
        }
        lines.append(line)
    }
    if menu.dishes.count > cappedDishes.count {
        lines.append("…и ещё \(menu.dishes.count - cappedDishes.count) блюд")
    }
    let text = header + "\n" + lines.joined(separator: "\n")

    let orderButtons = cappedDishes.enumerated().map { (index, dish) in
        TelegramInlineKeyboardButton(
            text: "Заказать \(index + 1)",
            callbackData: "order:create:\(dish.id?.uuidString ?? "")"
        )
    }
    let cartButtons = cappedDishes.enumerated().map { (index, dish) in
        TelegramInlineKeyboardButton(
            text: "🛒 \(index + 1)",
            callbackData: "cart:add:\(dish.id?.uuidString ?? ""):1"
        )
    }
    var buttons: [[TelegramInlineKeyboardButton]] = []
    for i in 0..<max(orderButtons.count, cartButtons.count) {
        buttons.append([
            orderButtons[i],
            cartButtons[i]
        ])
    }
    var footer: [TelegramInlineKeyboardButton] = []
    let isSubscribed = menu.cook.id.map { subscribedCookIDs.contains($0) } ?? false
    footer.append(TelegramInlineKeyboardButton(
        text: isSubscribed ? "Слежу ✓" : "Слежу",
        callbackData: "cook:sub:\(menu.cook.id?.uuidString ?? "")"
    ))
    if let cookID = menu.cook.id {
        let reviewCount = try await Order.query(on: req.db)
            .filter(\.$cook.$id == cookID)
            .filter(\.$reviewText != nil)
            .count()
        if reviewCount > 0 {
            footer.append(TelegramInlineKeyboardButton(
                text: "⭐ \(reviewCount)",
                callbackData: "cook:reviews:\(cookID.uuidString)"
            ))
        }
    }
    if let cookID = menu.cook.id,
       menu.cook.latitude != nil, menu.cook.longitude != nil {
        footer.append(TelegramInlineKeyboardButton(
            text: "🗺 Карта",
            callbackData: "cook:map:\(cookID.uuidString)"
        ))
    }
    if menu.reviewPhotoCount > 0 {
        footer.append(TelegramInlineKeyboardButton(
            text: "📷 Фото",
            callbackData: "cook:review_photos:\(menu.cook.id?.uuidString ?? "")"
        ))
    }
    footer.append(TelegramInlineKeyboardButton(
        text: "🛒 Корзина",
        callbackData: "cart:show"
    ))
    buttons.append(footer)

    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: text,
            replyMarkup: TelegramInlineKeyboardMarkup(inlineKeyboard: buttons)
        ),
        logger: logger
    )
}

func sendSurprise(
    telegramUserID: Int64,
    chatID: Int64,
    budget: Double,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        try await sendRoleSelection(
            telegramUserID: telegramUserID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )
        return
    }
    guard user.typedRole == .client else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Только для клиентов", replyMarkup: nil),
            logger: logger
        )
        return
    }
    guard let clientLatitude = user.latitude, let clientLongitude = user.longitude else {
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "Сначала поделитесь геолокацией через «Найти блюда рядом».",
                replyMarkup: nil
            ),
            logger: logger
        )
        return
    }

    let menus = try await collectNearbyMenus(
        clientLatitude: clientLatitude,
        clientLongitude: clientLongitude,
        req: req
    )

    var candidates: [(dish: Dish, menu: NearbyMenu)] = []
    for menu in menus {
        for dish in menu.dishes where dish.price <= budget {
            candidates.append((dish: dish, menu: menu))
        }
    }

    guard !candidates.isEmpty else {
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "В бюджете \(Int(budget))₽ рядом пока ничего нет. Попробуйте увеличить бюджет.",
                replyMarkup: nil
            ),
            logger: logger
        )
        return
    }

    try await ConversationService.startSurpriseBudget(for: telegramUserID, budget: String(budget), on: req.db)

    let pick = candidates.randomElement()!
    let dish = pick.dish
    let menu = pick.menu
    let text = """
    🎲 Сюрприз на ваш бюджет!
    Блюдо «\(dish.title)»
    \(dish.details ?? "Без описания")
    Цена: \(formatPrice(dish.price)) руб.
    Повар: \(menu.cook.firstName) (\(LocationService.formatDistance(menu.distance)))
    """
    let dishID = dish.id?.uuidString ?? ""
    let markup = TelegramInlineKeyboardMarkup(inlineKeyboard: [
        [
            TelegramInlineKeyboardButton(text: "Заказать", callbackData: "order:create:\(dishID)"),
            TelegramInlineKeyboardButton(text: "🎲 Ещё раз", callbackData: "surprise:again")
        ],
        [
            TelegramInlineKeyboardButton(text: "В избранное", callbackData: "dish:fav:\(dishID)")
        ]
    ])
    try await client.sendMessage(
        TelegramSendMessageRequest(chatID: chatID, text: text, replyMarkup: markup),
        logger: logger
    )
}

func sendMyCooks(
    telegramUserID: Int64,
    chatID: Int64,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          let userID = user.id else {
        try await sendRoleSelection(
            telegramUserID: telegramUserID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )
        return
    }
    guard user.typedRole == .client else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Только для клиентов", replyMarkup: nil),
            logger: logger
        )
        return
    }

    let subscriptions = try await Subscription.query(on: req.db)
        .filter(\.$client.$id == userID)
        .all()

    guard !subscriptions.isEmpty else {
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "Вы пока ни за кем не следите. Нажмите «Слежу» в меню повара.",
                replyMarkup: nil
            ),
            logger: logger
        )
        return
    }

    for subscription in subscriptions {
        guard let cook = try await User.find(subscription.$cook.id, on: req.db) else { continue }
        var text = "Повар: \(cook.firstName)"
        if cook.isAcceptingOrders == false {
            text += "\nСтатус: не принимает заказы"
        } else {
            text += "\nСтатус: принимает заказы"
        }
        if let days = cook.cookingDays, !days.isEmpty {
            text += "\nГотовит по дням: \(days)"
        }
        let markup = TelegramInlineKeyboardMarkup(inlineKeyboard: [
            [
                TelegramInlineKeyboardButton(
                    text: "Меню",
                    callbackData: "cook:menu:\(cook.id?.uuidString ?? "")"
                ),
                TelegramInlineKeyboardButton(
                    text: "Отписаться",
                    callbackData: "cook:unsub:\(cook.id?.uuidString ?? "")"
                )
            ]
        ])
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: text, replyMarkup: markup),
            logger: logger
        )
    }
}

func notifySubscribersOfCook(
    dish: Dish,
    portions: Int?,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let cook = try await User.find(dish.$cook.id, on: req.db),
          let cookID = cook.id else { return }
    let subscriptions = try await Subscription.query(on: req.db)
        .filter(\.$cook.$id == cookID)
        .all()
    guard !subscriptions.isEmpty else { return }

    let portionsLine = portions.map { ", осталось \($0) порций" } ?? ""
    let text = "🔥 \(cook.firstName) готовит сегодня: «\(dish.title)»\(portionsLine)"
    for subscription in subscriptions {
        guard let clientTelegramID = try await findTelegramIDForUser(subscription.$client.id, on: req.db) else {
            continue
        }
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: clientTelegramID, text: text, replyMarkup: nil),
            logger: logger
        )
    }
}

func sendCookDishes(
    telegramUserID: Int64,
    chatID: Int64,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          let cookID = user.id else {
        try await sendRoleSelection(
            telegramUserID: telegramUserID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )
        return
    }

    guard user.typedRole == .cook else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Только для повара", replyMarkup: nil),
            logger: logger
        )
        return
    }

    let dishes = try await Dish.query(on: req.db)
        .filter(\.$cook.$id == cookID)
        .sort(\.$createdAt, .descending)
        .all()

    guard !dishes.isEmpty else {
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "У вас пока нет блюд. Добавьте через «Добавить блюдо».",
                replyMarkup: nil
            ),
            logger: logger
        )
        return
    }

    for dish in dishes {
        let statusText = dish.isActive ? "🟢 активно" : "🔴 скрыто"
        let toggleTitle = dish.isActive ? "Скрыть" : "Показать"
        let typeLine = dishTypeTitle(dish.dishType).map { "Категория: \($0)\n" } ?? ""
        var text = """
        Блюдо «\(dish.title)»
        \(typeLine)\(dish.details ?? "Без описания")
        Цена: \(formatPrice(dish.price)) руб.
        \(statusText)
        """
        if isToday(dish) {
            if let left = dish.portionsLeft, let total = dish.portionsTotal {
                text += "\n🔥 Сегодня: осталось \(left) из \(total)"
            } else {
                text += "\n🔥 Сегодня (без лимита)"
            }
        }
        let todayButton = isToday(dish)
            ? TelegramInlineKeyboardButton(text: "Убрать с сегодня", callbackData: "dish:untoday:\(dish.id?.uuidString ?? "")")
            : TelegramInlineKeyboardButton(text: "На сегодня", callbackData: "dish:today:\(dish.id?.uuidString ?? "")")
        let markup = TelegramInlineKeyboardMarkup(inlineKeyboard: [
            [
                TelegramInlineKeyboardButton(
                    text: toggleTitle,
                    callbackData: "dish:toggle:\(dish.id?.uuidString ?? "")"
                )
            ],
            [
                todayButton
            ],
            [
                TelegramInlineKeyboardButton(
                    text: "Фото",
                    callbackData: "dish:photo:\(dish.id?.uuidString ?? "")"
                ),
                TelegramInlineKeyboardButton(
                    text: "Изменить",
                    callbackData: "dish:edit:\(dish.id?.uuidString ?? "")"
                )
            ],
            [
                TelegramInlineKeyboardButton(
                    text: "Удалить",
                    callbackData: "dish:delete:\(dish.id?.uuidString ?? "")"
                )
            ]
        ])
        if let photoFileID = dish.photoFileID {
            try await client.sendPhoto(
                TelegramSendPhotoRequest(chatID: chatID, photo: photoFileID, caption: text, replyMarkup: markup),
                logger: logger
            )
        } else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: text, replyMarkup: markup),
                logger: logger
            )
        }
    }
}

func handleDishToggleCallback(
    telegramUserID: Int64,
    callbackQueryID: String,
    dishIDString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }

    guard let dishID = UUID(uuidString: dishIDString),
          let dish = try await Dish.find(dishID, on: req.db),
          dish.$cook.id == user.id else {
        try await client.answerCallbackQuery(
            TelegramAnswerCallbackQueryRequest(callbackQueryID: callbackQueryID, text: "Блюдо не найдено"),
            logger: logger
        )
        return
    }

    dish.isActive.toggle()
    try await dish.save(on: req.db)

    let toastText = dish.isActive ? "Блюдо снова активно" : "Блюдо скрыто"
    try await client.answerCallbackQuery(
        TelegramAnswerCallbackQueryRequest(callbackQueryID: callbackQueryID, text: toastText),
        logger: logger
    )
}

func handleDishDeleteCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    dishIDString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }

    guard let dishID = UUID(uuidString: dishIDString),
          let dish = try await Dish.find(dishID, on: req.db),
          dish.$cook.id == user.id else {
        try await client.answerCallbackQuery(
            TelegramAnswerCallbackQueryRequest(callbackQueryID: callbackQueryID, text: "Блюдо не найдено"),
            logger: logger
        )
        return
    }

    let markup = TelegramInlineKeyboardMarkup(inlineKeyboard: [
        [
            TelegramInlineKeyboardButton(text: "🗑 Да, удалить", callbackData: "dish:delete_confirm:\(dishIDString)"),
            TelegramInlineKeyboardButton(text: "❌ Отмена", callbackData: "dish:delete_cancel")
        ]
    ])
    try await client.answerCallbackQuery(
        TelegramAnswerCallbackQueryRequest(callbackQueryID: callbackQueryID, text: "Подтвердите удаление"),
        logger: logger
    )
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Удалить блюдо «\(dish.title)»? Это действие необратимо.",
            replyMarkup: markup
        ),
        logger: logger
    )
}

func handleDishDeleteConfirmCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    dishIDString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }

    guard let dishID = UUID(uuidString: dishIDString),
          let dish = try await Dish.find(dishID, on: req.db),
          dish.$cook.id == user.id else {
        try await client.answerCallbackQuery(
            TelegramAnswerCallbackQueryRequest(callbackQueryID: callbackQueryID, text: "Блюдо не найдено"),
            logger: logger
        )
        return
    }

    try await dish.delete(on: req.db)

    try await client.answerCallbackQuery(
        TelegramAnswerCallbackQueryRequest(callbackQueryID: callbackQueryID, text: "Блюдо удалено"),
        logger: logger
    )
}

func handleDishEditCallback(
    telegramUserID: Int64,
    chatID: Int64,
    callbackQueryID: String,
    dishIDString: String,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db) else {
        return
    }

    guard let dishID = UUID(uuidString: dishIDString),
          let dish = try await Dish.find(dishID, on: req.db),
          dish.$cook.id == user.id else {
        try await client.answerCallbackQuery(
            TelegramAnswerCallbackQueryRequest(callbackQueryID: callbackQueryID, text: "Блюдо не найдено"),
            logger: logger
        )
        return
    }

    try await ConversationService.startEditDish(for: telegramUserID, dishID: dishID, on: req.db)

    try await client.answerCallbackQuery(
        TelegramAnswerCallbackQueryRequest(callbackQueryID: callbackQueryID, text: "Начинаем"),
        logger: logger
    )
    try await client.sendMessage(
        TelegramSendMessageRequest(
            chatID: chatID,
            text: "Введите новое название блюда (или отправьте '-' чтобы оставить текущее):",
            replyMarkup: nil
        ),
        logger: logger
    )
}

func sendMyAddresses(
    telegramUserID: Int64,
    chatID: Int64,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          let userID = user.id else {
        try await sendRoleSelection(
            telegramUserID: telegramUserID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )
        return
    }

    let addresses = try await Address.query(on: req.db)
        .filter(\.$user.$id == userID)
        .sort(\.$createdAt, .descending)
        .all()

    if addresses.isEmpty {
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: "У вас пока нет сохранённых адресов. Добавьте через «Мой адрес» или кнопку «📍 Поделиться геолокацией».",
                replyMarkup: nil
            ),
            logger: logger
        )
        return
    }

    for address in addresses {
        let defaultMark = address.isDefault == true ? " ⭐" : ""
        let text = "📍 \(address.name)\(defaultMark)\n\(address.text)"
        var rows: [[TelegramInlineKeyboardButton]] = []
        rows.append([
            TelegramInlineKeyboardButton(
                text: "Удалить",
                callbackData: "address:delete:\(address.id?.uuidString ?? "")"
            )
        ])
        if address.isDefault != true {
            rows.append([
                TelegramInlineKeyboardButton(
                    text: "По умолчанию",
                    callbackData: "address:default:\(address.id?.uuidString ?? "")"
                )
            ])
        }
        try await client.sendMessage(
            TelegramSendMessageRequest(
                chatID: chatID,
                text: text,
                replyMarkup: TelegramInlineKeyboardMarkup(inlineKeyboard: rows)
            ),
            logger: logger
        )
    }
}

func sendFavoriteDishes(
    telegramUserID: Int64,
    chatID: Int64,
    req: Vapor.Request,
    client: TelegramBotClient,
    logger: Logger
) async throws {
    guard let user = try await BotUserService.findByTelegramID(telegramUserID, on: req.db),
          let userID = user.id else {
        try await sendRoleSelection(
            telegramUserID: telegramUserID,
            chatID: chatID,
            req: req,
            client: client,
            logger: logger
        )
        return
    }

    guard user.typedRole == .client else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "Только для клиентов", replyMarkup: nil),
            logger: logger
        )
        return
    }

    let favorites = try await Favorite.query(on: req.db)
        .filter(\.$client.$id == userID)
        .with(\.$dish)
        .all()

    guard !favorites.isEmpty else {
        try await client.sendMessage(
            TelegramSendMessageRequest(chatID: chatID, text: "В избранном пока пусто. Нажмите «В избранное» на карточке блюда.", replyMarkup: nil),
            logger: logger
        )
        return
    }

    for (index, favorite) in favorites.enumerated() {
        let dish = favorite.dish
        let cookName = (try await User.find(dish.$cook.id, on: req.db))?.firstName ?? "Повар"
        var text = """
        Блюдо «\(dish.title)»
        \(dish.details ?? "Без описания")
        Цена: \(formatPrice(dish.price)) руб.
        Повар: \(cookName)
        """
        if dish.isActive == false {
            text += "\n🔴 Блюдо сейчас скрыто"
        }
        let markup = TelegramInlineKeyboardMarkup(inlineKeyboard: [
            [
                TelegramInlineKeyboardButton(
                    text: "Заказать #\(index + 1)",
                    callbackData: "order:create:\(dish.id?.uuidString ?? "")"
                )
            ],
            [
                TelegramInlineKeyboardButton(
                    text: "Убрать из избранного",
                    callbackData: "dish:fav:\(dish.id?.uuidString ?? "")"
                )
            ]
        ])
        if let photoFileID = dish.photoFileID {
            try await client.sendPhoto(
                TelegramSendPhotoRequest(chatID: chatID, photo: photoFileID, caption: text, replyMarkup: markup),
                logger: logger
            )
        } else {
            try await client.sendMessage(
                TelegramSendMessageRequest(chatID: chatID, text: text, replyMarkup: markup),
                logger: logger
            )
        }
    }
}
