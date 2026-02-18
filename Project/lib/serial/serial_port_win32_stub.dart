import 'dart:typed_data';

// Stub for serial_port_win32 types — used when compiling for web.
// On native platforms, serial_transport_win32.dart uses the real package.

/// Stub SerialPort class for web compilation.
class SerialPort {
  final String portName;
  // ignore: non_constant_identifier_names
  int BaudRate = 0;

  // ignore: non_constant_identifier_names
  SerialPort(this.portName, {bool openNow = true, int BaudRate = 115200}) {
    this.BaudRate = BaudRate;
  }

  bool get isOpened => false;

  // ignore: non_constant_identifier_names
  void openWithSettings({int BaudRate = 115200}) =>
      throw UnsupportedError('Win32 serial not available on this platform');

  void close() {}

  Future<Uint8List> readBytes(int bytesSize,
          {Duration? timeout,
          Duration dataPollingInterval =
              const Duration(microseconds: 500)}) async =>
      Uint8List(0);

  Future<bool> writeBytesFromUint8List(Uint8List data,
          {int timeout = 500}) async =>
      false;

  void setFlowControlSignal(int flag) {}

  static const int SETDTR = 5;
  static const int CLRDTR = 6;
  static const int SETRTS = 3;
  static const int CLRRTS = 4;

  static List<String> getAvailablePorts() => [];
}
