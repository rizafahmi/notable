// Registers the app-shell service worker served at /sw.js.
//
// Loaded from the root layout as its own esbuild entry so it stays out of
// app.js. The worker takes over with skipWaiting + clients.claim; nothing here
// reloads the page on update - a forced reload could discard what someone is
// typing, and LiveView already reloads on reconnect when tracked statics change.
//
// Per-browser kill switch (docs/OPERATIONS.md#service-worker):
//   await notableServiceWorker.uninstall()

if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/sw.js").catch(error => {
      console.warn("[notable] service worker registration failed", error)
    })
  })

  window.notableServiceWorker = {
    async uninstall() {
      const registrations = await navigator.serviceWorker.getRegistrations()
      await Promise.all(registrations.map(registration => registration.unregister()))
      const names = await caches.keys()
      await Promise.all(names.map(name => caches.delete(name)))
      return {unregistered: registrations.length, cachesDeleted: names.length}
    },
  }
}
