import 'serial_transport.dart';
import 'serial_transport_stub.dart' as platform;

SerialTransport createSerialTransport() => platform.getSerialTransport();
