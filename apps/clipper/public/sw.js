// Service worker app.{domain} (F-C14): web push (payload {title, body, url} dari identity bridge send_push) +
// halaman /offline saat navigasi gagal. Tidak meng-cache data user.
const CACHE = 'clipper-offline-v1';
const OFFLINE = '/offline';

async function precacheOffline() {
  const cache = await caches.open(CACHE);
  const res = await fetch(OFFLINE, { cache: 'reload', credentials: 'omit' });
  if (!res.ok) return;
  const html = await res.clone().text();
  await cache.put(OFFLINE, res);
  // CSS halaman offline ikut disimpan supaya tetap bergaya tanpa koneksi.
  const css = [...html.matchAll(/href="(\/_next\/static\/[^"]+\.css)"/g)].map((m) => m[1]);
  await Promise.all(css.map((href) => cache.add(href).catch(() => {})));
}

self.addEventListener('install', (event) => {
  event.waitUntil(precacheOffline().catch(() => {}).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  if (req.mode === 'navigate') {
    event.respondWith(fetch(req).catch(() => caches.match(OFFLINE).then((r) => r || Response.error())));
  } else if (url.pathname.startsWith('/_next/static/') && url.pathname.endsWith('.css')) {
    event.respondWith(fetch(req).catch(() => caches.match(req).then((r) => r || Response.error())));
  }
});

function safeUrl(raw) {
  try {
    const u = new URL(raw || '/campaigns', self.location.origin);
    return u.protocol === 'https:' || u.origin === self.location.origin ? u.href : new URL('/campaigns', self.location.origin).href;
  } catch {
    return new URL('/campaigns', self.location.origin).href;
  }
}

self.addEventListener('push', (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch {
    data = { body: event.data ? event.data.text() : '' };
  }
  const title = typeof data.title === 'string' && data.title ? data.title.slice(0, 120) : 'Clipper';
  event.waitUntil(
    self.registration.showNotification(title, {
      body: typeof data.body === 'string' ? data.body.slice(0, 240) : '',
      icon: '/icons/icon-192.png',
      badge: '/icons/badge-96.png',
      tag: typeof data.tag === 'string' ? data.tag : undefined,
      data: { url: safeUrl(data.url) },
    }),
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const target = safeUrl(event.notification.data && event.notification.data.url);
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
      const same = new URL(target).origin === self.location.origin;
      for (const client of list) {
        if (same && new URL(client.url).origin === self.location.origin && 'focus' in client) {
          return client.focus().then((c) => (c && 'navigate' in c ? c.navigate(target) : c));
        }
      }
      return self.clients.openWindow(target);
    }),
  );
});
