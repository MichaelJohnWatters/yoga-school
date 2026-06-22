// Fallback used only when neither dart:io nor dart:js_interop is available.
Future<void> downloadCsv(String filename, List<int> bytes) async {
  throw UnsupportedError('CSV download is not supported on this platform');
}
