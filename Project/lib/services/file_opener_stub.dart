import 'dart:typed_data';

/// Stub — throws on unsupported platforms.
Future<({String name, Uint8List bytes})?> pickFirmwareFileImplementation() async {
  throw UnsupportedError('Platform not supported for file picking');
}
