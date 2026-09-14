import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import Vapor

public func configure(_ app: Application) async throws {
    // Сессии для веб-авторизации через Telegram Login Widget (/auth/telegram)
    app.sessions.use(.memory)
    app.middleware.use(app.sessions.middleware)

    // Каталог для фото блюд, загружаемых из Mini App
    let uploadsDir = app.directory.publicDirectory + "uploads/"
    try? FileManager.default.createDirectory(atPath: uploadsDir, withIntermediateDirectories: true)

    if let postgresURL = Environment.get("DATABASE_URL") {
        app.databases.use(
            try .postgres(url: postgresURL),
            as: .psql
        )
    } else {
        app.databases.use(.sqlite(.file("povar.sqlite")), as: .sqlite)
    }

    try registerMigrations(app)

    if let botToken = Environment.get("TELEGRAM_BOT_TOKEN"), !botToken.isEmpty {
        let client = TelegramBotClient(app: app, botToken: botToken)
        try? await client.setMyCommands(logger: app.logger)
        // Режим доставки апдейтов:
        // - TELEGRAM_POLLING=true — всегда long-polling (по умолчанию, как было);
        // - иначе long-polling отключается, если задан TELEGRAM_WEBHOOK_SECRET
        //   (вебхук настраивается через setWebhook, см. README).
        let forcePolling = Environment.get("TELEGRAM_POLLING") == "true"
        if forcePolling || Environment.get("TELEGRAM_WEBHOOK_SECRET") == nil {
            app.lifecycle.use(BotPoller(app: app, client: client))
        } else {
            app.logger.info("webhook mode: long polling disabled")
        }
    }

    try routes(app)
}

/// Регистрация миграций вынесена отдельно, чтобы её можно было
/// переиспользовать в тестах с in-memory базой.
func registerMigrations(_ app: Application) throws {
    app.migrations.add(CreateUser())
    app.migrations.add(CreateDish())
    app.migrations.add(CreateOrder())
    app.migrations.add(AddLocationToUser())
    app.migrations.add(AddRatingToOrder())
    app.migrations.add(AddPickupFields())
    app.migrations.add(AddDeliveryFields())
    app.migrations.add(AddDishPhotoAndCookStatus())
    app.migrations.add(CreateFavorite())
    app.migrations.add(AddTodayAndReviews())
    app.migrations.add(CreateSubscription())
    app.migrations.add(AddOrderEnhancements())
    app.migrations.add(AddOrderQuantity())
    app.migrations.add(AddBalanceToUser())
    app.migrations.add(CreateAddress())
    app.migrations.add(CreateWaitlistEntry())
    app.migrations.add(AddOrderShippingAddress())
    app.migrations.add(CreateCartItem())
    app.migrations.add(CreateOrderItem())
    app.migrations.add(AddReferralToUser())
    app.migrations.add(AddSearchFiltersToUser())
    app.migrations.add(AddDishType())
    app.migrations.add(AddBonusAwardedToOrder())
    app.migrations.add(AddOrderBalanceAndVoiceAndPromo())
    app.migrations.add(CreatePromoCode())
    app.migrations.add(AddNotificationPreferences())
    app.migrations.add(AddProfileFieldsToUser())
    app.migrations.add(AddDishPhotoPath())
    app.migrations.add(AddUserTimezone())
    app.migrations.add(AddProfilePhotoPath())
    app.migrations.add(AddDishNutrition())
    app.migrations.add(AddOrderDeliveryCoords())
}
