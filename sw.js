/* ══════════════════════════════════════════════════════════════════
   bich.service — service worker
   Purpose: never show a stale app again.

   Why this is needed on GitHub Pages specifically: Pages sets its own
   cache headers and you cannot change them, so the browser is free to
   hold an old index.html. An iPhone homescreen icon is worse again,
   because it keeps its own long lived cache and does not refresh the
   way a tab does.

   Strategy:
     HTML  -> network first. Always try the network. Fall back to
              cache only when genuinely offline.
     assets-> stale while revalidate. Instant, and updated behind you.

   Bump CACHE_VERSION on every release. That is the whole ritual.
   ══════════════════════════════════════════════════════════════════ */

const CACHE_VERSION = '2026-08-03-54';
const CACHE = `bich-${CACHE_VERSION}`;

self.addEventListener('install', (e) => {
  // Take over immediately rather than waiting for every old tab to close.
  self.skipWaiting();
});

self.addEventListener('activate', (e) => {
  e.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;

  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;   // never touch API calls

  const isDoc = req.mode === 'navigate' ||
                (req.headers.get('accept') || '').includes('text/html');

  // config.js carries the addresses and keys the app runs on, so it
  // must never be served from a stale cache. Same rule as the document.
  const isConfig = url.pathname.endsWith('/config.js');

  if (isDoc || isConfig) {
    // NETWORK FIRST: the document is the thing that goes stale.
    e.respondWith((async () => {
      try {
        const fresh = await fetch(req, { cache: 'no-store' });
        // Only cache a good response. Without this a 404 or a 502 from
        // Pages becomes the offline copy of your app.
        if (fresh && fresh.ok) {
          const cache = await caches.open(CACHE);
          cache.put(req, fresh.clone());
        }
        return fresh;
      } catch (_) {
        /* caches.match() returns a PROMISE, which is always truthy, so
           the offline Response below was dead code and this expression
           could resolve to undefined - respondWith(undefined) rejects
           and the browser shows its own network error instead. Await
           each candidate. Also '/' is the cache key for a navigation,
           not '/index.html'. */
        return (await caches.match(req))
            || (await caches.match('/'))
            || (await caches.match('/index.html'))
            || new Response('offline', { status: 503, headers: { 'Content-Type': 'text/plain' } });
      }
    })());
    return;
  }

  // STALE WHILE REVALIDATE for everything else.
  e.respondWith((async () => {
    const cache = await caches.open(CACHE);
    const hit = await cache.match(req);
    const net = fetch(req).then(res => {
      if (res && res.ok) cache.put(req, res.clone());
      return res;
    }).catch(() => null);
    // same trap: `net` is a promise and always truthy, so the 504 never
    // fired and a failed fetch handed respondWith a null.
    return hit || (await net) || new Response('', { status: 504 });
  })());
});

// The page can ask us to hand over immediately after an update.
self.addEventListener('message', (e) => {
  if (e.data === 'skip-waiting') self.skipWaiting();
});
