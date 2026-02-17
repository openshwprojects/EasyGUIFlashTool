import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';

/// Native (desktop/mobile) file picker using the file_picker package.
Future<({String name, Uint8List bytes})?> pickFirmwareFileImplementation() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.any,
    withData: true,
  );

  if (result == null || result.files.isEmpty) return null;

  final file = result.files.first;
  Uint8List? bytes = file.bytes;

  // On some platforms (desktop), bytes may be null but path is available.
  if (bytes == null && file.path != null) {
    bytes = await File(file.path!).readAsBytes();
  }

  if (bytes == null || bytes.isEmpty) return null;

  return (name: file.name, bytes: bytes);
}
