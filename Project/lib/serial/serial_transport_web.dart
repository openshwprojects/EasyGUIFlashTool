import 'dart:async';
import 'dart:typed_data';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:web/web.dart' as web;
import 'package:flutter/foundation.dart';
import 'serial_transport.dart';

class SerialTransportWeb implements SerialTransport {
  JSObject? _port;
  JSObject? _reader;
  JSObject? _writer;
  final StreamController<Uint8List> _streamController = StreamController<Uint8List>.broadcast();
  bool _isReading = false;

  @override
  Stream<Uint8List> get stream => _streamController.stream;

  @override
  Future<void> init() async {
    // Check support
    if (!checkSupport()) {
      debugPrint('Web Serial API not supported in this browser');
    }
  }

  bool checkSupport() {
    final nav = web.window.navigator;
    return nav.has('serial');
  }

  @override
  Future<bool> connect() async {
    debugPrint("SerialTransportWeb.connect() started");
    try {
      if (!checkSupport()) {
        debugPrint("Web Serial API not supported");
        return false;
      }

      final nav = web.window.navigator;
      final serial = nav.getProperty('serial'.toJS) as JSObject;

      // Request Port
      debugPrint("Requesting port...");
      final portPromise = serial.callMethod('requestPort'.toJS);
      _port = await (portPromise as JSPromise).toDart as JSObject;
      debugPrint("Port selected");

      // Open Port
      debugPrint("Opening port...");
      final options = JSObject();
      options.setProperty('baudRate'.toJS, 115200.toJS);
      
      final openPromise = _port!.callMethod('open'.toJS, options);
      await (openPromise as JSPromise).toDart;
      debugPrint("Port opened successfully");

      _startReading();
      return true;
    } catch (e) {
      debugPrint('Web Serial connect error: $e');
      return false;
    }
  }

  void _startReading() {
    if (_isReading || _port == null) return;
    _isReading = true;
    _readLoop();
  }

  Future<void> _readLoop() async {
    try {
      final readable = _port!.getProperty('readable'.toJS) as JSObject?;
      if (readable == null) return;

      _reader = readable.callMethod('getReader'.toJS) as JSObject;
      
      while (_isReading) {
        final readPromise = _reader!.callMethod('read'.toJS) as JSPromise;
        final result = await readPromise.toDart as JSObject;
        
        final done = (result.getProperty('done'.toJS) as JSBoolean).toDart;
        if (done) break;

        final value = result.getProperty('value'.toJS) as JSObject?;
        if (value != null) {
          final data = (value as JSUint8Array).toDart;
          _streamController.add(data);
        }
      }
    } catch (e) {
      debugPrint('Read loop error: $e');
    } finally {
      // Release lock logic would go here if we were being pedantic, 
      // but usually we just close/disconnect.
      _isReading = false;
    }
  }

  @override
  Future<void> disconnect() async {
    _isReading = false;
    
    // Cancellation and closing logic
    try {
      if (_reader != null) {
        await (_reader!.callMethod('cancel'.toJS) as JSPromise).toDart;
        _reader = null;
      }
      
      if (_writer != null) {
        await (_writer!.callMethod('close'.toJS) as JSPromise).toDart;
        _writer = null;
      }

      if (_port != null) {
        await (_port!.callMethod('close'.toJS) as JSPromise).toDart;
        _port = null;
      }
    } catch (e) {
      debugPrint('Disconnect error: $e');
    }
  }

  @override
  void write(Uint8List data) async {
    if (_port == null) return;

    try {
      // In a real app, you'd keep the writer open, but for simplicity:
      final writable = _port!.getProperty('writable'.toJS) as JSObject?;
      if (writable == null) return;

      if (_writer == null) {
        _writer = writable.callMethod('getWriter'.toJS) as JSObject;
      }

      final chunk = data.toJS;
      await (_writer!.callMethod('write'.toJS, chunk) as JSPromise).toDart;
      
    } catch (e) {
      debugPrint('Write error: $e');
      // Force reset writer on error
      _writer = null;
    }
  }

  @override
  Future<void> setDTR(bool value) async {
    if (_port == null) return;
    try {
      final signals = JSObject();
      signals.setProperty('dataTerminalReady'.toJS, value.toJS);
      await (_port!.callMethod('setSignals'.toJS, signals) as JSPromise).toDart;
    } catch (e) {
      debugPrint('setDTR error: $e');
    }
  }

  @override
  Future<void> setRTS(bool value) async {
    if (_port == null) return;
    try {
      final signals = JSObject();
      signals.setProperty('requestToSend'.toJS, value.toJS);
      await (_port!.callMethod('setSignals'.toJS, signals) as JSPromise).toDart;
    } catch (e) {
      debugPrint('setRTS error: $e');
    }
  }

  @override
  void dispose() {
    disconnect();
    _streamController.close();
  }
}

SerialTransport getSerialTransport() => SerialTransportWeb();
