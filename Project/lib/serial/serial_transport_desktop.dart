import 'dart:async';
import 'dart:typed_data';
import 'package:libserialport/libserialport.dart';
import 'serial_transport.dart';

class SerialTransportDesktop implements SerialTransport {
  SerialPort? _port;
  SerialPortReader? _reader;
  SerialPortConfig? _cachedConfig;
  final StreamController<Uint8List> _streamController =
      StreamController<Uint8List>.broadcast();
  
  String? _selectedPortName;
  int _baudRate = 115200;

  @override
  Stream<Uint8List> get stream => _streamController.stream;

  /// Get list of available serial port names
  List<String> getAvailablePorts() {
    return SerialPort.availablePorts;
  }

  /// Set the port to connect to
  void setPort(String portName) {
    _selectedPortName = portName;
  }

  /// Set baud rate (call before connect)
  void setInitialBaudRate(int baudRate) {
    _baudRate = baudRate;
  }

  @override
  Future<void> init() async {
    // Desktop platforms don't need special initialization
    // Port scanning happens on connect()
  }

  @override
  Future<bool> connect() async {
    if (_port != null && _port!.isOpen) {
      print('SerialTransportDesktop: Already open');
      return true;
    }
    try {
      // If no port is selected, try to use the first available port
      if (_selectedPortName == null) {
        final availablePorts = SerialPort.availablePorts;
        if (availablePorts.isEmpty) {
          print('No serial ports available');
          return false;
        }
        _selectedPortName = availablePorts.first;
      }

      _port = SerialPort(_selectedPortName!);

      // Open the port FIRST — libserialport ignores config set before open
      if (!_port!.openReadWrite()) {
        final error = SerialPort.lastError;
        print('Failed to open port: ${error?.message}');
        _port?.dispose();
        _port = null;
        return false;
      }

      // Now configure port settings
      final config = SerialPortConfig()
        ..baudRate = _baudRate
        ..bits = 8
        ..stopBits = 1
        ..parity = SerialPortParity.none
        ..setFlowControl(SerialPortFlowControl.none);
      _port!.config = config;

      print('Connected to serial port: $_selectedPortName at $_baudRate baud');

      // Cache config for lightweight DTR/RTS changes
      _cachedConfig = _port!.config;

      // Start reading data
      _startReading();
      return true;
    } catch (e) {
      print('Desktop Serial connect error: $e');
      _port?.dispose();
      _port = null;
      return false;
    }
  }

  void _startReading() {
    if (_port == null) return;

    _reader = SerialPortReader(_port!);
    _reader!.stream.listen(
      (data) {
        _streamController.add(Uint8List.fromList(data));
      },
      onError: (error) {
        print('Serial read error: $error');
      },
      onDone: () {
        print('Serial stream closed');
      },
    );
  }

  @override
  Future<void> disconnect() async {
    _reader?.close();
    _reader = null;
    _cachedConfig = null;
    
    _port?.close();
    _port?.dispose();
    _port = null;
  }

  @override
  void write(Uint8List data) {
    if (_port == null || !_port!.isOpen) {
      print('Port not open, cannot write');
      return;
    }

    try {
      final bytesWritten = _port!.write(data);
      if (bytesWritten != data.length) {
        print('Warning: wrote $bytesWritten bytes, expected ${data.length}');
      }
    } catch (e) {
      print('Write error: $e');
    }
  }

  @override
  Future<void> setDTR(bool value) async {
    if (_port == null || !_port!.isOpen || _cachedConfig == null) return;
    try {
      _cachedConfig!.dtr = value ? SerialPortDtr.on : SerialPortDtr.off;
      _port!.config = _cachedConfig!;
    } catch (e) {
      print('setDTR error: $e');
    }
  }

  @override
  Future<void> setRTS(bool value) async {
    if (_port == null || !_port!.isOpen || _cachedConfig == null) return;
    try {
      _cachedConfig!.rts = value ? SerialPortRts.on : SerialPortRts.off;
      _port!.config = _cachedConfig!;
    } catch (e) {
      print('setRTS error: $e');
    }
  }

  @override
  Future<void> setBaudRate(int baudRate) async {
    if (_port == null || !_port!.isOpen) {
      _baudRate = baudRate;
      return;
    }
    if (baudRate == _baudRate) return;
    _baudRate = baudRate;
    try {
      // In-place baud rate change — no close/reopen needed on Linux/macOS.
      // (Windows now uses SerialTransportWin32 instead.)
      if (_cachedConfig != null) {
        _cachedConfig!.baudRate = baudRate;
        _port!.config = _cachedConfig!;
      } else {
        final config = SerialPortConfig()
          ..baudRate = baudRate
          ..bits = 8
          ..stopBits = 1
          ..parity = SerialPortParity.none
          ..setFlowControl(SerialPortFlowControl.none);
        _port!.config = config;
        _cachedConfig = _port!.config;
      }
      print('Baud rate changed to $baudRate');
    } catch (e) {
      print('setBaudRate error: $e');
    }
  }

  @override
  void dispose() {
    _reader?.close();
    _reader = null;
    _cachedConfig = null;
    _port?.close();
    _port?.dispose();
    _port = null;
    _streamController.close();
  }
}

SerialTransport getSerialTransport() => SerialTransportDesktop();
