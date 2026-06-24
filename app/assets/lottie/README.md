# Lottie animations

Booking-success animations. After a class is booked, the app picks one at
random for variety (see `lib/src/widgets/booking_success.dart`), loaded via
`AssetLottie`.

Current files:
- `booking_success.json` — pure-vector Lottie (no images)
- `yoga.json` — image-based Lottie; its 22 frames live in `yoga_assets/` and
  are referenced with `u: "yoga_assets/"` so `AssetLottie` resolves them
  relative to this folder.

Important: lottie 3.x does **not** decode base64-embedded images, and its zip
loader couldn't resolve this file's image paths — so a dotLottie `.lottie`
must be unpacked to a `.json` whose image assets point at sibling files
(`e: 0`, `u: "<folder>/"`, `p: "<name>.png"`), with the PNGs shipped as
assets. Pure-vector `.json` needs none of this.

To add more: drop the `.json` here (+ any image folder, registered in
pubspec) and add its path to `_kAssets` in `booking_success.dart`. Missing or
unparseable files fall back to a checkmark — no crash.
