// Newberry Coop Diary service worker: keeps the app available offline.
const SHELL = "coop-shell-v1";
const FILES = ["newberry-coop.html", "manifest-coop.webmanifest", "icons/coop-192.png", "icons/coop-512.png"];
self.addEventListener("install", e => {
  e.waitUntil(caches.open(SHELL).then(c => c.addAll(FILES)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k.startsWith("coop-") && k !== SHELL).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener("fetch", e => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== location.origin || !FILES.some(f => url.pathname.endsWith("/" + f))) return;
  e.respondWith(
    fetch(req)
      .then(res => { const copy = res.clone(); caches.open(SHELL).then(c => c.put(req, copy)); return res; })
      .catch(() => caches.match(req).then(r => r || caches.match("newberry-coop.html")))
  );
});
