import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../serial/serial_io.dart';

/// Provides serial port connectivity — open/close, port selection,
/// baud rate, DTR/RTS. No terminal or message logic.
class SerialProvider extends ChangeNotifier {
  final SerialTransport _transport;
  StreamSubscription<Uint8List>? _dataSubscription;

  bool _isConnected = false;
  String? _selectedPort;
  int _baudRate = 115200;
  bool _dtr = false;
  bool _rts = false;

  bool get isConnected => _isConnected;
  String? get selectedPort => _selectedPort;
  int get baudRate => _baudRate;
  bool get dtr => _dtr;
  bool get rts => _rts;

  /// Underlying transport — used by the flasher for direct protocol I/O.
  SerialTransport get transport => _transport;

  /// Stream of raw bytes from the serial port (for consumers to listen to).
  Stream<Uint8List> get dataStream => _transport.stream;

  SerialProvider() : _transport = createSerialTransport() {
    _init();
  }

  Future<void> _init() async {
    await _transport.init();
    await _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedPort = prefs.getString('serial_port');
      final savedBaud = prefs.getInt('serial_baud');

      if (savedPort != null) {
        _selectedPort = savedPort;
        // If the transport supports setting the port, set it now
        if (_transport is dynamic) {
          try {
            (_transport as dynamic).setPort(savedPort);
          } catch (_) {}
        }
      }

      if (savedBaud != null) {
        _baudRate = savedBaud;
        // If the transport supports setting the baud, set it now
        if (_transport is dynamic) {
          try {
            (_transport as dynamic).setBaudRate(savedBaud);
          } catch (_) {}
        }
      }
      notifyListeners();
    } catch (e) {
      debugPrint('Error loading serial settings: $e');
    }
  }

  Future<void> _saveSetting(String key, dynamic value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (value is String) {
        await prefs.setString(key, value);
      } else if (value is int) {
        await prefs.setInt(key, value);
      } else if (value is bool) {
        await prefs.setBool(key, value);
      } else if (value is double) {
        await prefs.setDouble(key, value);
      }
    } catch (e) {
      debugPrint('Error saving serial setting $key: $e');
    }
  }

  /// Get available ports (desktop only)
  List<String> getAvailablePorts() {
    try {
      if (_transport is dynamic) {
        final dynamic transport = _transport;
        if (transport.getAvailablePorts != null) {
          return transport.getAvailablePorts();
        }
      }
    } catch (e) {
      debugPrint('getAvailablePorts not supported on this platform');
    }
    return [];
  }

  /// Force a refresh of the port list
  void refreshPorts() {
    notifyListeners();
  }

  /// Set selected port (desktop only)
  void setPort(String portName) {
    _selectedPort = portName;
    _saveSetting('serial_port', portName);
    try {
      if (_transport is dynamic) {
        final dynamic transport = _transport;
        if (transport.setPort != null) {
          transport.setPort(portName);
        }
      }
    } catch (e) {
      debugPrint('setPort not supported on this platform');
    }
    notifyListeners();
  }

  /// Set baud rate
  void setBaudRate(int baudRate) {
    _baudRate = baudRate;
    _saveSetting('serial_baud', baudRate);
    try {
      if (_transport is dynamic) {
        final dynamic transport = _transport;
        if (transport.setBaudRate != null) {
          transport.setBaudRate(baudRate);
        }
      }
    } catch (e) {
      debugPrint('setBaudRate not supported on this platform');
    }
    notifyListeners();
  }

  /// Toggle DTR signal
  Future<void> toggleDTR() async {
    _dtr = !_dtr;
    try {
      await _transport.setDTR(_dtr);
    } catch (e) {
      debugPrint('toggleDTR error: $e');
    }
    notifyListeners();
  }

  /// Toggle RTS signal
  Future<void> toggleRTS() async {
    _rts = !_rts;
    try {
      await _transport.setRTS(_rts);
    } catch (e) {
      debugPrint('toggleRTS error: $e');
    }
    notifyListeners();
  }

  /// Open the serial port connection
  Future<bool> connect() async {
    try {
      final success = await _transport.connect();
      _isConnected = success;
      notifyListeners();
      return success;
    } catch (e) {
      debugPrint('Connection error: $e');
      _isConnected = false;
      notifyListeners();
      return false;
    }
  }

  /// Close the serial port connection
  Future<void> disconnect() async {
    await _transport.disconnect();
    _isConnected = false;
    notifyListeners();
  }

  /// Write raw bytes to the serial port
  void writeBytes(Uint8List data) {
    if (!_isConnected) {
      debugPrint('Cannot write: not connected');
      return;
    }
    try {
      _transport.write(data);
    } catch (e) {
      debugPrint('Write error: $e');
    }
  }

  @override
  void dispose() {
    _dataSubscription?.cancel();
    _transport.dispose();
    super.dispose();
  }
}
