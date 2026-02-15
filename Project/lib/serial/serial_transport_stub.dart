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
  void write(Uint8List data) {}

  @override
  Future<void> setDTR(bool value) async {}

  @override
  Future<void> setRTS(bool value) async {}

  @override
  void dispose() {}
}

SerialTransport getSerialTransport() => SerialTransportImpl();
