# Povar

Telegram bot backend on Swift Vapor for connecting home cooks and clients.

## Run locally

```bash
cp .env.example .env
swift run Povar migrate
swift run
```

Server starts on `http://127.0.0.1:8080` by default.

## Environment variables

- `DATABASE_URL` - optional PostgreSQL connection string.
- `TELEGRAM_BOT_TOKEN` - required token from @BotFather.
- `TELEGRAM_WEBHOOK_SECRET` - optional secret for webhook URL validation.

## Webhook endpoint

`POST /telegram/webhook`

or

`POST /telegram/webhook/:secret`

If `TELEGRAM_WEBHOOK_SECRET` is set, request must be sent to
`/telegram/webhook/:secret` and `:secret` must match this value.

Example Telegram webhook URL:

`https://your-domain.com/telegram/webhook/<secret>`

## Configure webhook in Telegram

```bash
curl -X POST "https://api.telegram.org/bot<TELEGRAM_BOT_TOKEN>/setWebhook" \
  -d "url=https://your-domain.com/telegram/webhook/<secret>"
```

After this, send `/start` to the bot. It will show role buttons:
- `Я клиент`
- `Я повар`

Current commands:
- `/start` - role selection
- `/menu` - role-specific menu (client/cook)
- `/cancel` - cancel current input scenario (for example, add dish flow)

Implemented flow:
- Cook can add a dish from menu: `Добавить блюдо`.
- Bot asks for title -> description -> price and saves to DB.
- Client can open `Найти блюда рядом` and see latest dishes.
- Client can create an order from dish card (`Заказать`) with confirmation step.
- Cook can open `Заказы повара` and move order status.
- Client can open `Мои заказы` and see current statuses.
- Client can cancel active order from `Мои заказы`.
- Main role menu is shown as Telegram reply keyboard (bottom buttons).
- Nearby search uses geolocation with a 10 km radius and keyword/price/type filters.
- Notification preferences: users can mute proactive pushes (new dish from
  a followed cook) and set quiet hours from `🔔 Уведомления`. Order-status
  updates are always delivered regardless of quiet hours.

## Next implementation steps

1. Quiet hours currently use the server's local time, not the user's own
   timezone — add per-user timezone if the audience spans multiple regions.
