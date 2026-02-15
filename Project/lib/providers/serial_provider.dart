import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../models/uart_message.dart';
import '../serial/serial_io.dart';


class SerialProvider extends ChangeNotifier {
  final SerialTransport _transport;

  StreamSubscription<Uint8List>? _dataSubscription;
  
  final List<UartMessage> _messages = [];
  bool _isConnected = false;
  String? _selectedPort;
  int _baudRate = 115200;
  bool _dtr = false;
  bool _rts = false;
  
  List<UartMessage> get messages => List.unmodifiable(_messages);
  bool get isConnected => _isConnected;
  String? get selectedPort => _selectedPort;
  int get baudRate => _baudRate;
  bool get dtr => _dtr;
  bool get rts => _rts;

  SerialProvider() : _transport = createSerialTransport() {
    _init();
  }

  Future<void> _init() async {
    await _transport.init();

    
    // Listen to incoming data
    _dataSubscription = _transport.stream.listen(_onDataReceived);
  }

  void _onDataReceived(Uint8List data) {
    try {
      final text = utf8.decode(data, allowMalformed: true);
      _addMessage(UartMessage(
        content: text,
        timestamp: DateTime.now(),
        direction: MessageDirection.received,
      ));
    } catch (e) {
      debugPrint('Error decoding received data: $e');
    }
  }

  void _addMessage(UartMessage message) {
    _messages.add(message);
    notifyListeners();
  }

  /// Get available ports (only works on desktop platforms)
  List<String> getAvailablePorts() {
    try {
      // Try to cast to desktop transport to get port list
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
  }

  /// Set baud rate
  void setBaudRate(int baudRate) {
    _baudRate = baudRate;
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
  }

  /// Toggle DTR signal
  Future<void> toggleDTR() async {
    _dtr = !_dtr;
    try {
      await _transport.setDTR(_dtr);
    } catch (e) {
      debugPrint('toggleDTR error: $e');
    }
    _addMessage(UartMessage(
      content: 'DTR set to ${_dtr ? "HIGH" : "LOW"}',
      timestamp: DateTime.now(),
      direction: MessageDirection.system,
    ));
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
    _addMessage(UartMessage(
      content: 'RTS set to ${_rts ? "HIGH" : "LOW"}',
      timestamp: DateTime.now(),
      direction: MessageDirection.system,
    ));
    notifyListeners();
  }

  Future<bool> connect() async {
    try {
      final success = await _transport.connect();
      _isConnected = success;
      if (success) {
        _addMessage(UartMessage(
          content: '--- Connected at $_baudRate baud ---',
          timestamp: DateTime.now(),
          direction: MessageDirection.received,
        ));
      }
      notifyListeners();
      return success;
    } catch (e) {
      debugPrint('Connection error: $e');
      _isConnected = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> disconnect() async {
    await _transport.disconnect();
    _isConnected = false;
    _addMessage(UartMessage(
      content: '--- Disconnected ---',
      timestamp: DateTime.now(),
      direction: MessageDirection.received,
    ));
    notifyListeners();
  }

  void sendMessage(String text) {
    if (!_isConnected) {
      debugPrint('Cannot send: not connected');
      return;
    }

    try {
      final data = Uint8List.fromList(utf8.encode(text));
      _transport.write(data);
      
      _addMessage(UartMessage(
        content: text,
        timestamp: DateTime.now(),
        direction: MessageDirection.sent,
      ));
      
      // Record in history for autocomplete

    } catch (e) {
      debugPrint('Send error: $e');
    }
  }

  void clearMessages() {
    _messages.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _dataSubscription?.cancel();
    _transport.dispose();
    super.dispose();
  }
}
