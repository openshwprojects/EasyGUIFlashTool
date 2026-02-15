import 'dart:io' show Platform;
import 'serial_transport.dart';
import 'serial_transport_android.dart' as android;
import 'serial_transport_desktop.dart' as desktop;

SerialTransport createSerialTransport() {
  if (Platform.isAndroid) {
    return android.getSerialTransport();
  } else if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    return desktop.getSerialTransport();
  }
  throw UnsupportedError('Platform not supported');
}
