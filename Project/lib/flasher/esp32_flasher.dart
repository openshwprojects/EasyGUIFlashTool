/// ESP32 flasher implementation, ported from C# `ESPFlasher.cs`.
///
/// Implements the ESP32 ROM bootloader SLIP protocol: sync, DTR/RTS reset,
/// chip identification, register read/write, SPI attach, and flash ID reading.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:crypto/crypto.dart' show md5;

import '../serial/serial_transport.dart';
import 'base_flasher.dart';

// ─── ESP32 command opcodes ──────────────────────────────────────────────────

class _ESPCmd {
  static const int flashBegin    = 0x02;
  static const int flashData     = 0x03;
  static const int flashEnd      = 0x04;
  static const int memBegin      = 0x05;
  static const int memEnd        = 0x06;
  static const int memData       = 0x07;
  static const int sync          = 0x08;
  static const int writeReg      = 0x09;
  static const int readReg       = 0x0A;
  static const int spiSetParams  = 0x0B;
  static const int spiAttach     = 0x0D;
  static const int readFlashSlow = 0x0E;
  static const int changeBaudrate = 0x0F;
  static const int spiFlashMd5   = 0x13;
  static const int getSecurityInfo = 0x14;
  static const int eraseFlash    = 0xD0;
  static const int readFlash     = 0xD2;
}

// ─── SLIP framing constants ─────────────────────────────────────────────────

const int _slipEnd    = 0xC0;
const int _slipEsc    = 0xDB;
const int _slipEscEnd = 0xDC;
const int _slipEscEsc = 0xDD;

// ─── Stub upload constants ──────────────────────────────────────────────────

const int _espRamBlock = 0x1800; // must match esptool default

// ─── Chip identification tables ─────────────────────────────────────────────

const Map<int, String> _chipMagicValues = {
  0x00F01D83: 'ESP32',
  0x000007C6: 'ESP32-S2',
  0xFFF0C101: 'ESP8266',
};

const Map<int, String> _chipIDs = {
  0:  'ESP32',
  2:  'ESP32-S2',
  5:  'ESP32-C3',
  9:  'ESP32-S3',
  12: 'ESP32-C2',
  13: 'ESP32-C6',
  16: 'ESP32-H2',
  18: 'ESP32-P4',
};

// ─── SPI register offsets (ESP32) ───────────────────────────────────────────

const int _esp32SpiRegBase   = 0x3FF42000;
const int _spiUsrOffs        = 0x1C;
const int _spiUsr2Offs       = 0x24;
const int _spiMosiDlenOffs   = 0x28;
const int _spiMisoDlenOffs   = 0x2C;
const int _spiW0Offs         = 0x80;

// ─── SPI register offsets (ESP32-S3 / ESP32-C3 — shared base) ───────────────

const int _esp32s3SpiRegBase     = 0x60002000;
const int _esp32s3SpiUsrOffs     = 0x18;
const int _esp32s3SpiUsr2Offs    = 0x20;
const int _esp32s3SpiMosiDlenOffs = 0x24;
const int _esp32s3SpiMisoDlenOffs = 0x28;
const int _esp32s3SpiW0Offs      = 0x58;

// ═══════════════════════════════════════════════════════════════════════════
//  ESP32 Flasher
// ═══════════════════════════════════════════════════════════════════════════

class ESPFlasher extends BaseFlasher {
  bool _isStub = false;

  bool get _isESP32S3 => chipType == BKType.esp32s3;
  bool get _isESP32C3 => chipType == BKType.esp32c3;

  /// Receive buffer — incoming stream data is accumulated here.
  final _rxBuffer = Queue<int>();
  StreamSubscription<Uint8List>? _rxSub;

  /// Result of the last read operation.
  Uint8List? _readResult;

  ESPFlasher({
    required super.transport,
    super.chipType = BKType.esp32,
    super.baudrate = 921600,
  });

  // ════════════════════════════════════════════════════════════════════════
  //  PUBLIC API (overrides from BaseFlasher)
  // ════════════════════════════════════════════════════════════════════════

