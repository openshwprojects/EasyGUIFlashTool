import 'dart:typed_data';
import 'serial_transport.dart';

class SerialTransportImpl implements SerialTransport {
  @override
  Stream<Uint8List> get stream => const Stream.empty();

  @override
  Future<void> init() async {}

  @override
  Future<bool> connect() async {
    throw UnimplementedError(
        'Serial transport not implemented for this platform');
  }

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> write(Uint8List data) async {}

  @override
  Future<bool> setDTR(bool value) async => true;

  @override
  Future<bool> setRTS(bool value) async => true;

  @override
  Future<void> setBaudRate(int baudRate) async {}

  @override
  void dispose() {}
}

SerialTransport getSerialTransport() => SerialTransportImpl();
