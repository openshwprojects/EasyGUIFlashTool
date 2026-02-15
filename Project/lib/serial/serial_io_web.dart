import 'serial_transport.dart';
import 'serial_transport_web.dart' as web;

SerialTransport createSerialTransport() => web.getSerialTransport();
