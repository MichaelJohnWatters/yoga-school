// Custom Flutter web bootstrap.
//
// Goal: no stale-bundle pain in dev, but a real service worker (PWA install +
// offline + versioned-filename caching) in production.
//
// How it works:
//   1. Tear down any service worker + cache storage left over from a previous
//      session before loading the new bundle. Harmless in prod; in dev it
//      guarantees the first request hits the network, not a stale cache.
//   2. Register the SW using `{{flutter_service_worker_version}}`. Flutter
//      resolves that token to a real version in a RELEASE build (`flutter build
//      web`) and to `null` under `flutter run` (dev). A null version means no
//      SW is registered — so dev stays cache-free automatically, while prod
//      gets proper versioned caching. No manual dev/prod switch needed.
//
// NOTE: changes to this file are not exercised by `dart analyze`/`flutter
// test`; verify with `flutter build web` + a browser load (M7 smoke test)
// before relying on the prod caching behaviour.

{{flutter_js}}
{{flutter_build_config}}

(async () => {
  // 1. Evict everything cached by previous service-worker generations.
  //    `serviceWorker` may be undefined in some browsers/contexts, so guard.
  if ('serviceWorker' in navigator) {
    try {
      const regs = await navigator.serviceWorker.getRegistrations();
      await Promise.all(regs.map((r) => r.unregister()));
    } catch (_) {}
  }
  if ('caches' in window) {
    try {
      const keys = await caches.keys();
      await Promise.all(keys.map((k) => caches.delete(k)));
    } catch (_) {}
  }

  // 2. Load Flutter, registering the service worker only when the build
  //    carries a version (release). In dev the version is null → no SW.
  _flutter.loader.load({
    serviceWorkerSettings: {
      serviceWorkerVersion: {{flutter_service_worker_version}},
    },
  });
})();
