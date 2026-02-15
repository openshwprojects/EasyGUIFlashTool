import 'dart:typed_data';

import 'file_saver_stub.dart'
    if (dart.library.html) 'file_saver_web.dart'
    if (dart.library.io) 'file_saver_io.dart';

/// Save [data] to a file named [filename].
/// On web, this triggers a browser download.
/// On desktop/android, this saves to Downloads or Documents.
Future<void> saveFile(String filename, Uint8List data) => saveFileImplementation(filename, data);
