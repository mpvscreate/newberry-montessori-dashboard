const CACHE_NAME = 'newberry-v4';
const FLAG = '/__sw-upgrade';
const ASSETS = [
  '/',
  '/index.html',
  '/team-roles-card.html',
  '/manifest.json',
  '/icons/icon-192.png',
  '/icons/icon-512.png'
];

self.addEventListener('install', e => {
  /* remember whether this install replaces an older worker, so open pages can be refreshed once */
  const replacing = !!self.registration.active;
  e.waitUntil(
    caches.open(CACHE_NAME).then(c => Promise.all([
      c.addAll(ASSETS).catch(() => {}),
      c.put(FLAG, new Response(replacing ? '1' : '0'))
    ])).catch(() => {})
  );
  self.skipWaiting();
});

self.addEventListener('activate', e => {
  e.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k)));
    await self.clients.claim();
    let replacing = false;
    try {
      const c = await caches.open(CACHE_NAME), r = await c.match(FLAG);
      replacing = !!r && (await r.text()) === '1';
      if (r) await c.put(FLAG, new Response('0'));
    } catch {}
    if (replacing) {
      /* an older version was running: reload open pages once so nobody stays on a stale copy */
      const wins = await self.clients.matchAll({ type: 'window' });
      wins.forEach(w => { try { w.navigate(w.url); } catch {} });
    }
  })());
});

self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  if (/\/(rest|auth|storage)\/v1\//.test(e.request.url)) return; // never cache Supabase API responses
  e.respondWith(
    fetch(e.request).then(res => {
      if (res && res.status === 200) {
        const clone = res.clone();
        caches.open(CACHE_NAME).then(c => c.put(e.request, clone));
      }
      return res;
    }).catch(() => caches.match(e.request))
  );
});
