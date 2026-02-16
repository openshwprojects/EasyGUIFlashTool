import 'dart:typed_data';

/// Native (desktop/mobile) file picker.
/// For now, returns null on native — the drag-and-drop flow is the primary
/// way to load files on desktop. If file_picker is added later, hook it here.
Future<({String name, Uint8List bytes})?> pickFirmwareFileImplementation() async {
  // Native platforms can use drag-and-drop or download.
  // A full native file dialog requires the file_picker package.
  // For now, return null to indicate "not supported via this button".
  return null;
}
