import 'dart:async';
import 'dart:typed_data';
import 'serial_port_win32_stub.dart'
    if (dart.library.ffi) 'package:serial_port_win32/serial_port_win32.dart';
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
  /// Generation counter: incremented each time the read loop is restarted.
  /// Old read loops check this and self-terminate if they're stale.
  int _readGen = 0;

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
      // Port is already open (singleton cache).  Make sure the baud rate
      // matches what setInitialBaudRate() requested — the UI may have
      // opened the port at the user-selected baud (e.g. 230400) but the
      // flasher needs the ROM-bootloader baud (115200) for initial sync.
      try {
        _port!.BaudRate = _baudRate;
        print('SerialTransportWin32: Already open – forced baud to $_baudRate');
      } catch (e) {
        print('SerialTransportWin32: Already open – BaudRate change failed: $e');
      }
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
  Completer<void>? _readLoopDone;

  void _startReadLoop() {
    if (_isReading) return;
    _isReading = true;
    _readGen++;
    _readLoopDone = Completer<void>();
    _readLoop(_readGen);
  }

  Future<void> _readLoop(int gen) async {
    while (_isReading && gen == _readGen && _port != null && _port!.isOpened) {
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
        // Check generation again after the await — baud rate may have changed
        if (gen != _readGen) break;
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
    // Signal that this read loop has fully exited
    if (_readLoopDone != null && !_readLoopDone!.isCompleted) {
      _readLoopDone!.complete();
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
  Future<void> write(Uint8List data) async {
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
      // Simplest possible baud rate change: just modify the DCB via
      // SetCommState.  The BaudRate setter calls GetCommState, updates
      // dcb.BaudRate, calls SetCommState, then PurgeComm.
      // The read loop keeps running — its current readBytes(timeout: 10ms)
      // will naturally complete and the next iteration reads at the new baud.
      _port!.BaudRate = baudRate;
      // Let USB-serial adapter finish reconfiguring baud rate dividers.
      await Future.delayed(const Duration(milliseconds: 50));
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
