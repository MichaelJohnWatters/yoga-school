// Cross-platform shim for the two browser-only operations the hosted Stripe
// Checkout flow needs: a full-page redirect to Stripe, and clearing the
// ?checkout=… query param off our URL after we've handled the return.
//
// On non-web builds the platform impl is the no-op stub, so shared code
// (checkout_sheet, main) compiles for mobile without `package:web`.

import 'web_redirect_stub.dart'
    if (dart.library.js_interop) 'web_redirect_web.dart' as platform;

/// Test seam (integration tests only): when non-null, [redirectToCheckout]
/// hands the URL here instead of navigating the browser away — so a test can
/// assert on the real Checkout URL without leaving the app. Null in production.
void Function(String url)? debugCheckoutRedirectOverride;

/// Navigates the browser to Stripe's hosted Checkout page (or the test seam).
void redirectToCheckout(String url) {
  final override = debugCheckoutRedirectOverride;
  if (override != null) {
    override(url);
    return;
  }
  platform.redirectToCheckout(url);
}

/// Strips the ?checkout=… params off the URL after handling the return.
void clearCheckoutQuery() => platform.clearCheckoutQuery();
