import 'dart:io' show Platform;
import 'serial_transport.dart';
import 'serial_transport_android.dart' as android;
import 'serial_transport_desktop.dart' as desktop;
import 'serial_transport_win32.dart' as win32;

SerialTransport createSerialTransport() {
  if (Platform.isAndroid) {
    return android.getSerialTransport();
  } else if (Platform.isWindows) {
    return desktop.getSerialTransport();
  } else if (Platform.isLinux || Platform.isMacOS) {
    return desktop.getSerialTransport();
  }
  throw UnsupportedError('Platform not supported');
}
