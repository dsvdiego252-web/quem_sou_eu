const CACHE = 'quem-sou-eu-v2';
const ASSETS = ['/', '/index.html', '/manifest.webmanifest', '/icons/icon.svg'];
self.addEventListener('install', e => { self.skipWaiting(); e.waitUntil(caches.open(CACHE).then(c => c.addAll(ASSETS))); });
self.addEventListener('activate', e => e.waitUntil(
  caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim())
));
self.addEventListener('fetch', e => {
  const req = e.request;
  // Só o próprio site: respostas da API do Supabase (dados privados) nunca vão para o cache.
  if (req.method !== 'GET' || new URL(req.url).origin !== self.location.origin) return;
  e.respondWith(fetch(req).then(r => {
    if (r.ok) { const clone = r.clone(); caches.open(CACHE).then(c => c.put(req, clone)); }
    return r;
  }).catch(() => caches.match(req).then(m => m || (req.mode === 'navigate' ? caches.match('/index.html') : undefined))));
});
