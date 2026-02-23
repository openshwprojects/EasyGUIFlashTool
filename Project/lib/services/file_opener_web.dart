// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';
import 'dart:async';

/// Opens a file-picker dialog in the browser and returns the selected file.
Future<({String name, Uint8List bytes})?> pickFirmwareFileImplementation() async {
  final completer = Completer<({String name, Uint8List bytes})?>();

  final input = html.FileUploadInputElement()..accept = '.bin,.rbl,.fls,.img';
  input.click();

  input.onChange.listen((event) {
    final files = input.files;
    if (files == null || files.isEmpty) {
      completer.complete(null);
      return;
    }
    final file = files.first;
    final reader = html.FileReader();
    reader.readAsArrayBuffer(file);
    reader.onLoadEnd.listen((_) {
      final result = reader.result;
      if (result is Uint8List) {
        completer.complete((name: file.name, bytes: result));
      } else if (result is List<int>) {
        completer.complete((name: file.name, bytes: Uint8List.fromList(result)));
      } else {
        completer.complete(null);
      }
    });
    reader.onError.listen((_) {
      completer.complete(null);
    });
  });

  // If user cancels, the change event never fires on some browsers.
  // We use a focus listener as a fallback.
  html.window.onFocus.first.then((_) {
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    });
  });

  return completer.future;
}
