/// Winner Micro (W800/W600) flasher, ported from C# `WMFlasher.cs`.
///
/// Protocol: custom command frames (header `0x21`, CRC16 CCITT-FALSE) plus
/// XMODEM-1K for stub upload and firmware write.
///
/// Supports:
/// - W800: full read + write (with stub upload)
/// - W600: write-only (no flash read, no stub needed)
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show rootBundle;

import 'base_flasher.dart';
import 'crc.dart';
import 'xmodem.dart';

// ─── Constants ──────────────────────────────────────────────────────────────

/// Sector size shared with other flashers.
const int _sectorSize = 4096;

// ═══════════════════════════════════════════════════════════════════════════
//  WM Flasher
// ═══════════════════════════════════════════════════════════════════════════

class WMFlasher extends BaseFlasher {
  // ── Serial RX buffer (same pattern as ESPFlasher / BL602Flasher) ─────
  final List<int> _rxBuffer = [];
  StreamSubscription<Uint8List>? _rxSub;

  // ── Flash state ───────────────────────────────────────────────────────
  int _flashSizeMB = 2;
  int _currentBaud = 115200;
  Uint8List? _flashID;
  Uint8List? _readResult;

  // ── XMODEM sender ────────────────────────────────────────────────────
  late final XmodemSender _xm;

  WMFlasher({
    required super.transport,
    super.chipType = BKType.w800,
    super.baudrate,
  }) {
    // The port may already be open at the UI-selected baud rate.
    _currentBaud = baudrate;
    _xm = XmodemSender(transport)
      ..inactivityTimeoutMs = 5000
      ..maxRetries = 5
      ..paddingByte = 0xFF;
  }

  // ────────────────────────────────────────────────────────────────────────
  //  Serial helpers
  // ────────────────────────────────────────────────────────────────────────

  Future<bool> _openPort() async {
    try {
      final ok = await transport.connect();
      if (!ok) {
        addError('Serial port open failed!\n');
        return false;
      }
      // The WM bootloader always communicates at 115200.  The UI may have
      // opened the port at a different baud rate, so force 115200 here —
      // matching the C# code which does `new SerialPort(name, 115200)`.
      if (_currentBaud != 115200) {
        await transport.setBaudRate(115200);
        _currentBaud = 115200;
      }
      await transport.setDTR(false);
      await transport.setRTS(false);
      _rxBuffer.clear();
      _rxSub?.cancel();
      _rxSub = transport.stream.listen((data) {
        _rxBuffer.addAll(data);
      });
      return true;
    } catch (e) {
      addError('Port setup failed with $e!\n');
      return false;
    }
  }

  void _discardInput() {
    _rxBuffer.clear();
  }

