const CACHE = 'quem-sou-eu-v3';
const ASSETS = ['/', '/index.html', '/manifest.webmanifest', '/icons/icon.svg'];
self.addEventListener('install', e => { self.skipWaiting(); e.waitUntil(caches.open(CACHE).then(c => c.addAll(ASSETS))); });
self.addEventListener('activate', e => e.waitUntil(
  caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim())
));
self.addEventListener('fetch', e => {
  const req = e.request;
  const url = new URL(req.url);
  // Só o próprio site: respostas da API do Supabase (dados privados) e /api nunca vão para o cache.
  if (req.method !== 'GET' || url.origin !== self.location.origin || url.pathname.startsWith('/api/')) return;
  e.respondWith(fetch(req).then(r => {
    if (r.ok) { const clone = r.clone(); caches.open(CACHE).then(c => c.put(req, clone)); }
    return r;
  }).catch(() => caches.match(req).then(m => m || (req.mode === 'navigate' ? caches.match('/index.html') : undefined))));
});

// Notificações push (convites). Se o jogo já está aberto e visível, o aviso aparece dentro do app.
self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch { d = { body: e.data && e.data.text() }; }
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
    if (list.some(c => c.visibilityState === 'visible')) return;
    return self.registration.showNotification(d.title || 'Quem Sou Eu?', {
      body: d.body || '', icon: '/icons/icon.svg', badge: '/icons/icon.svg', tag: d.tag, renotify: true,
      vibrate: [200, 100, 200], data: { url: d.url || '/' },
    });
  }));
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const target = new URL(e.notification.data?.url || '/', self.location.origin).href;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
    const c = list.find(x => new URL(x.url).origin === self.location.origin);
    if (c) return c.focus().then(w => (w || c).navigate(target));
    return self.clients.openWindow(target);
  }));
});
