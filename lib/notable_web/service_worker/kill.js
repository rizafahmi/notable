// Notable service worker - kill switch.
//
// Served at /sw.js instead of the real worker when NOTABLE_SERVICE_WORKER=off
// (docs/OPERATIONS.md#service-worker). The browser sees a byte-different
// script, installs it in place of the running worker, and this one removes
// every Notable cache and unregisters itself. It has no fetch handler, so
// pages it still controls talk straight to the network until they navigate.

self.addEventListener("install", () => self.skipWaiting());

self.addEventListener("activate", event => {
  event.waitUntil(
    (async () => {
      const names = await caches.keys();
      await Promise.all(names.map(name => caches.delete(name)));
      await self.registration.unregister();
    })(),
  );
});