  /// Wait for at least [count] bytes within [timeoutMs].
  Future<bool> _waitForBytes(int count, int timeoutMs) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (DateTime.now().isBefore(deadline)) {
      if (_rxBuffer.length >= count) return true;
      await Future.delayed(const Duration(milliseconds: 1));
    }
    return _rxBuffer.length >= count;
  }

  /// Read a single byte with timeout. Returns -1 on timeout.
  Future<int> _readByte(int timeoutMs) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (DateTime.now().isBefore(deadline)) {
      if (_rxBuffer.isNotEmpty) return _rxBuffer.removeAt(0);
      await Future.delayed(const Duration(milliseconds: 1));
    }
    return -1;
  }

  // ────────────────────────────────────────────────────────────────────────
  //  Generic setup
  // ────────────────────────────────────────────────────────────────────────

  Future<bool> _doGenericSetup() async {
    final now = DateTime.now();
    addLog('Now is: ${now.toIso8601String()}\n');
    addLog('Flasher mode: ${chipType.displayName}\n');
    addLog('Going to open port.\n');
    if (!await _openPort()) return false;
    addLog('Port ready!\n');
    return true;
  }

  // ────────────────────────────────────────────────────────────────────────
  //  Command protocol — 0x21 frames with CRC16 CCITT-FALSE
  // ────────────────────────────────────────────────────────────────────────

  /// Execute a WM bootloader command.
  ///
  /// Frame: `0x21 | lenLo | lenHi | crc16Lo | crc16Hi | type[4] | parms`
  Future<Uint8List?> _executeCommand(
    int type, {
    Uint8List? parms,
    double timeout = 0.1,
    int expectedReplyLen = 0,
    int br = 115200,
    bool isErrorExpected = false,
  }) async {
    final p = parms ?? const <int>[];
    final cmdLen = 4 + p.length; // 4 bytes type + payload

    // Build cmd: type as 4 LE bytes + parms
    final cmd = Uint8List(cmdLen);
    cmd[0] = type & 0xFF;
    cmd[1] = (type >> 8) & 0xFF;
    cmd[2] = (type >> 16) & 0xFF;
    cmd[3] = (type >> 24) & 0xFF;
    for (int i = 0; i < p.length; i++) {
      cmd[4 + i] = p[i];
    }

    // CRC16 over cmd
    final crc = CRC16.compute(CRC16Type.ccittFalse, cmd);

    // Build raw frame: 0x21 | (cmdLen+2) LE 16-bit | crc LE 16-bit | cmd
    final raw = Uint8List(3 + 2 + cmdLen);
    raw[0] = 0x21;
    final totalLen = cmdLen + 2;
    raw[1] = totalLen & 0xFF;
    raw[2] = (totalLen >> 8) & 0xFF;
    raw[3] = crc & 0xFF;
    raw[4] = (crc >> 8) & 0xFF;
    raw.setRange(5, 5 + cmdLen, cmd);

    _discardInput();
    await transport.write(raw);

    // Baud-rate change command: switch serial baud rate after sending.
    // This only runs on native platforms where setBaudRate is instant
    // (in-place change, no close/reopen). On web, _setBaud handles
    // the baud change sequence separately.
    if (type == 0x31 && !kIsWeb) {
      await Future.delayed(const Duration(milliseconds: 20));
      await transport.setBaudRate(br);
      _currentBaud = br;
    }

    // Wait for reply
    final timeoutMs = (timeout * 1000).toInt();
    await _waitForBytes(expectedReplyLen, timeoutMs);

    if (_rxBuffer.isEmpty) {
      if (!isErrorExpected) addErrorLine('Command response is empty!');
      return null;
    }

    final available = _rxBuffer.length;
    if (available < expectedReplyLen) {
      if (!isErrorExpected) {
        addErrorLine(
            'Command reply length $available < expected $expectedReplyLen');
      }
      return null;
    }

    final ret = Uint8List.fromList(
        _rxBuffer.sublist(0, expectedReplyLen > 0 ? expectedReplyLen : available));
    _rxBuffer.removeRange(0, ret.length);
    return ret;
  }

  // ────────────────────────────────────────────────────────────────────────
  //  Sync — wait for 'C' bytes from bootloader
  // ────────────────────────────────────────────────────────────────────────

  Future<bool> _sync() async {
    addLogLine('Waiting for bootloader sync (press RESET while BOOT is held)...');
    _discardInput();
    int count = 0;
    try {
      for (int attempt = 0; attempt < 1000; attempt++) {
        if (isCancelled) return false;
        final b = await _readByte(2000);
        if (b == 0x43) {
          count++;
        } else if (b == -1) {
          // Timeout — don't discard or reset count.
          // The bootloader may not have been reset yet, or 'C' bytes
          // may arrive just after the timeout window. Matches C# behavior
          // where ReadByte timeout simply continues the loop.
          addLogLine('Sync attempt $attempt/1000 — timeout');
        } else {
          if (chipType == BKType.w600) {
            if (b == 0x50) continue; // 'P' — skip
            // Send ESC burst for W600
            final esc = Uint8List(1);
            esc[0] = 0x1B;
            for (int i = 0; i < 250; i++) {
              await transport.write(esc);
              await Future.delayed(const Duration(milliseconds: 1));
            }
          } else {
            await Future.delayed(const Duration(milliseconds: 250));
          }
          addLogLine('Sync: unexpected byte 0x${b.toRadixString(16)}');
          _discardInput();
          count = 0;
        }
        if (count > 3) {
          addLogLine('Sync success!');
          return true;
        }
      }
    } catch (ex) {
      addErrorLine(ex.toString());
    }
    return false;
  }

  // ────────────────────────────────────────────────────────────────────────
  //  Flash ID
  // ────────────────────────────────────────────────────────────────────────

  Future<Uint8List?> _readFlashId() async {
    final res = await _executeCommand(0x3c,
        timeout: 1, expectedReplyLen: 10, isErrorExpected: true);

    if (res != null &&
        res.length >= 3 &&
        res[0] == 0x46 && // 'F'
        res[1] == 0x49 && // 'I'
        res[2] == 0x44) {
      // 'D'
      if (chipType == BKType.w600) {
        _flashID = Uint8List.fromList([
          int.parse(String.fromCharCodes([res[4], res[5]]), radix: 16),
        ]);
        addLogLine('Flash ID: 0x${_flashID![0].toRadixString(16).toUpperCase()}');
      } else {
        _flashID = Uint8List.fromList([
          int.parse(String.fromCharCodes([res[4], res[5]]), radix: 16),
          int.parse(String.fromCharCodes([res[7], res[8]]), radix: 16),
        ]);
        addLogLine(
            'Flash ID: 0x${_flashID![0].toRadixString(16).toUpperCase()}'
            'xx${_flashID![1].toRadixString(16).toUpperCase()}');
        _flashSizeMB = (1 << (_flashID![1] - 0x11)) ~/ 8;
        addLogLine('Flash size is ${_flashSizeMB}MB');
      }
    } else if (chipType == BKType.w600) {
      addLogLine('Getting flash id failed, assuming device is in secboot mode.');
      addLogLine('Erasing secboot, will resync...');
      await _executeCommand(0x3f, timeout: 1, expectedReplyLen: 2);
      if (!await _sync()) return null;
      return _readFlashId();
    }

    if (chipType != BKType.w600) {
      final romv =
          await _executeCommand(0x3e, timeout: 1, expectedReplyLen: 3);
      if (romv != null && romv.length >= 3) {
        addLogLine('ROM version: ${String.fromCharCode(romv[2])}');
      }
    }

    return _flashID;
  }

  // ────────────────────────────────────────────────────────────────────────
  //  Stub upload
  // ────────────────────────────────────────────────────────────────────────

  Future<bool> _uploadStub() async {
    if (chipType == BKType.w600) return true;

    Uint8List stub;
    try {
      // Try loading pre-decompressed stub first (works on all platforms)
      final raw = await rootBundle.load('assets/floaders/W800_Stub_raw.bin');
      stub = Uint8List.fromList(raw.buffer.asUint8List());
    } catch (_) {
      // Fall back to gzip-compressed stub (desktop/mobile only — dart:io gzip
      // is not available on web)
      final compressed =
          await rootBundle.load('assets/floaders/W800_Stub.bin');
      stub =
          Uint8List.fromList(gzip.decode(compressed.buffer.asUint8List()));
    }

    addLogLine('Sending stub (${stub.length} bytes)...');
    final sent = await _xm.send(stub);
    if (sent == stub.length) {
      addLogLine('Stub uploaded!');
      return _sync();
    }
    return false;
  }

  // ────────────────────────────────────────────────────────────────────────
  //  Baud rate
  // ────────────────────────────────────────────────────────────────────────

  Future<bool> _setBaud(int baud, {bool noResync = false}) async {
    // Skip if we're already at the target baud rate.
    if (baud == _currentBaud) {
      addLogLine('Already at $baud baud, skipping baud change.');
      return true;
    }
    addLogLine(
        'Changing baud to $baud${!noResync ? ", will resync..." : ""}');

    if (kIsWeb) {
      // ── Web path ─────────────────────────────────────────────────────
      // Web Serial API can't change baud in-place; it must close/reopen
      // the port. We handle the full sequence here:
      // 1) Send baud change command at the CURRENT baud
      // 2) Wait for chip to process + respond (response at current baud)
      // 3) Close/reopen port at the NEW baud
      // 4) Re-subscribe to stream
      // 5) Sync at the new baud
      final msg = Uint8List(4);
      msg[0] = baud & 0xFF;
      msg[1] = (baud >> 8) & 0xFF;
      msg[2] = (baud >> 16) & 0xFF;
      msg[3] = (baud >> 24) & 0xFF;

      // Send the command at the current baud (don't trigger baud switch
      // inside _executeCommand — it's gated by !kIsWeb).
      await _executeCommand(0x31,
          parms: msg, timeout: 1, expectedReplyLen: 1, br: baud,
          isErrorExpected: true);

      // Wait for the chip to fully process the command and switch bauds.
      // The chip ACKs then switches — give it generous time.
      await Future.delayed(const Duration(milliseconds: 5));

      // Now close port and reopen at the new baud rate.
      await transport.setBaudRate(baud);
      await transport.setDTR(false);
      await transport.setRTS(false);
      _currentBaud = baud;

      // Re-subscribe to the stream after port reopen.
      _rxSub?.cancel();
      _rxBuffer.clear();
      _rxSub = transport.stream.listen((data) {
        _rxBuffer.addAll(data);
      });

      return noResync || await _sync();
    }

    // ── Native path ──────────────────────────────────────────────────
    // Win32 setBaudRate closes/reopens the port, which restarts the
    // transport's read loop.  We must re-subscribe to the stream and
    // clear stale data, just like the web path does.
    final msg = Uint8List(4);
    msg[0] = baud & 0xFF;
    msg[1] = (baud >> 8) & 0xFF;
    msg[2] = (baud >> 16) & 0xFF;
    msg[3] = (baud >> 24) & 0xFF;
    await _executeCommand(0x31,
        parms: msg, timeout: 1, expectedReplyLen: 1, br: baud,
        isErrorExpected: true);

    // Re-subscribe to the stream after port close/reopen cycle.
    _rxSub?.cancel();
    _rxBuffer.clear();
    _rxSub = transport.stream.listen((data) {
      _rxBuffer.addAll(data);
    });
    _currentBaud = baud;

    return noResync || await _sync();
  }

  // ────────────────────────────────────────────────────────────────────────
  //  Flash read
  // ────────────────────────────────────────────────────────────────────────

  /// Read flash data in 4 KB blocks with CRC-32 verification.
  Future<bool> _readFlash(BytesBuilder dest, int offset, int size) async {
    const readLength = 4096;
    final count = (size + readLength - 1) ~/ readLength;
    int crcErrCount = 0;
    int respErrCount = 0;

    setProgress(0, count);
    setState('Reading...');

    for (int i = 0; i < count; i++) {
      if (isCancelled) return false;


      final header = Uint8List(8);
      header[0] = offset & 0xFF;
      header[1] = (offset >> 8) & 0xFF;
      header[2] = (offset >> 16) & 0xFF;
      header[3] = (offset >> 24) & 0xFF;
      header[4] = readLength & 0xFF;
      header[5] = (readLength >> 8) & 0xFF;
      header[6] = (readLength >> 16) & 0xFF;
      header[7] = (readLength >> 24) & 0xFF;

      final response = await _executeCommand(0x4a,
          parms: header,
          timeout: 2,
          expectedReplyLen: readLength + 4,
          isErrorExpected: true);

      if (response == null) {
        addWarningLine('Failed to get response! Retrying...');
        if (++respErrCount > 10) {
          addErrorLine('Response error count exceeded limit, stopping!');
          return false;
        }
        i--;
        continue;
      } else {
        respErrCount = 0;
      }

      // CRC-32 check (last 4 bytes of response)
      final dataPart = Uint8List.sublistView(response, 0, response.length - 4);
      final crc32 = CRC.crc32(0xFFFFFFFF, dataPart);
      final recvCrc32 = response[response.length - 4] |
          (response[response.length - 3] << 8) |
          (response[response.length - 2] << 16) |
          (response[response.length - 1] << 24);
      if (crc32 != recvCrc32) {
        addWarningLine('CRC Error! Retrying...');
        if (++crcErrCount > 10) {
          addErrorLine('CRC error count exceeded limit, stopping!');
          return false;
        }
        i--;
        continue;
      } else {
        crcErrCount = 0;
      }

      dest.add(dataPart);
      offset += readLength;
      setProgress(i + 1, count);
    }

    setProgress(count, count);
    addLog('All blocks read!\n');
    return true;
  }

  Future<Uint8List?> _readInternalAsync(int startSector, int sectors) async {
    final builder = BytesBuilder(copy: false);
    if (!await _readFlash(builder, startSector, sectors * _sectorSize)) {
      setState('Reading error!');
      await _setBaud(115200);
      return null;
    }
    final result = builder.toBytes();
    addLog('Read done for ${result.length} bytes!\n');
    return result;
  }

  // ────────────────────────────────────────────────────────────────────────
  //  Pseudo-FLS generation
  // ────────────────────────────────────────────────────────────────────────

  Uint8List _generateW800PseudoFLS(Uint8List data, int startAddr) {
    final crc = CRC.crc32(0xFFFFFFFF, data);
    final fls = BytesBuilder(copy: false);
    final header = Uint8List(48);
    header[0] = 0x9F; header[1] = 0xFF; header[2] = 0xFF; header[3] = 0xA0;
    header[4] = 0x00; header[5] = 0x02; header[6] = 0x00; header[7] = 0x00;
    header[8]  = startAddr & 0xFF;
    header[9]  = (startAddr >> 8) & 0xFF;
    header[10] = (startAddr >> 16) & 0xFF;
    header[11] = (startAddr >> 24) & 0xFF;
    header[12] = data.length & 0xFF;
    header[13] = (data.length >> 8) & 0xFF;
    header[14] = (data.length >> 16) & 0xFF;
    header[15] = (data.length >> 24) & 0xFF;
    // 16..19 = 0 (already zero)
    // 20..23 = 0 (already zero)
    header[24] = crc & 0xFF;
    header[25] = (crc >> 8) & 0xFF;
    header[26] = (crc >> 16) & 0xFF;
    header[27] = (crc >> 24) & 0xFF;
    // 28..31 = 0
    header[32] = 0x31; // 33..35 = 0
    // 36..47 = 0

    final hdrCrc = CRC.crc32(0xFFFFFFFF, header);
    final hdrCrcBytes = Uint8List(4);
    hdrCrcBytes[0] = hdrCrc & 0xFF;
    hdrCrcBytes[1] = (hdrCrc >> 8) & 0xFF;
    hdrCrcBytes[2] = (hdrCrc >> 16) & 0xFF;
    hdrCrcBytes[3] = (hdrCrc >> 24) & 0xFF;

    fls.add(header);
    fls.add(hdrCrcBytes);
    fls.add(data);
    return fls.toBytes();
  }

  Uint8List _generateW600PseudoFLS(Uint8List data, int startAddr) {
    final crc = CRC.crc32(0xFFFFFFFF, data);
    final header = Uint8List(44);
    header[0] = 0x9F; header[1] = 0xFF; header[2] = 0xFF; header[3] = 0xA0;
    header[4] = 0x00; header[5] = 0x02; header[6] = 0x00; header[7] = 0x00;
    header[8]  = startAddr & 0xFF;
    header[9]  = (startAddr >> 8) & 0xFF;
    header[10] = (startAddr >> 16) & 0xFF;
    header[11] = (startAddr >> 24) & 0xFF;
    header[12] = data.length & 0xFF;
    header[13] = (data.length >> 8) & 0xFF;
    header[14] = (data.length >> 16) & 0xFF;
    header[15] = (data.length >> 24) & 0xFF;
    header[16] = crc & 0xFF;
    header[17] = (crc >> 8) & 0xFF;
    header[18] = (crc >> 16) & 0xFF;
    header[19] = (crc >> 24) & 0xFF;
    // 20..27 = 0
    // 28..31 = 0
    header[32] = 0x31; // 33..35 = 0
    // 36..43 = 0

    final hdrCrc = CRC.crc32(0xFFFFFFFF, header);
    final hdrCrcBytes = Uint8List(4);
    hdrCrcBytes[0] = hdrCrc & 0xFF;
    hdrCrcBytes[1] = (hdrCrc >> 8) & 0xFF;
    hdrCrcBytes[2] = (hdrCrc >> 16) & 0xFF;
    hdrCrcBytes[3] = (hdrCrc >> 24) & 0xFF;

    final fls = BytesBuilder(copy: false);
    fls.add(header);
    fls.add(hdrCrcBytes);
    fls.add(data);
    return fls.toBytes();
  }

  // ────────────────────────────────────────────────────────────────────────
  //  Public API — overrides
  // ────────────────────────────────────────────────────────────────────────

  @override
  Future<void> doRead(
      {int startSector = 0, int sectors = 10, bool fullRead = false}) async {
    if (chipType == BKType.w600) {
      addErrorLine(
          "W600 doesn't support read. Use JLink for firmware backup.");
      return;
    }
    if (!await _doGenericSetup()) return;

    if (await _sync() && await _readFlashId() != null && await _uploadStub()) {
      try {
        await _setBaud(baudrate);
        if (fullRead) {
          sectors = _flashSizeMB * 0x100000 ~/ _sectorSize;
        }
        _readResult =
            await _readInternalAsync(startSector | 0x08000000, sectors);
      } catch (ex) {
        addErrorLine(ex.toString());
      } finally {
        if (!isCancelled) await _setBaud(115200, noResync: true);
      }
    }
  }

  @override
  Future<void> doWrite(int startSector, Uint8List data) async {
    // Detect FLS format from file name (set by caller) or from header magic.
    String? fName = sourceFileName;
    if (fName == null || fName.isEmpty) {
      // Auto-detect: real .fls files start with the 0x9F 0xFF 0xFF 0xA0 magic
      // right at byte 0 (in contrast, raw backups have it at 0x2000).
      if (data.length >= 4 &&
          data[0] == 0x9F && data[1] == 0xFF &&
          data[2] == 0xFF && data[3] == 0xA0) {
        fName = 'firmware.fls';
      } else {
        fName = 'firmware.bin';
      }
    }
    await doReadAndWrite(startSector, 0, data, fName, WriteMode.onlyWrite);
  }

  @override
  Future<bool> doErase(
      {int startSector = 0, int sectors = 10, bool eraseAll = false}) async {
    // Erase is not implemented in the C# original (commented out)
    return false;
  }

  @override
  Uint8List? getReadResult() => _readResult;

  @override
  Future<void> closePort() async {
    await _rxSub?.cancel();
    _rxSub = null;
    await transport.disconnect();
  }

  @override
  void dispose() {
    _rxSub?.cancel();
    _rxSub = null;
  }

  // ────────────────────────────────────────────────────────────────────────
  //  Combined read + write (main entry point for flashing)
  // ────────────────────────────────────────────────────────────────────────

  /// Combined read-and-write operation, ported from C# `doReadAndWrite`.
  Future<void> doReadAndWrite(
    int startSector,
    int sectors,
    Uint8List? fileData,
    String? sourceFileName,
    WriteMode rwMode,
  ) async {
    if (chipType == BKType.w600) {
      if (rwMode == WriteMode.readAndWrite) {
        addErrorLine(
            "W600 doesn't support read. Use JLink for firmware backup.");
        return;
      }
    }

    if (!await _doGenericSetup()) return;

    if (!(await _sync() &&
        await _readFlashId() != null &&
        await _uploadStub())) {
      return;
    }

    try {
      // Wire up XMODEM progress
      _xm.onPacketSent = (sent, total, blk, ofs) {
        setProgress(sent, total);
      };

      await _setBaud(baudrate);

      // ── Read phase ────────────────────────────────────────────────
      if (rwMode == WriteMode.readAndWrite) {
        sectors = _flashSizeMB * 0x100000 ~/ _sectorSize;
        addLogLine('Flash size detected: ${sectors ~/ 256}MB');
        _readResult =
            await _readInternalAsync(startSector | 0x08000000, sectors);
        if (_readResult == null) return;
      }

      // ── Write phase ───────────────────────────────────────────────
      if (rwMode == WriteMode.onlyWrite ||
          (rwMode == WriteMode.readAndWrite && !isCancelled)) {
        final data = fileData;
        if (data == null || data.isEmpty) {
          addLogLine('No data to write!');
          return;
        }

        addLogLine('Starting flash write ${data.length}');
        setState('Writing');

        if (sourceFileName != null && sourceFileName.endsWith('.fls')) {
          // Direct FLS passthrough
          final sent = await _xm.send(data);
          if (sent == data.length) {
            setState('Writing done');
            addLogLine('Done flash write ${data.length}');
          } else {
            setState('Write error!');
            addErrorLine('Write error!');
          }
        } else if (data.length >= 0x100000) {
          // Raw binary — extract from 0x2000, wrap in pseudo-FLS
          int rawStart = 0x2000;
          // Validate sec boot header
          if (data[rawStart] != 0x9F ||
              data[rawStart + 1] != 0xFF ||
              data[rawStart + 2] != 0xFF ||
              data[rawStart + 3] != 0xA0) {
            addErrorLine(
                'Unknown file type, no firmware header at 0x2000!');
            return;
          }
          final cutData =
              Uint8List.sublistView(data, rawStart, data.length - 1);
          int addr = rawStart | 0x08000000;

          Uint8List fls;
          if (chipType == BKType.w600) {
            // Check W600 specific header bytes
            if (data[rawStart + 60] != 0xFF ||
                data[rawStart + 61] != 0xFF ||
                data[rawStart + 62] != 0xFF ||
                data[rawStart + 63] != 0xFF) {
              addErrorLine('Not W600 backup!');
              return;
            }
            fls = _generateW600PseudoFLS(cutData, addr);
          } else {
            fls = _generateW800PseudoFLS(cutData, addr);
          }

          final sent = await _xm.send(fls);
          if (sent == fls.length) {
            setState('Writing done');
            addLogLine('Done flash write ${data.length}');
            setProgress(1, 1);
          } else {
            setState('Write error!');
          }
        } else {
          addErrorLine('Unknown file type, skipping.');
        }
      }
    } catch (ex) {
      addErrorLine(ex.toString());
    } finally {
      _xm.onPacketSent = null;
      if (!isCancelled) await _setBaud(115200, noResync: true);
    }
  }
}
