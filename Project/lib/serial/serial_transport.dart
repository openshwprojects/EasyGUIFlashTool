import 'dart:async';
import 'dart:typed_data';

abstract class SerialTransport {
  Stream<Uint8List> get stream;

  Future<void> init();
  Future<bool> connect();
  Future<void> disconnect();
  void write(Uint8List data);
  Future<void> setDTR(bool value);
  Future<void> setRTS(bool value);
  void dispose();
}