  @override
  Future<void> doRead({int startSector = 0, int sectors = 10, bool fullRead = false}) async {
    try {
      if (!await _connect()) {
        setState('Connection failed!');
        addErrorLine('Failed to connect to ESP32.');
        return;
      }

      // Read chip identification
      final chipId = await _getChipId();
      if (chipId != null) {
        addLogLine('Chip ID result: $chipId');
      }

      // Read flash ID via SPI
      int flashSize = 0;
      final flashId = await _readFlashId();
      if (flashId != null) {
        addLogLine('Flash ID result: 0x${flashId.toRadixString(16).toUpperCase()}');
        final sizeCode = (flashId >> 16) & 0xFF;
        if (sizeCode > 0 && sizeCode <= 31) {
          flashSize = 1 << sizeCode;
          await _spiSetParams(flashSize);
        }
      }

      if (fullRead && flashSize > 0) {
        sectors = flashSize ~/ 0x1000;
      }

      setState('Reading flash...');
      addLogLine('Starting Flash Read: $sectors sectors from '
          '0x${startSector.toRadixString(16).toUpperCase()}...');
      final startAddr = startSector * 0x1000;
      final totalSize = sectors * 0x1000;
      final sw = Stopwatch()..start();

      // Try stub for faster reads
      bool stubOk = await _uploadStub();
      if (stubOk) {
        // Re-attach SPI after stub starts
        await _spiAttach();
        if (baudrate > 115200) {
          await _changeBaudrate(baudrate);
        }

        try {
          setState('Reading flash (fast)...');
          addLogLine('Starting fast flash read: $totalSize bytes from '
              '0x${startAddr.toRadixString(16).toUpperCase()}...');
          final flashData = await _readFlashFast(startAddr, totalSize, sw);
          _readResult = flashData;
          sw.stop();
          final secs = sw.elapsedMilliseconds / 1000.0;
          final kbps = (totalSize / 1024.0) / secs;
          addLogLine('Read $totalSize bytes in ${secs.toStringAsFixed(1)}s '
              '(${kbps.toStringAsFixed(1)} KB/s)');
          addSuccess('Flash Read Complete (stub mode).\n');
          setState('Read complete');
          return;
        } catch (e) {
          addErrorLine('Fast read failed: $e');
          // After stub upload, ROM commands won't work — can't fall back to slow read
          setState('Read failed');
          return;
        }
      }

      // Slow read fallback (ROM only, 64 bytes at a time) — only when stub was NOT uploaded
      setState('Reading flash (slow)...');
      addLogLine('Starting slow flash read: $totalSize bytes from '
          '0x${startAddr.toRadixString(16).toUpperCase()}...');
      const int blockSize = 64;
      final result = BytesBuilder();
      int currentAddr = startAddr;
      while (currentAddr < startAddr + totalSize) {
        if (isCancelled) break;
        final toRead = (startAddr + totalSize - currentAddr).clamp(0, blockSize);
        final block = await _readFlashBlockSlow(currentAddr, toRead);
        if (block == null || block.isEmpty) {
          final done = currentAddr - startAddr;
          final pct = (done * 100.0 / totalSize).toStringAsFixed(1);
          addErrorLine('Failed to read block at '
              '0x${currentAddr.toRadixString(16).toUpperCase()} ($pct% done, $done/$totalSize bytes)');
          return;
        }
        result.add(block);
        currentAddr += block.length;
        final done = currentAddr - startAddr;
        setProgress(done, totalSize);
        final elapsed = sw.elapsedMilliseconds / 1000.0;
        final speed = elapsed > 0 ? (done / 1024.0) / elapsed : 0.0;
        setState('${(done / 1024).toStringAsFixed(0)} KB / ${(totalSize / 1024).toStringAsFixed(0)} KB at ${speed.toStringAsFixed(1)} KB/s');
      }
      _readResult = result.toBytes();
      sw.stop();
      final secs = sw.elapsedMilliseconds / 1000.0;
      final kbps = (totalSize / 1024.0) / secs;
      addLogLine('Read $totalSize bytes in ${secs.toStringAsFixed(1)}s '
          '(${kbps.toStringAsFixed(1)} KB/s)');
      addSuccess('Flash Read Complete.\n');
      setState('Read complete');
    } catch (e) {
      addErrorLine('Exception: $e');
    }
  }

  @override
  Uint8List? getReadResult() => _readResult;

  @override
  Future<void> closePort() async {
    _rxSub?.cancel();
    _rxSub = null;
    await transport.disconnect();
  }

  @override
  void dispose() {
    _rxSub?.cancel();
  }

  // ════════════════════════════════════════════════════════════════════════
  //  SERIAL I/O — async rx buffer (same pattern as BK7231Flasher)
  // ════════════════════════════════════════════════════════════════════════

  Future<bool> _openPort() async {
    try {
      // ESP32 ROM bootloader communicates at 115200 baud.
      // Set initial baud rate BEFORE connecting so the port opens at 115200
      // (avoids a close/reopen cycle that can cause timing issues).
      if (transport is dynamic) {
        try {
          (transport as dynamic).setInitialBaudRate(115200);
        } catch (_) {}
      }
      final ok = await transport.connect();
      if (!ok) {
        addErrorLine('Failed to open serial port!');
        return false;
      }
      _rxBuffer.clear();
      _rxSub?.cancel();
      _rxSub = transport.stream.listen((data) {
        _rxBuffer.addAll(data);
      });
      return true;
    } catch (e) {
      addErrorLine('Serial port exception: $e');
      return false;
    }
  }

  void _consumePending() {
    _rxBuffer.clear();
  }

