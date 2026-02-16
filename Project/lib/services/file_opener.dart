import 'dart:typed_data';

import 'file_opener_stub.dart'
    if (dart.library.html) 'file_opener_web.dart'
    if (dart.library.io) 'file_opener_io.dart';

/// Pick a firmware file (.bin / .rbl) from the user's device.
/// Returns a record with the file name and bytes, or null if cancelled.
Future<({String name, Uint8List bytes})?> pickFirmwareFile() =>
    pickFirmwareFileImplementation();
