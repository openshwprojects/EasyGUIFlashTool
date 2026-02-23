import 'dart:async';
import 'dart:typed_data';
import 'package:usb_serial/usb_serial.dart';
import 'serial_transport.dart';

class SerialTransportAndroid implements SerialTransport {
  UsbPort? _port;
  final StreamController<Uint8List> _streamController =
      StreamController<Uint8List>.broadcast();
  StreamSubscription<UsbEvent>? _usbEventSub;

  @override
  Stream<Uint8List> get stream => _streamController.stream;

  @override
  Future<void> init() async {
    _listenUsbEvents();
    // Auto-open if device is already connected
    await _autoOpenPort();
  }

  void _listenUsbEvents() {
    _usbEventSub = UsbSerial.usbEventStream?.listen((UsbEvent event) async {
      if (event.event == UsbEvent.ACTION_USB_ATTACHED) {
        await _autoOpenPort();
      } else if (event.event == UsbEvent.ACTION_USB_DETACHED) {
        await disconnect();
      }
    });
  }

  Future<void> _autoOpenPort() async {
    if (_port != null) return;

    // Original logic from serial_provider.dart
    List<UsbDevice> devices = await UsbSerial.listDevices();
    if (devices.isEmpty) return;

    try {
      _port = await devices.first.create();
      bool opened = await _port!.open() ?? false;
      if (!opened) {
        _port = null;
        return;
      }

      await _port!.setDTR(true);
      await _port!.setRTS(true);
      await _port!.setPortParameters(
        115200,
        UsbPort.DATABITS_8,
        UsbPort.STOPBITS_1,
        UsbPort.PARITY_NONE,
      );

      _port!.inputStream!.listen((data) {
        _streamController.add(data);
      });
    } catch (e) {
      _port = null;
    }
  }

  @override
  Future<bool> connect() async {
    // Android uses auto-connect logic via init() and USB events.
    // Explicit connect could just retry scan.
    await _autoOpenPort();
    return _port != null;
  }

  @override
  Future<void> disconnect() async {
    _port?.close();
    _port = null;
  }

  @override
  Future<void> write(Uint8List data) async {
    _port?.write(data);
  }

  @override
  Future<bool> setDTR(bool value) async {
    try {
      await _port?.setDTR(value);
      return true;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<bool> setRTS(bool value) async {
    try {
      await _port?.setRTS(value);
      return true;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<void> setBaudRate(int baudRate) async {
    if (_port == null) return;
    await _port!.setPortParameters(
      baudRate,
      UsbPort.DATABITS_8,
      UsbPort.STOPBITS_1,
      UsbPort.PARITY_NONE,
    );
  }

  @override
  void dispose() {
    disconnect();
    _usbEventSub?.cancel();
    _streamController.close();
  }
}

SerialTransport getSerialTransport() => SerialTransportAndroid();
