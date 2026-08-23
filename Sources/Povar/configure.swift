import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import Vapor

public func configure(_ app: Application) async throws {
    if let postgresURL = Environment.get("DATABASE_URL") {
        app.databases.use(
            try .postgres(url: postgresURL),
            as: .psql
        )
    } else {
        app.databases.use(.sqlite(.file("povar.sqlite")), as: .sqlite)
    }

    app.migrations.add(CreateUser())
    app.migrations.add(CreateDish())
    app.migrations.add(CreateOrder())
    app.migrations.add(CreateConversationState())
    app.migrations.add(AddLocationToUser())
    app.migrations.add(AddDraftDishIDToConversationState())
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
    app.migrations.add(AddDraftVoiceToConversationState())
    app.migrations.add(CreatePromoCode())

    if let botToken = Environment.get("TELEGRAM_BOT_TOKEN"), !botToken.isEmpty {
        let client = TelegramBotClient(app: app, botToken: botToken)
        try? await client.setMyCommands(logger: app.logger)
        app.lifecycle.use(BotPoller(app: app, client: client))
    }

    try routes(app)
}
