// Non-web stub. The hosted-Checkout redirect is web-only; mobile uses the
// native PaymentSheet, so these are never called off the web.

void redirectToCheckout(String url) =>
    throw UnsupportedError('hosted Checkout redirect is web-only');

void clearCheckoutQuery() {}
