#!/usr/bin/env bash
# Запускать на сервере (Ubuntu), находясь в папке проекта.
set -e

if ! command -v docker >/dev/null 2>&1; then
  echo ">>> Устанавливаем Docker..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
fi

echo ">>> Сборка и запуск..."
docker compose -f docker-compose.server.yml up --build -d

echo ">>> Контейнеры:"
docker compose -f docker-compose.server.yml ps

echo ">>> Логи (Ctrl+C выйдет, контейнер продолжит работать):"
docker compose -f docker-compose.server.yml logs -f app
