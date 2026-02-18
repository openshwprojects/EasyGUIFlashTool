import 'dart:async';
import 'dart:typed_data';
import 'package:serial_port_win32/serial_port_win32.dart';
import 'serial_transport.dart';

/// Windows-specific serial transport using the Win32 API.
///
/// Uses `serial_port_win32` which directly calls Win32 serial functions
/// via dart:ffi — no C library config lifecycle issues.
class SerialTransportWin32 implements SerialTransport {
  SerialPort? _port;
  final StreamController<Uint8List> _streamController =
      StreamController<Uint8List>.broadcast();
  bool _isReading = false;

  String? _selectedPortName;
  int _baudRate = 115200;

  @override
  Stream<Uint8List> get stream => _streamController.stream;

  /// Get list of available serial port names
  List<String> getAvailablePorts() {
    return SerialPort.getAvailablePorts();
  }

  /// Set the port to connect to
  void setPort(String portName) {
    _selectedPortName = portName;
  }

  /// Set baud rate (call before connect, or use setBaudRate for live changes)
  void setInitialBaudRate(int baudRate) {
    _baudRate = baudRate;
  }

  @override
  Future<void> init() async {
    // No special initialization needed
  }

  @override
  Future<bool> connect() async {
    if (_port != null && _port!.isOpened) {
      print('SerialTransportWin32: Already open');
      return true;
    }
    try {
      if (_selectedPortName == null) {
        final availablePorts = SerialPort.getAvailablePorts();
        if (availablePorts.isEmpty) {
          print('No serial ports available');
          return false;
        }
        _selectedPortName = availablePorts.first;
      }

      // serial_port_win32 uses singleton pattern per port name.
      // The constructor may return a previously-opened instance.
      _port = SerialPort(_selectedPortName!, openNow: false, BaudRate: _baudRate);
      if (!_port!.isOpened) {
        _port!.openWithSettings(BaudRate: _baudRate);
      }

      if (!_port!.isOpened) {
        print('Failed to open port: $_selectedPortName');
        _port = null;
        return false;
      }

      print('Connected to serial port: $_selectedPortName at $_baudRate baud');

      _startReadLoop();
      return true;
    } catch (e) {
      print('Win32 Serial connect error: $e');
      _port = null;
      return false;
    }
  }

  /// Tight async read loop — yields to the Dart event loop between reads
  /// so Flutter can still pump messages, but adds zero artificial delay.
  void _startReadLoop() {
    if (_isReading) return;
    _isReading = true;
    _readLoop();
  }

  Future<void> _readLoop() async {
    while (_isReading && _port != null && _port!.isOpened) {
      try {
        // Use a longer polling interval (2ms vs default 500μs) to avoid
        // flooding the Dart event loop with timer callbacks. The default
        // 500μs creates ~10 timer events per readBytes call which starves
        // the Windows message pump of input processing time.
        final data = await _port!.readBytes(
          4096,
          timeout: const Duration(milliseconds: 10),
          dataPollingInterval: const Duration(milliseconds: 2),
        );
        if (data.isNotEmpty) {
          _streamController.add(Uint8List.fromList(data));
        }
      } catch (_) {
        // Port may have been closed
      }
      // Yield enough time for Flutter to process Windows messages
      // (WM_LBUTTONDOWN, WM_MOUSEMOVE, etc.) between read cycles.
      await Future.delayed(const Duration(milliseconds: 5));
    }
  }

  void _stopReadLoop() {
    _isReading = false;
  }

  @override
  Future<void> disconnect() async {
    _stopReadLoop();
    try {
      _port?.close();
    } catch (e) {
      print('Disconnect error: $e');
    }
    _port = null;
  }

  @override
  void write(Uint8List data) {
    if (_port == null || !_port!.isOpened) {
      print('Port not open, cannot write');
      return;
    }

    try {
      _port!.writeBytesFromUint8List(data);
    } catch (e) {
      print('Write error: $e');
    }
  }

  @override
  Future<bool> setDTR(bool value) async {
    if (_port == null || !_port!.isOpened) return false;
    try {
      _port!.setFlowControlSignal(
        value ? SerialPort.SETDTR : SerialPort.CLRDTR,
      );
      return true;
    } catch (e) {
      print('setDTR error: $e');
      return false;
    }
  }

  @override
  Future<bool> setRTS(bool value) async {
    if (_port == null || !_port!.isOpened) return false;
    try {
      _port!.setFlowControlSignal(
        value ? SerialPort.SETRTS : SerialPort.CLRRTS,
      );
      return true;
    } catch (e) {
      print('setRTS error: $e');
      return false;
    }
  }

  @override
  Future<void> setBaudRate(int baudRate) async {
    if (baudRate == _baudRate && _port != null && _port!.isOpened) return;
    _baudRate = baudRate;
    if (_port == null || !_port!.isOpened) return;
    try {
      // serial_port_win32 allows direct baud rate changes — no close/reopen
      _port!.BaudRate = baudRate;
      print('Baud rate changed to $baudRate');
    } catch (e) {
      print('setBaudRate error: $e');
    }
  }

  @override
  void dispose() {
    _stopReadLoop();
    try {
      _port?.close();
    } catch (_) {}
    _port = null;
    _streamController.close();
  }
}

SerialTransport getSerialTransport() => SerialTransportWin32();
