// Web implementation backed by package:web.

import 'package:web/web.dart' as web;

/// Navigates the whole browser tab to Stripe's hosted Checkout page. The
/// Flutter app is unloaded; Stripe returns the user to our success/cancel URL.
void redirectToCheckout(String url) {
  web.window.location.href = url;
}

/// Strips the ?checkout=… (and related) query params off the current URL so a
/// page refresh after returning from Checkout doesn't re-trigger the handler.
/// Keeps the path + hash (the SPA route) intact.
void clearCheckoutQuery() {
  final loc = web.window.location;
  web.window.history.replaceState(null, '', '${loc.pathname}${loc.hash}');
}
