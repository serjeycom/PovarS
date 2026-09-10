# Povar

Сервис домашней еды: платформа на Swift Vapor, связывающая домашних поваров и клиентов.

## Архитектура

- **Mini App** (`/app`) — основная точка взаимодействия: каталог блюд, поиск и
  фильтры, корзина, заказы, избранное, профиль, поварской раздел
  (блюда, заказы со сменой статусов, промокоды, статистика), настройки
  уведомлений.
- **Telegram-бот** (`/telegram/webhook` или long-polling) — работает только как
  канал уведомлений: новые заказы повару, смена статуса заказа клиенту,
  новые блюда у поваров, на которые подписан клиент, лист ожидания,
  оплата звёздами и напоминания. Вся интерактивность — в Mini App.
- **Лендинг** (`/`) — вход через Telegram Login Widget.
- **Админ-панель** (`/admin`) — доступ по токену `ADMIN_TOKEN`.

## Run locally

```bash
cp .env.example .env
swift run Povar migrate
swift run
```

Сервер стартует на `http://127.0.0.1:8080` по умолчанию.

## Environment variables

- `DATABASE_URL` — опциональная строка подключения PostgreSQL (по умолчанию SQLite `povar.sqlite`).
- `TELEGRAM_BOT_TOKEN` — обязательный токен от @BotFather.
- `TELEGRAM_WEBHOOK_SECRET` — опциональный секрет для валидации webhook-URL.
- `ADMIN_TOKEN` — обязательный токен для админ-панели (`/admin`).
- `MINI_APP_URL` — публичный URL Mini App для кнопки «Открыть каталог» в боте.
- `BOT_USERNAME` — ник бота для ссылок `t.me/<bot>`.

## Webhook endpoint

`POST /telegram/webhook` или `POST /telegram/webhook/:secret`

Если `TELEGRAM_WEBHOOK_SECRET` задан, запрос должен идти на
`/telegram/webhook/:secret`, и `:secret` должен совпадать с этим значением.

Пример настройки webhook:

```bash
curl -X POST "https://api.telegram.org/bot<TELEGRAM_BOT_TOKEN>/setWebhook" \
  -d "url=https://your-domain.com/telegram/webhook/<secret>"
```

## Bot

Бот — это только чат сообщений, уведомлений и рекламы. Он отвечает на
`/start` и `/menu` кнопкой «Открыть каталог», принимает реферальные ссылки
`/start CODE`, а в остальном отправляет:

- **сообщения**: инвойсы оплаты звёздами, подтверждения;
- **уведомления**: повару — новый заказ, отмена, оплата, лист ожидания;
  клиенту — смена статуса заказа, напоминание о готовом заказе,
  «повар готовит сегодня», пополнение блюда из листа ожидания;
- **рекламу**: рассылки из админ-панели (`/admin` → «Рассылка»),
  с учётом настроек уведомлений и тихих часов пользователей.

Тихие часы и отключение уведомлений настраиваются в Mini App
(профиль → 🔔 Уведомления) и учитывают часовой пояс пользователя
(определяется автоматически на клиенте). Статусы заказов приходят всегда.

## Mini App API

Основные группы `/api/v1`:

- `GET /browse?q=&category=&maxPrice=&city=&sort=&todayOnly=&photoOnly=&page=` — каталог
- `GET /cities` — города поваров
- `GET /api/v1/uploads/:fileId` — прокси фото из Telegram (с кэшем URL)
- `GET|PUT /me`, `POST /me/photo` (аватар), `GET|PUT /notification-settings`, `PUT /location`
- `GET|POST /dishes`, `GET|PUT|DELETE /dishes/:id`,
  `POST /dishes/:id/today|untoday|toggle|photo|waitlist`, `GET /my-dishes`
- `GET|POST /cart`, `PUT|DELETE /cart/:id`
- `GET|POST /orders`, `POST /orders/:id/cancel|status|rate`, `GET /cook-orders`
- `GET|POST /favorites`, `POST /favorites/:id`
- `GET /cook/:id`, `POST /cook/:id/subscribe|unsubscribe`
- `GET|POST /promos`, `POST /promos/:id/toggle`, `GET /cook-stats`

Админ-API (`/api/v1/admin/*`, токен `ADMIN_TOKEN`): статистика, пользователи,
блюда, заказы, `POST /broadcast` — рекламная рассылка в чат бота.

Авторизация — `X-Telegram-Init-Data` (Mini App) или сессия (`/auth/telegram` для сайта).

## Next implementation steps

1. Частичная предоплата звёздами (сейчас инвойс на полную сумму, наличные — опция при получении).
2. Расширенная реклама: картинки/кнопки в рассылке, авто-промо новых блюд.
3. Мультиязычность интерфейса (сейчас только русский).
