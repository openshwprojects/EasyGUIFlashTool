import 'dart:typed_data';

// Stub for libserialport types — used when compiling for web.
// On native platforms, serial_transport_desktop.dart uses the real package.

// ignore_for_file: non_constant_identifier_names, camel_case_types

class SerialPortParity {
  static const int none = 0;
}

class SerialPortFlowControl {
  static const int none = 0;
}

class SerialPortDtr {
  static const int on = 1;
  static const int off = 0;
}

class SerialPortRts {
  static const int on = 1;
  static const int off = 0;
}

class SerialPortConfig {
  int baudRate = 115200;
  int bits = 8;
  int stopBits = 1;
  int parity = 0;
  int dtr = 0;
  int rts = 0;

  void setFlowControl(int flowControl) {}
}

class SerialPortError {
  final String message;
  SerialPortError(this.message);
}

class SerialPortReader {
  final SerialPort _port;
  SerialPortReader(this._port);

  Stream<Uint8List> get stream => const Stream.empty();

  void close() {}
}

class SerialPort {
  final String name;
  bool _isOpen = false;

  SerialPort(this.name);

  bool get isOpen => _isOpen;

  bool openReadWrite() =>
      throw UnsupportedError('libserialport not available on this platform');

  SerialPortConfig get config => SerialPortConfig();
  set config(SerialPortConfig c) {}

  int write(Uint8List data) => 0;

  void close() {
    _isOpen = false;
  }

  void dispose() {}

  static List<String> get availablePorts => [];
  static SerialPortError? get lastError => null;
}
