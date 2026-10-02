const CACHE = 'quem-sou-eu-v1';
const ASSETS = ['/', '/index.html', '/manifest.webmanifest', '/icons/icon.svg'];
self.addEventListener('install', e => e.waitUntil(caches.open(CACHE).then(c => c.addAll(ASSETS))));
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  e.respondWith(fetch(e.request).then(r => {
    const clone = r.clone(); caches.open(CACHE).then(c => c.put(e.request, clone)); return r;
  }).catch(() => caches.match(e.request)));
});
