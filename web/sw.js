// Service worker for Plateworks Ignition — makes the whole app available offline
// (a fireline has no signal). The app is a single self-contained document, so
// caching the shell + icons is the entire app; all compute (IRPG tables,
// psychrometrics, .xlsx export) runs client-side with no network.
//
// CACHE is a version string, not brand copy — bump the number on any cached-asset
// change; never reword the prefix (see CLAUDE.md).
const CACHE = "badwater-ignition-v15";
const ASSETS = [
  "/",
  "/index.html",
  "/engine.js",
  "/app.js",
  "/analytics.js",
  "/manifest.webmanifest",
  "/favicon.svg",
  "/icon.svg",
  "/icon-512.png",
  "/apple-touch-icon.png",
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE)
      // {cache:"reload"} bypasses the HTTP cache: icons are served with long
      // max-age headers, so a plain addAll could precache a year-old copy into
      // a brand-new SW cache version and the update would never land.
      .then((cache) => cache.addAll(ASSETS.map((u) => new Request(u, { cache: "reload" }))))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;

  // Network-first for the page itself, so a new deploy is picked up when online;
  // fall back to the cached shell when offline.
  if (req.mode === "navigate") {
    event.respondWith(
      fetch(req)
        .then((res) => {
          // Only a healthy response for the app's own root may refresh the
          // cached shell. Every same-origin navigation used to be stored under
          // the "/index.html" key — a 404 for a typo path, or /robots.txt typed
          // in the address bar, replaced the entire offline app with that
          // response until the device was next online. Offline IS the product.
          const path = new URL(req.url).pathname;
          if (res.ok && (path === "/" || path === "/index.html")) {
            const copy = res.clone();
            caches.open(CACHE).then((c) => c.put("/index.html", copy));
          }
          return res;
        })
        .catch(() => caches.match("/index.html"))
    );
    return;
  }

  // Cache-first for static assets (icons, manifest).
  event.respondWith(caches.match(req).then((cached) => cached || fetch(req)));
});
