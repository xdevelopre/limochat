const CACHE_NAME = 'limo-chat-v2.01-shell';
const APP_SHELL = [
  './',
  './index.html',
  './limo-v2.js',
  './manifest.json',
  './favicon.svg',
  './icon-192.png',
  './icon-512.png'
];

self.addEventListener('install', event => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE_NAME);
    await cache.addAll(APP_SHELL);
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter(key => key !== CACHE_NAME).map(key => caches.delete(key)));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', event => {
  const request = event.request;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) {
    // Supabase JS is loaded as an ES module from esm.sh. Cache that SDK after
    // the first successful online load so the shell can boot while offline.
    if (url.hostname === 'esm.sh' && url.pathname.startsWith('/@supabase/supabase-js')) {
      event.respondWith((async () => {
        const cache = await caches.open(CACHE_NAME);
        try {
          const response = await fetch(request);
          if (response.ok) await cache.put(request, response.clone());
          return response;
        } catch {
          return (await cache.match(request)) || new Response('Supabase SDK is not cached yet. Connect once to the internet and reopen the app.', { status: 503, statusText: 'Offline SDK unavailable' });
        }
      })());
    }
    return;
  }

  // Always try the network first for app code so deployments update promptly.
  if (request.mode === 'navigate' || /\/(index\.html|limo-v2\.js|manifest\.json)$/.test(url.pathname)) {
    event.respondWith((async () => {
      try {
        const response = await fetch(request);
        if (response.ok) {
          const cache = await caches.open(CACHE_NAME);
          cache.put(request, response.clone());
        }
        return response;
      } catch {
        return (await caches.match(request)) || (await caches.match('./index.html'));
      }
    })());
    return;
  }

  event.respondWith((async () => {
    const cached = await caches.match(request);
    if (cached) return cached;
    try {
      const response = await fetch(request);
      if (response.ok) {
        const cache = await caches.open(CACHE_NAME);
        cache.put(request, response.clone());
      }
      return response;
    } catch {
      return new Response('Offline', { status: 503, statusText: 'Offline' });
    }
  })());
});
