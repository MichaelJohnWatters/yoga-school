# Lottie animations

Booking-success animations. After a class is booked, the app picks one of
these at random for variety (see `lib/src/widgets/booking_success.dart`).

Current files (all plain self-contained Lottie JSON):
- `booking_success.json`
- `yoga.json`

To add more, drop a `.json` here and add its path to `_kAssets` in
`booking_success.dart`. If a file is missing or won't parse, the booking flow
falls back to a simple checkmark — no crash.

A `.lottie` (dotLottie) file is a zip; don't ship it directly. Unzip it and
flatten to a self-contained JSON first (extract `animations/*.json` and embed
the `images/*` as base64 data URIs), then add the resulting `.json` here.

Grab more from https://lottiefiles.com/free-animations/yoga (export "Lottie
JSON").
