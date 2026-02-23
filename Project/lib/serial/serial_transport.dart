import 'dart:async';
import 'dart:typed_data';

abstract class SerialTransport {
  Stream<Uint8List> get stream;

  Future<void> init();
  Future<bool> connect();
  Future<void> disconnect();
  Future<void> write(Uint8List data);
  Future<bool> setDTR(bool value);
  Future<bool> setRTS(bool value);
  Future<void> setBaudRate(int baudRate);
  void dispose();
}
