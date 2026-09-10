// Service worker больше не используется: при активации эта версия
// удаляет все кэши и снимает себя с регистрации. Страница всегда
// работает напрямую с сервером — никакого устаревшего кэша.
self.addEventListener('install', e => {
  self.skipWaiting();
});

self.addEventListener('activate', e => {
  e.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.map(k => caches.delete(k)));
    await self.registration.unregister();
    await self.clients.claim();
  })());
});
