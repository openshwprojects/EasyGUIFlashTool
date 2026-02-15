import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

Future<void> saveFileImplementation(String filename, Uint8List data) async {
  Directory? dir;
  try {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      dir = await getDownloadsDirectory();
    }
  } catch (e) {
    // Fallback or ignore
  }
  dir ??= await getApplicationDocumentsDirectory();
  
  final file = File('${dir.path}${Platform.pathSeparator}$filename');
  await file.writeAsBytes(data);
  // We can't easily show the file on all platforms, but it's saved.
  // The caller logs the path.
}
