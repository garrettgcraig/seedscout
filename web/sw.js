/* SeedFinder offline support.

   A field tool has to answer at the trailhead, where there is often no signal.
   This keeps three things:
   - the app itself (page, fonts, icons), refreshed from the network whenever
     there is one, so a deploy is picked up on the next online visit;
   - the map library from its CDN, which is versioned and never changes;
   - the species data for areas already looked at (tiles, observation sidecars,
     the name index), served from the cache at once and refreshed in the
     background. Capped, oldest first, so storage stays bounded.

   Basemap tiles are deliberately not cached: OpenStreetMap's tile policy asks
   apps not to store tiles for offline use, and the search works without them.
   Bump VERSION when the shell list changes. */
const VERSION = 'seedfinder-shell-v1';
const DATA = 'seedfinder-data-v1';
const LIBS = 'seedfinder-libs-v1';
const MAX_DATA_ENTRIES = 48;

const SHELL = ['./', './fonts/fraunces.woff2', './fonts/inter.woff2', './favicon.svg',
               './manifest.webmanifest', './icons/icon-192.png', './icons/apple-touch-icon.png',
               './tiles_conus/index.json'];
const LIB_HOSTS = ['unpkg.com'];

self.addEventListener('install', e => {
  e.waitUntil((async () => {
    const cache = await caches.open(VERSION);
    // One missing file should not stop the rest from being cached.
    await Promise.all(SHELL.map(u => cache.add(u).catch(() => {})));
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', e => {
  e.waitUntil((async () => {
    const keep = new Set([VERSION, DATA, LIBS]);
    for (const k of await caches.keys()) if (!keep.has(k)) await caches.delete(k);
    await self.clients.claim();
  })());
});

const isData = url => /\/(tiles_[a-z]+|obs_[a-z]+)\//.test(url.pathname) || /\/names_[a-z]+\.json$/.test(url.pathname);

async function trim(cacheName, max){
  const cache = await caches.open(cacheName);
  const keys = await cache.keys();
  for (let i = 0; i < keys.length - max; i++) await cache.delete(keys[i]);
}

async function networkFirst(req, cacheName){
  const cache = await caches.open(cacheName);
  try {
    const res = await fetch(req);
    if (res.ok) cache.put(req, res.clone());
    return res;
  } catch (err) {
    const hit = await cache.match(req, {ignoreSearch: req.mode === 'navigate'});
    if (hit) return hit;
    throw err;
  }
}

async function staleWhileRevalidate(req, cacheName, event){
  const cache = await caches.open(cacheName);
  const hit = await cache.match(req);
  const refresh = fetch(req).then(async res => {
    if (res.ok){
      await cache.delete(req);          // re-insert so it counts as recently used
      await cache.put(req, res.clone());
      await trim(cacheName, MAX_DATA_ENTRIES);
    }
    return res;
  });
  if (hit){ event.waitUntil(refresh.catch(() => {})); return hit; }
  return refresh;
}

async function cacheFirst(req, cacheName){
  const cache = await caches.open(cacheName);
  const hit = await cache.match(req);
  if (hit) return hit;
  const res = await fetch(req);
  if (res.ok || res.type === 'opaque') cache.put(req, res.clone());
  return res;
}

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);

  if (url.origin === location.origin){
    if (!url.pathname.startsWith(new URL('./', location.href).pathname)) return;
    if (url.pathname.endsWith('/sw.js')) return;
    if (url.pathname.endsWith('/tiles_conus/index.json')) { e.respondWith(networkFirst(req, VERSION)); return; }
    if (isData(url)) { e.respondWith(staleWhileRevalidate(req, DATA, e)); return; }
    // The page, fonts, icons: fresh when online, cached when not.
    e.respondWith(networkFirst(req, VERSION));
    return;
  }
  if (LIB_HOSTS.includes(url.hostname)) e.respondWith(cacheFirst(req, LIBS));
});
