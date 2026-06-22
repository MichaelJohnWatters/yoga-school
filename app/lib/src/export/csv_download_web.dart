// Web: wrap the bytes in a Blob and click a hidden anchor to download.
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

Future<void> downloadCsv(String filename, List<int> bytes) async {
  final data = Uint8List.fromList(bytes);
  final parts = <JSAny>[data.toJS].toJS;
  final blob = web.Blob(parts, web.BlobPropertyBag(type: 'text/csv'));
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = filename
    ..style.display = 'none';
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}
