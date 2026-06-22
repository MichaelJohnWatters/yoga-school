// Cross-platform "save this CSV" entry point. The web build triggers a browser
// download; native builds write a temp file and open the share sheet. The
// platform-specific implementation is selected at compile time.
export 'csv_download_stub.dart'
    if (dart.library.io) 'csv_download_io.dart'
    if (dart.library.js_interop) 'csv_download_web.dart';