  /// Wait for at least [count] bytes in _rxBuffer within [timeoutMs].
  Future<bool> _waitForBytes(int count, int timeoutMs) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (_rxBuffer.length < count) {
      if (DateTime.now().isAfter(deadline)) return false;
      await Future.delayed(const Duration(milliseconds: 1));
    }
    return true;
  }

  // ════════════════════════════════════════════════════════════════════════
  //  SLIP FRAMING
  // ════════════════════════════════════════════════════════════════════════

  /// SLIP-encode [inner] and write to transport.
  void _sendSlipPacket(Uint8List inner) {
    // Worst case: every byte needs escaping (2×) + 2 framing bytes
    final packet = Uint8List(inner.length * 2 + 2);
    int pos = 0;
    packet[pos++] = _slipEnd;
    for (final b in inner) {
      if (b == _slipEnd) {
        packet[pos++] = _slipEsc;
        packet[pos++] = _slipEscEnd;
      } else if (b == _slipEsc) {
        packet[pos++] = _slipEsc;
        packet[pos++] = _slipEscEsc;
      } else {
        packet[pos++] = b;
      }
    }
    packet[pos++] = _slipEnd;
    transport.write(Uint8List.sublistView(packet, 0, pos));
  }

  /// Read one SLIP-framed packet from _rxBuffer within [timeoutMs].
  /// Returns the decoded payload, or null on timeout.
  Future<Uint8List?> _readSlipPacket(int timeoutMs) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    final payload = <int>[];
    bool inPacket = false;
    bool escape = false;

    while (true) {
      if (DateTime.now().isAfter(deadline)) return null;

      if (_rxBuffer.isEmpty) {
        await Future.delayed(const Duration(milliseconds: 1));
        continue;
      }

      final b = _rxBuffer.removeFirst();

      if (b == _slipEnd) {
        if (inPacket && payload.isNotEmpty) {
          return Uint8List.fromList(payload);
        }
        inPacket = true;
        payload.clear();
        escape = false;
      } else if (inPacket) {
        if (b == _slipEsc) {
          escape = true;
        } else if (escape) {
          if (b == _slipEscEnd) {
            payload.add(_slipEnd);
          } else if (b == _slipEscEsc) {
            payload.add(_slipEsc);
          }
          escape = false;
        } else {
          payload.add(b);
        }
      }
    }
  }

  // ════════════════════════════════════════════════════════════════════════
  //  COMMAND / RESPONSE PROTOCOL
  // ════════════════════════════════════════════════════════════════════════

  /// Send an ESP bootloader command.
  /// Packet: [0x00, op, len_lo, len_hi, chk_0..chk_3, data...]
  void _sendCommand(int op, Uint8List data, {int checksum = 0}) {
    final inner = Uint8List(8 + data.length);
    inner[0] = 0x00; // direction: request
    inner[1] = op;
    inner[2] = data.length & 0xFF;
    inner[3] = (data.length >> 8) & 0xFF;
    // checksum as 4 LE bytes
    inner[4] = checksum & 0xFF;
    inner[5] = (checksum >> 8) & 0xFF;
    inner[6] = (checksum >> 16) & 0xFF;
    inner[7] = (checksum >> 24) & 0xFF;
    inner.setRange(8, 8 + data.length, data);
    _sendSlipPacket(inner);
  }

  /// Read a response packet, matching [expectedCmd].
  ///
  /// [respDataLen] is the number of payload data bytes before the 2 status bytes.
  /// For most commands this is 0.
  ///
  /// Returns:
  /// - For respDataLen > 0: the data bytes (without status)
  /// - For respDataLen == 0: 4 bytes of the `value` field from the header
  /// - null on timeout or error
  Future<Uint8List?> _readPacket(int timeoutMs, int expectedCmd, {int respDataLen = 0}) async {
    final startTime = DateTime.now();

    for (int retry = 0; retry < 100; retry++) {
      final elapsed = DateTime.now().difference(startTime).inMilliseconds;
      if (elapsed >= timeoutMs) break;

      final raw = await _readSlipPacket(timeoutMs - elapsed);
      if (raw == null) return null;

      // Parse: resp(1) op_ret(1) len_ret(2) val(4) [data...]
      if (raw.length < 8) continue;

      final resp = raw[0];
      final opRet = raw[1];
      // val is at bytes 4..7 (little-endian)
      final val = raw[4] | (raw[5] << 8) | (raw[6] << 16) | (raw[7] << 24);
      final data = raw.length > 8
          ? Uint8List.sublistView(raw, 8)
          : Uint8List(0);

      if (resp != 0x01) continue; // Not a response
      if (expectedCmd != 0 && opRet != expectedCmd) continue; // Wrong command

      // check_command: status_bytes = data[respDataLen : respDataLen + 2]
      if (data.length < respDataLen + 2) {
        // Short response — check if there's an error in the first 2 bytes
        if (data.length >= 2 && data[0] != 0) {
          addErrorLine('CMD 0x${opRet.toRadixString(16)} error: '
              'status=0x${data[0].toRadixString(16)} '
              'err=0x${data[1].toRadixString(16)}');
          return null;
        }
        // Return the value field
        return _uint32ToBytes(val);
      }

      // Check status
      if (data[respDataLen] != 0) {
        addErrorLine('CMD 0x${opRet.toRadixString(16)} error: '
            'status=0x${data[respDataLen].toRadixString(16)} '
            'err=0x${data[respDataLen + 1].toRadixString(16)}');
        return null;
      }

      // Return data or value
      if (respDataLen > 0) {
        return Uint8List.sublistView(data, 0, respDataLen);
      }
      return _uint32ToBytes(val);
    }
    return null;
  }

  /// Perform the exact same reset as C# ESPFlasher.Connect():
  ///   serial.DtrEnable = false;
  ///   serial.RtsEnable = true;
  ///   Thread.Sleep(100);
  ///   serial.DtrEnable = true;
  ///   serial.RtsEnable = false;
  ///   Thread.Sleep(500);
  Future<void> _resetIntoBootloader() async {
    addLogLine('Resetting ESP32 into bootloader...');

    await transport.setDTR(false);
    await transport.setRTS(true);
    await Future.delayed(const Duration(milliseconds: 100));

    await transport.setDTR(true);
    await transport.setRTS(false);
    await Future.delayed(const Duration(milliseconds: 500));

    _consumePending();
  }

  Future<bool> _connect() async {
    setState('Connecting to ESP32...');
    addLogLine('Attempting to connect to ESP32...');

    if (!await _openPort()) return false;

    for (int attempt = 0; attempt < 4; attempt++) {
      if (isCancelled) return false;
      addLogLine('Connection attempt ${attempt + 1}/4...');
      await _resetIntoBootloader();

      if (await _sync()) {
        setState('ESP32 synced');
        addSuccess('\nSynced with ESP32!\n');
        if (!await _spiAttach()) {
          addErrorLine('Failed to configure SPI pins.');
          return false;
        }
        return true;
      }
      addLogLine('Sync failed on attempt ${attempt + 1}.');
    }

    addErrorLine('Failed to sync with ESP32 after all attempts.');
    return false;
  }

  Future<bool> _sync() async {
    // Sync data: 0x07, 0x07, 0x12, 0x20, then 32 × 0x55
    final syncData = Uint8List(36);
    syncData[0] = 0x07;
    syncData[1] = 0x07;
    syncData[2] = 0x12;
    syncData[3] = 0x20;
    for (int i = 4; i < 36; i++) {
      syncData[i] = 0x55;
    }

    for (int i = 0; i < 10; i++) {
      if (isCancelled) return false;
      try {
        _consumePending();
        _sendCommand(_ESPCmd.sync, syncData);

        // Wait a bit for data to arrive, then check
        await Future.delayed(const Duration(milliseconds: 200));

        // Log raw RX for diagnostics on first 2 iterations
        if (i < 2 && _rxBuffer.isNotEmpty) {
          final preview = _rxBuffer.take(48).map(
            (b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()
          ).join(' ');
          addLogLine('  Sync attempt $i: RX ${_rxBuffer.length} bytes: $preview');
        }

        final resp = await _readPacket(300, _ESPCmd.sync);
        if (resp != null) {
          addLogLine('Sync response received!');
          // Drain additional SYNC responses (esptool does this)
          for (int j = 0; j < 7; j++) {
            try {
              await _readPacket(100, _ESPCmd.sync);
            } catch (_) {}
          }
          return true;
        }
      } catch (_) {
        // Ignore timeout
      }
      await Future.delayed(const Duration(milliseconds: 50));
    }

    // Log buffer state for debugging
    if (_rxBuffer.isNotEmpty) {
      final preview = _rxBuffer.take(48).map(
        (b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()
      ).join(' ');
      addLogLine('RX buffer has ${_rxBuffer.length} bytes after sync attempts: $preview');
    } else {
      addLogLine('RX buffer empty after sync attempts — no data received from ESP32.');
    }
    return false;
  }

  // ════════════════════════════════════════════════════════════════════════
  //  REGISTER READ / WRITE
  // ════════════════════════════════════════════════════════════════════════

  Future<int> _readReg(int addr) async {
    final payload = _uint32ToBytes(addr);
    addLogLine('Reading Reg 0x${addr.toRadixString(16).toUpperCase()}...');
    _sendCommand(_ESPCmd.readReg, payload);
    final resp = await _readPacket(3000, _ESPCmd.readReg);
    if (resp != null && resp.length >= 4) {
      return resp[0] | (resp[1] << 8) | (resp[2] << 16) | (resp[3] << 24);
    }
    throw Exception('Failed to read register 0x${addr.toRadixString(16)}');
  }

  Future<void> _writeReg(int addr, int value, {int mask = 0xFFFFFFFF, int delay = 0}) async {
    final payload = BytesBuilder();
    payload.add(_uint32ToBytes(addr));
    payload.add(_uint32ToBytes(value));
    payload.add(_uint32ToBytes(mask));
    payload.add(_uint32ToBytes(delay));
    _sendCommand(_ESPCmd.writeReg, payload.toBytes());
    await _readPacket(1000, _ESPCmd.writeReg);
  }

  // ════════════════════════════════════════════════════════════════════════
  //  SPI ATTACH / SPI COMMANDS
  // ════════════════════════════════════════════════════════════════════════

  Future<bool> _spiAttach() async {
    try {
      addLogLine('Configuring SPI flash pins (SpiAttach)...');
      // ROM needs 8 bytes, stub needs 4
      final payloadSize = _isStub ? 4 : 8;
      final payload = Uint8List(payloadSize);
      _sendCommand(_ESPCmd.spiAttach, payload);
      final resp = await _readPacket(3000, _ESPCmd.spiAttach);
      if (resp == null) {
        addErrorLine('SPI_ATTACH failed (no response).');
        return false;
      }
      addLogLine('SPI_ATTACH success.');
      return true;
    } catch (e) {
      addErrorLine('SPI_ATTACH exception: $e');
      return false;
    }
  }

  Future<bool> _spiSetParams(int size) async {
    try {
      addLogLine('Setting SPI flash params for ${size ~/ 1024 ~/ 1024}MB...');
      final payload = ByteData(24);
      payload.setUint32(0, 0, Endian.little);          // id
      payload.setUint32(4, size, Endian.little);       // total size
      payload.setUint32(8, 64 * 1024, Endian.little);  // block size
      payload.setUint32(12, 4 * 1024, Endian.little);  // sector size
      payload.setUint32(16, 256, Endian.little);        // page size
      payload.setUint32(20, 0xFFFF, Endian.little);     // status mask
      _sendCommand(_ESPCmd.spiSetParams, payload.buffer.asUint8List());
      final resp = await _readPacket(1000, _ESPCmd.spiSetParams);
      if (resp == null) {
        addErrorLine('SPI_SET_PARAMS failed (no response)');
        return false;
      }
      addLogLine('SPI_SET_PARAMS success');
      return true;
    } catch (e) {
      addErrorLine('SPI_SET_PARAMS exception: $e');
      return false;
    }
  }

  Future<bool> _changeBaudrate(int newBaud) async {
    try {
      addLogLine('Requesting baud rate change to $newBaud...');
      final payload = ByteData(8);
      payload.setUint32(0, newBaud, Endian.little);
      // second arg: old baud when stub, 0 for ROM
      payload.setUint32(4, _isStub ? 115200 : 0, Endian.little);
      _sendCommand(_ESPCmd.changeBaudrate, payload.buffer.asUint8List());
      final resp = await _readPacket(3000, _ESPCmd.changeBaudrate);
      if (resp == null) {
        addErrorLine('Baudrate change request failed (no response)');
        return false;
      }
      await Future.delayed(const Duration(milliseconds: 50));
      await transport.setBaudRate(newBaud);
      await Future.delayed(const Duration(milliseconds: 50));
      // Web transport closes/reopens port on baud change — re-subscribe rx stream
      _rxSub?.cancel();
      _rxSub = transport.stream.listen((data) {
        _rxBuffer.addAll(data);
      });
      _consumePending();
      addLogLine('Baud rate changed to $newBaud successfully.');
      return true;
    } catch (e) {
      addErrorLine('ChangeBaudrate exception: $e');
      return false;
    }
  }

  /// Run a SPI flash command by manipulating ESP32 SPI peripheral registers.
  Future<int> _runSpiFlashCmd(int cmd, {int readBits = 0}) async {
    // Select chip-specific SPI register addresses
    final int baseAddr;
    final int w0Offs;
    final int usrOffs;
    final int usr2Offs;
    final int mosiDlenOffs;
    final int misoDlenOffs;

    if (_isESP32S3 || _isESP32C3) {
      baseAddr = _esp32s3SpiRegBase;
      w0Offs = _esp32s3SpiW0Offs;
      usrOffs = _esp32s3SpiUsrOffs;
      usr2Offs = _esp32s3SpiUsr2Offs;
      mosiDlenOffs = _esp32s3SpiMosiDlenOffs;
      misoDlenOffs = _esp32s3SpiMisoDlenOffs;
    } else {
      baseAddr = _esp32SpiRegBase;
      w0Offs = _spiW0Offs;
      usrOffs = _spiUsrOffs;
      usr2Offs = _spiUsr2Offs;
      mosiDlenOffs = _spiMosiDlenOffs;
      misoDlenOffs = _spiMisoDlenOffs;
    }

    // Set MISO length
    if (readBits > 0) {
      await _writeReg(baseAddr + misoDlenOffs, readBits - 1);
    } else {
      await _writeReg(baseAddr + misoDlenOffs, 0);
    }
    // Set MOSI length = 0
    await _writeReg(baseAddr + mosiDlenOffs, 0);

    // SPI_USR_REG: COMMAND(31) | MISO(28) if read
    int usrFlags = 1 << 31; // COMMAND
    if (readBits > 0) usrFlags |= 1 << 28; // MISO
    await _writeReg(baseAddr + usrOffs, usrFlags);

    // SPI_USR2_REG: (7 << 28) | cmd
    final usr2 = (7 << 28) | cmd;
    await _writeReg(baseAddr + usr2Offs, usr2);

    // Execute: SPI_CMD_REG bit 18 (USR)
    await _writeReg(baseAddr, 1 << 18);

    // Poll for completion
    for (int i = 0; i < 50; i++) {
      final val = await _readReg(baseAddr);
      if ((val & (1 << 18)) == 0) break;
      await Future.delayed(const Duration(milliseconds: 1));
    }

    // Read result from W0
    if (readBits > 0) {
      return await _readReg(baseAddr + w0Offs);
    }
    return 0;
  }

  // ════════════════════════════════════════════════════════════════════════
  //  CHIP & FLASH IDENTIFICATION
  // ════════════════════════════════════════════════════════════════════════

  Future<String?> _getChipId() async {
    // Try GET_SECURITY_INFO first (ESP32-C3 and later)
    try {
      addLogLine('Trying GET_SECURITY_INFO...');
      _sendCommand(_ESPCmd.getSecurityInfo, Uint8List(0));
      final resp = await _readPacket(1000, _ESPCmd.getSecurityInfo);
      if (resp != null && resp.length >= 20) {
        // Chip ID is at offset 12 (after flags(4) + flash_crypt_cnt(1) + key_purposes(7))
        final chipId = resp[12] | (resp[13] << 8) | (resp[14] << 16) | (resp[15] << 24);
        final chipName = _chipIDs[chipId] ?? 'Unknown';
        addLogLine('Got Chip ID from Security Info: $chipId ($chipName)');
        return chipName;
      } else if (resp != null) {
        addLogLine('GET_SECURITY_INFO returned ${resp.length} bytes.');
        if (resp.length == 4) {
          final val = resp[0] | (resp[1] << 8) | (resp[2] << 16) | (resp[3] << 24);
          addLogLine('Value: 0x${val.toRadixString(16).toUpperCase()}');
        }
      }
    } catch (e) {
      addLogLine('GET_SECURITY_INFO failed: $e');
    }

    // Fallback: Read Magic Register 0x40001000
    try {
      addLogLine('Trying ReadReg 0x40001000...');
      final val = await _readReg(0x40001000);
      final chipName = _chipMagicValues[val] ?? 'Unknown';
      addLogLine('Read Magic Reg 0x40001000: 0x${val.toRadixString(16).toUpperCase()} ($chipName)');
      if (val == 0) {
        addLogLine('Warning: Read 0, this might indicate read failure or unsupported register.');
      }
      return chipName;
    } catch (e) {
      addErrorLine('Failed to read chip magic: $e');
    }
    return null;
  }

  Future<int?> _readFlashId() async {
    try {
      addLogLine('Reading Flash ID...');
      // CMD 0x9F (RDID), read 24 bits
      final fid = await _runSpiFlashCmd(0x9F, readBits: 24);
      addLogLine('Flash ID: 0x${fid.toRadixString(16).toUpperCase()}');

      // Decode size
      final sizeCode = (fid >> 16) & 0xFF;
      if (sizeCode > 0 && sizeCode <= 31) {
        final size = 1 << sizeCode;
        addLogLine('Detected Flash Size: $size bytes (${size ~/ 1024 ~/ 1024}MB)');
      } else {
        addLogLine('Unknown Flash Size Code: 0x${sizeCode.toRadixString(16).toUpperCase()}');
      }
      return fid;
    } catch (e) {
      addErrorLine('Failed to read Flash ID: $e');
    }
    return null;
  }

  // ════════════════════════════════════════════════════════════════════════
  //  STUB UPLOAD (MEM_BEGIN / MEM_DATA / MEM_END)
  // ════════════════════════════════════════════════════════════════════════

  Future<bool> _memBegin(int size, int blocks, int blockSize, int offset) async {
    final payload = ByteData(16);
    payload.setUint32(0, size, Endian.little);
    payload.setUint32(4, blocks, Endian.little);
    payload.setUint32(8, blockSize, Endian.little);
    payload.setUint32(12, offset, Endian.little);
    _sendCommand(_ESPCmd.memBegin, payload.buffer.asUint8List());
    final resp = await _readPacket(5000, _ESPCmd.memBegin);
    return resp != null;
  }

  Future<bool> _memData(Uint8List data, int seq) async {
    final header = ByteData(16);
    header.setUint32(0, data.length, Endian.little);
    header.setUint32(4, seq, Endian.little);
    header.setUint32(8, 0, Endian.little);  // reserved
    header.setUint32(12, 0, Endian.little); // reserved
    final payload = Uint8List(16 + data.length);
    payload.setRange(0, 16, header.buffer.asUint8List());
    payload.setRange(16, 16 + data.length, data);
    // checksum: XOR all data bytes starting from 0xEF
    int checksum = 0xEF;
    for (final b in data) {
      checksum ^= b;
    }
    _sendCommand(_ESPCmd.memData, payload, checksum: checksum);
    final resp = await _readPacket(5000, _ESPCmd.memData);
    return resp != null;
  }

  Future<bool> _memEnd(int entryPoint) async {
    final payload = ByteData(8);
    payload.setUint32(0, entryPoint == 0 ? 1 : 0, Endian.little); // no_entry
    payload.setUint32(4, entryPoint, Endian.little);
    _sendCommand(_ESPCmd.memEnd, payload.buffer.asUint8List());
    final resp = await _readPacket(3000, _ESPCmd.memEnd);
    return resp != null;
  }

  Future<bool> _uploadStub() async {
    setState('Uploading stub...');
    addLogLine('Uploading stub flasher...');
    try {
      final jsonContent = await rootBundle.loadString(
        'assets/${_isESP32S3 ? "ESP32S3_Stub" : _isESP32C3 ? "ESP32C3_Stub" : "ESP32_Stub"}.json',
      );
      final stubJson = jsonDecode(jsonContent) as Map<String, dynamic>;

      final textB64 = stubJson['text'] as String;
      final dataB64 = stubJson['data'] as String;
      final textStart = stubJson['text_start'] as int;
      final dataStart = stubJson['data_start'] as int;
      final entry = stubJson['entry'] as int;

      final textBytes = base64Decode(textB64);
      final dataBytes = base64Decode(dataB64);

      // Upload text (IRAM)
      int blocks = (textBytes.length + _espRamBlock - 1) ~/ _espRamBlock;
      if (!await _memBegin(textBytes.length, blocks, _espRamBlock, textStart)) {
        addErrorLine('Failed to MEM_BEGIN for text');
        return false;
      }
      for (int i = 0; i < blocks; i++) {
        final start = i * _espRamBlock;
        final end = (start + _espRamBlock).clamp(0, textBytes.length);
        final block = Uint8List.sublistView(textBytes, start, end);
        if (!await _memData(block, i)) {
          addErrorLine('Failed to MEM_DATA text block $i');
          return false;
        }
      }

      // Upload data (DRAM)
      blocks = (dataBytes.length + _espRamBlock - 1) ~/ _espRamBlock;
      if (!await _memBegin(dataBytes.length, blocks, _espRamBlock, dataStart)) {
        addErrorLine('Failed to MEM_BEGIN for data');
        return false;
      }
      for (int i = 0; i < blocks; i++) {
        final start = i * _espRamBlock;
        final end = (start + _espRamBlock).clamp(0, dataBytes.length);
        final block = Uint8List.sublistView(dataBytes, start, end);
        if (!await _memData(block, i)) {
          addErrorLine('Failed to MEM_DATA data block $i');
          return false;
        }
      }

      // Execute stub
      addLogLine('Running stub flasher...');
      await _memEnd(entry);

      // Wait for OHAI
      if (!await _checkForOHAI(5000)) {
        addErrorLine('Stub did not respond with OHAI.');
        return false;
      }

      _isStub = true;
      addLogLine('Stub flasher running.');
      return true;
    } catch (e) {
      addErrorLine('Stub upload failed: $e');
      return false;
    }
  }

  /// After MEM_END, the stub sends a raw SLIP packet containing "OHAI" (4F 48 41 49)
  Future<bool> _checkForOHAI(int timeoutMs) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    final buffer = <int>[];
    while (DateTime.now().isBefore(deadline)) {
      if (_rxBuffer.isEmpty) {
        await Future.delayed(const Duration(milliseconds: 1));
        continue;
      }
      buffer.add(_rxBuffer.removeFirst());
      // Check for SLIP-framed OHAI: C0 4F 48 41 49 C0
      if (buffer.length >= 6) {
        final n = buffer.length;
        if (buffer[n - 1] == 0xC0 &&
            buffer[n - 2] == 0x49 && // I
            buffer[n - 3] == 0x41 && // A
            buffer[n - 4] == 0x48 && // H
            buffer[n - 5] == 0x4F && // O
            buffer[n - 6] == 0xC0) {
          return true;
        }
      }
    }
    return false;
  }

  // ════════════════════════════════════════════════════════════════════════
  //  FLASH WRITE (full speed via stub)
  // ════════════════════════════════════════════════════════════════════════

  @override
  Future<void> doWrite(int startSector, Uint8List data) async {
    try {
      if (!await _connect()) {
        setState('Connection failed!');
        addErrorLine('Failed to connect to ESP32.');
        return;
      }

      // Upload stub for faster writes
      final stubOk = await _uploadStub();
      if (stubOk) {
        await _spiAttach();
        if (baudrate > 115200) {
          await _changeBaudrate(baudrate);
        }
      }

      final int offset = startSector;
      const int blockSize = 0x400; // 1024 bytes
      final int numBlocks = (data.length + blockSize - 1) ~/ blockSize;

      setState('Writing flash...');
      addLogLine('Starting Flash Write: ${data.length} bytes '
          '($numBlocks blocks) at 0x${offset.toRadixString(16).toUpperCase()}...');
      final sw = Stopwatch()..start();

      // ── FLASH_BEGIN: size(4) + numBlocks(4) + blockSize(4) + offset(4)
      final beginPayload = ByteData(16);
      beginPayload.setUint32(0, data.length, Endian.little);
      beginPayload.setUint32(4, numBlocks, Endian.little);
      beginPayload.setUint32(8, blockSize, Endian.little);
      beginPayload.setUint32(12, offset, Endian.little);

      _sendCommand(_ESPCmd.flashBegin, beginPayload.buffer.asUint8List());
      // FLASH_BEGIN can take a long time if it triggers an erase
      final beginResp = await _readPacket(10000, _ESPCmd.flashBegin);
      if (beginResp == null) {
        addErrorLine('FLASH_BEGIN failed.');
        return;
      }

      // ── FLASH_DATA loop — pre-allocate reusable buffers outside loop
      final block = Uint8List(blockSize);
      final payload = Uint8List(16 + blockSize);
      final header = ByteData.sublistView(payload, 0, 16);
      header.setUint32(0, blockSize, Endian.little);
      header.setUint32(8, 0, Endian.little);  // reserved
      header.setUint32(12, 0, Endian.little); // reserved

      for (int i = 0; i < numBlocks; i++) {
        if (isCancelled) {
          addWarningLine('Write cancelled by user.');
          return;
        }

        final int start = i * blockSize;
        final int len = (data.length - start).clamp(0, blockSize);

        // Fill block: data then 0xFF padding
        block.setRange(0, len, data, start);
        if (len < blockSize) {
          block.fillRange(len, blockSize, 0xFF);
        }

        // Update only the seq field in the pre-allocated header
        header.setUint32(4, i, Endian.little);
        payload.setRange(16, 16 + blockSize, block);

        // XOR checksum over the data block
        int checksum = 0xEF;
        for (final b in block) {
          checksum ^= b;
        }

        bool success = false;
        for (int retry = 0; retry < 3; retry++) {
          _sendCommand(_ESPCmd.flashData, payload, checksum: checksum);
          final resp = await _readPacket(3000, _ESPCmd.flashData);
          if (resp != null) {
            success = true;
            break;
          }
          addWarningLine('FLASH_DATA failed at block $i, retry ${retry + 1}...');
        }

        if (!success) {
          addErrorLine('FLASH_DATA failed at block $i after 3 retries.');
          return;
        }

        // Progress
        final written = (i + 1) * blockSize;
        setProgress(written.clamp(0, data.length), data.length);
        final elapsed = sw.elapsedMilliseconds / 1000.0;
        final kbps = elapsed > 0 ? (written / 1024.0) / elapsed : 0.0;
        setState('${(written / 1024).toStringAsFixed(0)} KB / '
            '${(data.length / 1024).toStringAsFixed(0)} KB at '
            '${kbps.toStringAsFixed(1)} KB/s');
      }

      sw.stop();
      final secs = sw.elapsedMilliseconds / 1000.0;
      final kbps = (data.length / 1024.0) / secs;
      addLogLine('Wrote ${data.length} bytes at '
          '0x${offset.toRadixString(16).toUpperCase()} in '
          '${secs.toStringAsFixed(1)}s (${kbps.toStringAsFixed(1)} KB/s)');
      addSuccess('Flash Write Complete.\n');
      setState('Write complete');

      // ── MD5 verification BEFORE FLASH_END (stub must still be running)
      if (_isStub) {
        setState('Verifying MD5...');
        addLogLine('Verifying write with MD5...');
        try {
          final calcDigest = md5.convert(data);
          final expected = calcDigest.bytes
              .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
              .join();

          final actual = await _flashMd5Sum(offset, data.length);
          if (actual == null) {
            addErrorLine('Failed to get Flash MD5');
          } else if (actual != expected) {
            addErrorLine('MD5 Mismatch! Expected $expected, Got $actual');
          } else {
            addLogLine('Write Verified Successfully!');
            setState('Write verified');
          }
        } catch (e) {
          addErrorLine('Verification exception: $e');
        }
      }

      // ── FLASH_END: no_entry=1 means stay in bootloader (don't reboot)
      addLogLine('Sending FLASH_END...');
      _sendCommand(_ESPCmd.flashEnd, _uint32ToBytes(1));
      final endResp = await _readPacket(1000, _ESPCmd.flashEnd);
      if (endResp == null) {
        addWarningLine('FLASH_END: no response (non-fatal).');
      } else {
        addLogLine('FLASH_END OK.');
      }
    } catch (e) {
      addErrorLine('Write exception: $e');
    }
  }

  // ════════════════════════════════════════════════════════════════════════
  //  FLASH MD5 (stub command for verification)
  // ════════════════════════════════════════════════════════════════════════

  /// Request MD5 hash of flash region from the stub/ROM.
  /// Returns hex string (uppercase), or null on failure.
  Future<String?> _flashMd5Sum(int addr, int size) async {
    // Payload: addr(4) + size(4) + reserved(4) + reserved(4)
    final payload = ByteData(16);
    payload.setUint32(0, addr, Endian.little);
    payload.setUint32(4, size, Endian.little);
    payload.setUint32(8, 0, Endian.little);
    payload.setUint32(12, 0, Endian.little);

    _sendCommand(_ESPCmd.spiFlashMd5, payload.buffer.asUint8List());

    // Timeout: 8 seconds per MB, minimum 5s
    final timeout = (8.0 * size / 1000000.0 * 1000).toInt().clamp(5000, 60000);

    // Stub returns 16 raw MD5 bytes, ROM returns 32 hex chars
    final rdl = _isStub ? 16 : 32;
    final resp = await _readPacket(timeout, _ESPCmd.spiFlashMd5, respDataLen: rdl);
    if (resp == null) return null;

    if (_isStub) {
      // 16 raw bytes → uppercase hex string
      return resp.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join();
    } else {
      // 32 ASCII hex chars
      return String.fromCharCodes(resp).toUpperCase();
    }
  }

  // ════════════════════════════════════════════════════════════════════════
  //  FLASH READ — SLOW (ROM, 64 bytes at a time)
  // ════════════════════════════════════════════════════════════════════════

  Future<Uint8List?> _readFlashBlockSlow(int addr, int size) async {
    const blockLen = 64;
    final result = BytesBuilder();
    while (result.length < size) {
      final readLen = (size - result.length).clamp(0, blockLen);
      final payload = ByteData(8);
      payload.setUint32(0, addr + result.length, Endian.little);
      payload.setUint32(4, readLen, Endian.little);
      _sendCommand(_ESPCmd.readFlashSlow, payload.buffer.asUint8List());
      // ROM always returns 64 bytes of data + 2 status bytes
      final resp = await _readPacket(3000, _ESPCmd.readFlashSlow, respDataLen: blockLen);
      if (resp == null || resp.length < readLen) {
        addErrorLine('ReadFlashBlockSlow: failed at '
            '0x${(addr + result.length).toRadixString(16).toUpperCase()}');
        return null;
      }
      result.add(Uint8List.sublistView(resp, 0, readLen));
    }
    return result.toBytes();
  }

  // ════════════════════════════════════════════════════════════════════════
  //  FLASH READ — FAST (stub, streamed with ACK)
  // ════════════════════════════════════════════════════════════════════════

  /// Send raw SLIP-framed data (no command header, used for ACKs during fast read)
  void _sendRawSlip(Uint8List data) {
    final packet = Uint8List(data.length * 2 + 2);
    int pos = 0;
    packet[pos++] = _slipEnd;
    for (final b in data) {
      if (b == _slipEnd) {
        packet[pos++] = _slipEsc;
        packet[pos++] = _slipEscEnd;
      } else if (b == _slipEsc) {
        packet[pos++] = _slipEsc;
        packet[pos++] = _slipEscEsc;
      } else {
        packet[pos++] = b;
      }
    }
    packet[pos++] = _slipEnd;
    transport.write(Uint8List.sublistView(packet, 0, pos));
  }

  /// Read one raw SLIP-decoded packet directly into [dest] at [destOffset].
  /// Returns the number of bytes written, or -1 on timeout.
  Future<int> _readRawPacketInto(Uint8List dest, int destOffset, int timeoutMs) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    bool inPacket = false;
    bool escape = false;
    int written = 0;

    while (DateTime.now().isBefore(deadline)) {
      if (_rxBuffer.isEmpty) {
        await Future.delayed(const Duration(milliseconds: 1));
        continue;
      }
      // Drain all available bytes in bulk to reduce yield overhead
      while (_rxBuffer.isNotEmpty) {
        final b = _rxBuffer.removeFirst();
        if (b == _slipEnd) {
          if (inPacket && written > 0) return written;
          inPacket = true;
          written = 0;
        } else if (inPacket) {
          if (b == _slipEsc) {
            escape = true;
          } else {
            int decoded = b;
            if (escape) {
              if (b == _slipEscEnd) decoded = _slipEnd;
              else if (b == _slipEscEsc) decoded = _slipEsc;
              escape = false;
            }
            dest[destOffset + written] = decoded;
            written++;
          }
        }
      }
    }
    return -1;
  }

  /// Read a raw SLIP-decoded packet. Returns null on timeout.
  Future<Uint8List?> _readRawPacket(int timeoutMs) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    final payload = <int>[];
    bool inPacket = false;
    bool escape = false;

    while (DateTime.now().isBefore(deadline)) {
      if (_rxBuffer.isEmpty) {
        await Future.delayed(const Duration(milliseconds: 1));
        continue;
      }
      final b = _rxBuffer.removeFirst();
      if (b == _slipEnd) {
        if (inPacket && payload.isNotEmpty) return Uint8List.fromList(payload);
        inPacket = true;
        payload.clear();
        escape = false;
      } else if (inPacket) {
        if (b == _slipEsc) {
          escape = true;
        } else if (escape) {
          if (b == _slipEscEnd) payload.add(_slipEnd);
          else if (b == _slipEscEsc) payload.add(_slipEsc);
          escape = false;
        } else {
          payload.add(b);
        }
      }
    }
    return null;
  }

  /// Fast flash read using the stub's READ_FLASH (0xD2) command.
  /// The stub streams data in SLIP packets and expects ACKs (bytes_received as u32 LE).
  Future<Uint8List> _readFlashFast(int addr, int size, Stopwatch sw) async {
    // READ_FLASH payload: offset(4) + length(4) + sector_size(4) + packet_size(4)
    final payload = ByteData(16);
    payload.setUint32(0, addr, Endian.little);
    payload.setUint32(4, size, Endian.little);
    payload.setUint32(8, 0x1000, Endian.little); // sector size
    payload.setUint32(12, 64, Endian.little);  // packet size (64 bytes, matches C#)

    _sendCommand(_ESPCmd.readFlash, payload.buffer.asUint8List());

    // Wait for ACK response
    final cmdResp = await _readPacket(3000, _ESPCmd.readFlash);
    if (cmdResp == null) {
      throw Exception('READ_FLASH command failed (no ACK)');
    }

    // Pre-allocate the full result buffer
    final dataBytes = Uint8List(size);
    final ackBuf = Uint8List(4);
    int received = 0;
    int lastProgress = 0;

    while (received < size) {
      if (isCancelled) throw Exception('Cancelled');

      int got = -1;
      for (int retry = 0; retry < 5; retry++) {
        got = await _readRawPacketInto(dataBytes, received, 3000);
        if (got > 0) break;
        // Timeout — re-send last ACK and retry
        final pct = (received * 100.0 / size).toStringAsFixed(1);
        addLogLine('Read timeout at 0x${(addr + received).toRadixString(16).toUpperCase()} '
            '($pct%), retry ${retry + 1}/5...');
        // Re-send ACK for current position to nudge the stub
        final retryAck = _uint32ToBytes(received);
        _sendRawSlip(retryAck);
        await Future.delayed(const Duration(milliseconds: 200));
      }
      if (got <= 0) {
        final pct = (received * 100.0 / size).toStringAsFixed(1);
        throw Exception('Timeout reading flash data at offset '
            '0x${(addr + received).toRadixString(16).toUpperCase()} ($pct% done, $received/$size bytes) after 5 retries');
      }
      received += got;

      // Send ACK (bytes received as u32 LE)
      ackBuf[0] = received & 0xFF;
      ackBuf[1] = (received >> 8) & 0xFF;
      ackBuf[2] = (received >> 16) & 0xFF;
      ackBuf[3] = (received >> 24) & 0xFF;
      _sendRawSlip(ackBuf);

      // Batch progress updates to reduce callback overhead
      if (received - lastProgress >= 4096 || received >= size) {
        setProgress(received, size);
        final elapsed = sw.elapsedMilliseconds / 1000.0;
        final kbps = elapsed > 0 ? (received / 1024.0) / elapsed : 0.0;
        setState('${(received / 1024).toStringAsFixed(0)} KB / ${(size / 1024).toStringAsFixed(0)} KB at ${kbps.toStringAsFixed(1)} KB/s');
        lastProgress = received;
      }
    }

    // After data, read MD5 digest (16 bytes)
    final digest = await _readRawPacket(3000);
    if (digest == null || digest.length != 16) {
      throw Exception('Failed to read MD5 digest');
    }

    // Verify MD5
    final calc = md5.convert(dataBytes).bytes;
    for (int i = 0; i < 16; i++) {
      if (calc[i] != digest[i]) {
        throw Exception(
          'MD5 mismatch! Expected ${digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}, '
          'Calc ${calc.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}'
        );
      }
    }

    addLogLine('Flash Read MD5 verified.');
    return dataBytes;
  }

  // ════════════════════════════════════════════════════════════════════════
  //  UTILITIES
  // ════════════════════════════════════════════════════════════════════════

  /// Convert an unsigned 32-bit integer to 4 little-endian bytes.
  static Uint8List _uint32ToBytes(int val) {
    return Uint8List.fromList([
      val & 0xFF,
      (val >> 8) & 0xFF,
      (val >> 16) & 0xFF,
      (val >> 24) & 0xFF,
    ]);
  }
}

