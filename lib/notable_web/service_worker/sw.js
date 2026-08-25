// Notable service worker - app shell cache for the audience pages.
//
// Served by NotableWeb.ServiceWorkerController at /sw.js. The CONFIG literal
// below is substituted by NotableWeb.ServiceWorker from the digest manifest
// (`mix phx.digest`), so the precache list is never maintained by hand and the
// cache name changes whenever a build ships different assets.
//
// Strategy (see docs/superpowers/specs/2026-08-25-offline-submission-design.md):
//   * shell documents (`/`, `/questions`): network-first with a bounded wait,
//     cache fallback - fresh when the network allows, cached when it does not.
//   * digested static assets: cache-first - content-hashed, so immutable.
//   * everything else (LiveView socket, /admin, webhooks, dev, other pages):
//     untouched - the browser talks to the network as if no worker existed.
//
// Kill switch: docs/OPERATIONS.md#service-worker.

const CONFIG = __NOTABLE_SW_CONFIG__;

const CACHE_PREFIX = "notable-";
const CACHE = CACHE_PREFIX + CONFIG.stamp;
const SHELL = new Set(CONFIG.shell);
const PRECACHE = new Set(CONFIG.precache);
const NEVER_CACHE = CONFIG.never_cache;
const NETWORK_TIMEOUT_MS = CONFIG.network_timeout_ms;

// `name-<md5>.ext` as written by `mix phx.digest`.
const DIGESTED = /-[0-9a-f]{32}\.[a-z0-9]+$/i;
// Digested assets are requested with `?vsn=d`; the name alone identifies them.
const MATCH_OPTS = {ignoreSearch: true, ignoreVary: true};

self.addEventListener("install", event => {
  event.waitUntil(
    (async () => {
      const cache = await caches.open(CACHE);
      // Best effort on purpose: this runs on the same bad wifi the cache is
      // for. A failed fetch must not fail the install, and cache-first fills
      // any asset that is missing the first time the page asks for it.
      await Promise.allSettled([
        ...CONFIG.precache.map(path => precacheAsset(cache, path)),
        ...CONFIG.shell.map(path => precacheShell(cache, path)),
      ]);
      await self.skipWaiting();
    })(),
  );
});

self.addEventListener("activate", event => {
  event.waitUntil(
    (async () => {
      const names = await caches.keys();
      await Promise.all(
        names
          .filter(name => name.startsWith(CACHE_PREFIX) && name !== CACHE)
          .map(name => caches.delete(name)),
      );
      await self.clients.claim();
    })(),
  );
});

self.addEventListener("fetch", event => {
  const request = event.request;
  if (request.method !== "GET") return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;
  if (neverCache(url.pathname)) return;

  if (request.mode === "navigate") {
    if (SHELL.has(url.pathname)) event.respondWith(networkFirst(request, url.pathname));
    return;
  }

  if (PRECACHE.has(url.pathname) || DIGESTED.test(url.pathname)) {
    event.respondWith(cacheFirst(request));
  }
});

function neverCache(pathname) {
  return NEVER_CACHE.some(prefix => pathname === prefix || pathname.startsWith(prefix + "/"));
}

async function precacheAsset(cache, path) {
  const response = await fetch(path, {cache: "no-cache"});
  if (cacheable(response)) await cache.put(path, response);
}

async function precacheShell(cache, path) {
  try {
    const response = await fetch(path, {cache: "no-cache"});
    if (cacheable(response)) {
      await cache.put(path, response);
      return;
    }
  } catch (_error) {
    // fall through: keep whatever an earlier build had cached
  }
  const previous = await caches.match(path, MATCH_OPTS);
  if (previous) await cache.put(path, previous);
}

// Shell documents. The network request keeps running after the timeout so a
// slow-but-alive connection still refreshes the cache for next time.
async function networkFirst(request, key) {
  const cache = await caches.open(CACHE);

  const network = fetch(request).then(async response => {
    if (cacheable(response)) await cache.put(key, response.clone());
    return response;
  });
  const timeout = new Promise(resolve => setTimeout(() => resolve(null), NETWORK_TIMEOUT_MS));

  const first = await Promise.race([network.catch(() => null), timeout]);
  if (first) return first;

  const cached = await cache.match(key, MATCH_OPTS);
  if (cached) return cached;

  try {
    return await network;
  } catch (_error) {
    return Response.error();
  }
}

// Digested assets: once fetched, immutable.
async function cacheFirst(request) {
  const cache = await caches.open(CACHE);
  const cached = await cache.match(request, MATCH_OPTS);
  if (cached) return cached;

  const response = await fetch(request);
  if (cacheable(response)) await cache.put(request, response.clone());
  return response;
}

function cacheable(response) {
  return Boolean(response) && response.ok && response.type === "basic" && !response.redirected;
}
