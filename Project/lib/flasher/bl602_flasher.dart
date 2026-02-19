/// BL602/BL702/BL616 flasher implementation, ported from C# `BL602Flasher.cs`.
///
/// Full port: sync, getInfo, readFlashID, doGenericSetup, eflash loader,
/// readFlash, writeFlash, doErase, CheckSHA256, doRead, doWrite,
/// doReadAndWrite, saveReadResult.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'base_flasher.dart';
import 'bl602_flash_list.dart';
import 'bl602_utils.dart';

// ─── BLInfo (inner class from C#) ──────────────────────────────────────────

/// Parsed boot-ROM information.
///
/// The bootrom version encodes the chip variant:
///   - `0x702xxxx` → BL702  (also 704, 706)
///   - `0x616xxxx` → BL616  (also 618)
///   - everything else → BL602
class BLInfo {
  final int bootromVersion;
  final Uint8List remaining;
  final BKType variant;

  BLInfo._({
    required this.bootromVersion,
    required this.remaining,
    required this.variant,
  });

  factory BLInfo.fromResponse(Uint8List res) {
    final bootromVersion =
        res[2] | (res[3] << 8) | (res[4] << 16) | (res[5] << 24);
    final remaining = Uint8List.fromList(res.sublist(6));

    // Detect variant from bootrom version (same logic as C#)
    final bootrom = bootromVersion.toRadixString(16).toUpperCase();
    BKType variant;
    if (bootrom.startsWith('702') ||
        bootrom.startsWith('704') ||
        bootrom.startsWith('706')) {
      variant = BKType.bl702;
    } else if (bootrom.startsWith('616') || bootrom.startsWith('618')) {
      variant = BKType.bl616;
    } else {
      variant = BKType.bl602;
    }

    return BLInfo._(
      bootromVersion: bootromVersion,
      remaining: remaining,
      variant: variant,
    );
  }

  @override
  String toString() {
    final sb = StringBuffer();
    sb.writeln(
        'BootROM version: $bootromVersion (${bootromVersion.toRadixString(16).toUpperCase()})');
    sb.writeln('OTP flags:');
    for (int y = 0; y < 4; y++) {
      for (int x = 0; x < 4; x++) {
        final index = x + y * 4;
        if (index < remaining.length) {
          sb.write(remaining[index].toRadixString(2).padLeft(8, '0'));
          sb.write(' ');
        }
      }
      sb.writeln();
    }
    sb.writeln('Chip type: ${variant.displayName}');
    return sb.toString();
  }
}

// ─── BL602 Flasher ─────────────────────────────────────────────────────────

class BL602Flasher extends BaseFlasher {
  // ── Serial RX buffer (same pattern as BK7231Flasher) ──────────────────
  final List<int> _rxBuffer = [];
  StreamSubscription<Uint8List>? _rxSub;

  // ── Flash state ───────────────────────────────────────────────────────
  double _flashSizeMB = 2;
  Uint8List? _flashID;
  BLInfo? _blinfo;
  Uint8List? _readResult;

  BL602Flasher({
    required super.transport,
    super.chipType = BKType.bl602,
    super.baudrate,
  });

  // ── Serial port management ────────────────────────────────────────────

  Future<bool> _openPort() async {
    try {
      final ok = await transport.connect();
      if (!ok) {
        addError('Serial port open failed!\n');
        return false;
      }
      _rxBuffer.clear();
      _rxSub?.cancel();
      _rxSub = transport.stream.listen((data) {
        _rxBuffer.addAll(data);
      });
      return true;
    } catch (e) {
      addError('Serial port exception: $e\n');
      return false;
    }
  }

  void _consumePending() {
    _rxBuffer.clear();
  }

  /// Wait for [count] bytes to appear in [_rxBuffer] within [timeoutMs].
  Future<bool> _waitForBytes(int count, int timeoutMs) async {
    final deadline =
        DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (DateTime.now().isBefore(deadline)) {
      if (_rxBuffer.length >= count) return true;
      await Future.delayed(const Duration(milliseconds: 1));
    }
    return _rxBuffer.length >= count;
  }

  /// Drain all currently available bytes from the RX buffer.
  Uint8List _readFully() {
    final r = Uint8List.fromList(_rxBuffer);
    _rxBuffer.clear();
    return r;
  }

  // ── Sync ──────────────────────────────────────────────────────────────

  /// Try to sync once: send 16× 'U' (0x55), wait for "OK" response.
  Future<bool> _internalSync() async {
    _consumePending();

    // Write initialization sequence
    final syncRequest = Uint8List(16);
    for (int i = 0; i < syncRequest.length; i++) {
      syncRequest[i] = 0x55; // 'U'
    }
    transport.write(syncRequest);

    // Wait up to ~75ms for 2-byte response
    for (int i = 0; i < 75; i++) {
      await Future.delayed(const Duration(milliseconds: 1));

      if (_rxBuffer.length >= 2) {
        final r0 = _rxBuffer[0];
        final r1 = _rxBuffer[1];
        _rxBuffer.removeRange(0, 2);
        // Accept "OK" or "KO" (byte order may vary)
        if ((r0 == 0x4F && r1 == 0x4B) || (r0 == 0x4B && r1 == 0x4F)) {
          return true;
        }
      }
    }
    return false;
  }

  /// Toggle DTR/RTS to auto-reset into boot mode.
  Future<void> _dtrReset() async {
    addLogLine('Attempting DTR/RTS auto-reset into boot mode...');    
    await transport.setRTS(true);
    await Future.delayed(const Duration(milliseconds: 100));
    await transport.setDTR(true);
    await Future.delayed(const Duration(milliseconds: 100));
    await transport.setDTR(false);
    await Future.delayed(const Duration(milliseconds: 100));
    await transport.setRTS(true);
    await Future.delayed(const Duration(milliseconds: 500));
  }

  /// Sync with the chip, retrying up to 1000 times.
  Future<bool> sync() async {
    await _dtrReset();
    for (int i = 0; i < 1000; i++) {
      try {
        if (isCancelled) return false;

        addLog('Sync attempt $i/1000 ');
        if (await _internalSync()) {
          addLog('... OK!\n');
          return true;
        }
        addWarningLine('... failed, will retry!');
        if (i % 10 == 1) {
          await _dtrReset();
          addLogLine(
              'If doing something immediately after another operation, it might not sync for about half a minute');
          addLogLine(
              'Otherwise, please pull high BOOT/${chipType == BKType.bl602 ? "IO8" : "IO28"} and reset.');
        }
        await Future.delayed(const Duration(milliseconds: 50));
      } catch (ex) {
        addLogLine('');
        addErrorLine(ex.toString());
        return false;
      }
    }
    return false;
  }

  // ── Command execution ─────────────────────────────────────────────────

  /// Execute a BL602 boot-ROM command.
  Future<Uint8List?> _executeCommand(
    int type, {
    Uint8List? parms,
    int start = 0,
    int len = 0,
    bool bChecksum = false,
    double timeout = 0.1,
    int expectedReplyLen = 2,
  }) async {
    if (len < 0 && parms != null) {
      len = parms.length;
    }

    // Build checksum
    int chksum = 1;
    if (bChecksum) {
      chksum = 0;
      chksum += (len & 0xFF);
      chksum += (len >> 8);
      for (int i = 0; i < len; i++) {
        chksum += parms![start + i];
      }
      chksum = chksum & 0xFF;
    }

    // Build 4-byte header
    final raw = Uint8List.fromList([
      type & 0xFF,
      chksum & 0xFF,
      len & 0xFF,
      (len >> 8) & 0xFF,
    ]);

    _consumePending();
    transport.write(raw);
    if (parms != null && len > 0) {
      transport.write(Uint8List.fromList(parms.sublist(start, start + len)));
    }

    // Wait for response
    final timeoutMs = (timeout * 1000).toInt();
    await _waitForBytes(expectedReplyLen, timeoutMs);

    if (_rxBuffer.length >= 2) {
      final rep0 = _rxBuffer[0];
      final rep1 = _rxBuffer[1];
      _rxBuffer.removeRange(0, 2);

      // "OK" or "KO"
      if ((rep0 == 0x4F && rep1 == 0x4B) || (rep0 == 0x4B && rep1 == 0x4F)) {
        return _readFully();
      }
      // "FL" — command fail
      else if (rep0 == 0x46 && rep1 == 0x4C) {
        addLogLine('Command fail!');
        _readFully(); // discard
        return null;
      }
      // "PD"/"DP" — pending
      else if ((rep0 == 0x50 && rep1 == 0x44) ||
          (rep0 == 0x44 && rep1 == 0x50)) {
        int errcount = 500;
        while (errcount-- > 0) {
          try {
            await _waitForBytes(2, 20);
            if (_rxBuffer.length >= 2) {
              final r0 = _rxBuffer[0];
              final r1 = _rxBuffer[1];
              _rxBuffer.removeRange(0, 2);
              if ((r0 == 0x4F && r1 == 0x4B) ||
                  (r0 == 0x4B && r1 == 0x4F)) {
                return _readFully();
              } else if ((r0 == 0x50 && r1 == 0x44) ||
                  (r0 == 0x44 && r1 == 0x50)) {
                addLogLine('Command pending...');
              }
            }
          } catch (_) {}
          await Future.delayed(const Duration(milliseconds: 20));
        }
        return _readFully();
      }
    }

    if (expectedReplyLen != 0) addLogLine('Command timed out!');
    return null;
  }

  /// Execute command with chunked data (max 4092 bytes per chunk).
  Future<void> _executeCommandChunked(int type,
      {Uint8List? parms, int start = 0, int len = 0}) async {
    if (len == -1 && parms != null) {
      len = parms.length - start;
    }
    int ofs = 0;
    while (ofs < len) {
      int chunk = len - ofs;
      if (chunk > 4092) chunk = 4092;
      await _executeCommand(type, parms: parms, start: start + ofs, len: chunk);
      ofs += chunk;
    }
  }

  // ── Info / Flash ID ───────────────────────────────────────────────────

  /// Get boot-ROM info (command 0x10).
  Future<BLInfo?> _getInfo() async {
    final res = await _executeCommand(0x10);
    if (res == null) return null;

    final totalLen = res[0] + (res[1] << 8);
    if (totalLen + 2 != res.length) return null;

    return BLInfo.fromResponse(res);
  }

  /// Get and log boot-ROM info.
  Future<BLInfo?> _getAndPrintInfo() async {
    _blinfo = await _getInfo();
    if (_blinfo == null) return null;
    addLogLine(_blinfo.toString());
    return _blinfo;
  }

  /// Read flash JEDEC ID (command 0x36).
  Future<Uint8List?> _readFlashID() async {
    final res = await _executeCommand(0x36,
        bChecksum: true, timeout: 0.1, expectedReplyLen: 6);
    if (res == null) return null;

    if (res.length >= 6) {
      final sizeCode = res[4] - 0x11;
      _flashSizeMB = (1 << sizeCode) / 8.0;
      if (_flashSizeMB > 32) return null;

      addLogLine(
          'Flash ID: ${res[2].toRadixString(16).padLeft(2, '0').toUpperCase()}'
          '${res[3].toRadixString(16).padLeft(2, '0').toUpperCase()}'
          '${res[4].toRadixString(16).padLeft(2, '0').toUpperCase()}'
          '${res[5].toRadixString(16).padLeft(2, '0').toUpperCase()}');
      addLogLine('Flash size is ${_flashSizeMB}MB');
    } else {
      addLogLine('Invalid response length: ${res.length}');
    }
    return res;
  }

  // ── Eflash loader ────────────────────────────────────────────────────

  /// Load a GZ-compressed binary from Flutter assets.
  Future<Uint8List> _loadAssetBinary(String assetName) async {
    final data = await rootBundle.load('assets/floaders/$assetName');
    final compressed = data.buffer.asUint8List();
    // Decompress gzip
    return Uint8List.fromList(gzip.decode(compressed));
  }

  /// Load and run the eflash loader (preprocessed boot image).
  Future<bool> _loadAndRunPreprocessedImage() async {
    if (_blinfo?.variant == BKType.bl616) return true;

    final String assetName;
    switch (chipType) {
      case BKType.bl702:
        assetName = 'BL702Floader.bin';
        break;
      default:
        assetName = 'BL602Floader.bin';
        break;
    }

    final file = await _loadAssetBinary(assetName);
    return _loadAndRunPreprocessedImageData(file);
  }

  Future<bool> _loadAndRunPreprocessedImageData(Uint8List file) async {
    addLogLine('Sending boot header...');
    await _executeCommand(0x11, parms: file, start: 0, len: 176);

    addLogLine('Sending segment header...');
    await _executeCommand(0x17, parms: file, start: 176, len: 16);

    addLogLine('Writing application to RAM...');
    await _executeCommandChunked(0x18, parms: file, start: 176 + 16, len: -1);

    addLogLine('Checking...');
    await _executeCommand(0x19);

    addLogLine('Jumping...');
    await _executeCommand(0x1a);

    return false;
  }

  // ── doGenericSetup ────────────────────────────────────────────────────

  /// Full connection setup: open port → sync → getInfo → eflash loader → readFlashID.
  Future<bool> _doGenericSetup() async {
    final now = DateTime.now();
    addLog(
        'Now is: ${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.\n');
    addLog('Flasher mode: ${chipType.displayName}\n');
    addLog('Going to open port.\n');

    if (!await _openPort()) {
      return false;
    }
    addLog('Port ready!\n');

    if (!await sync()) {
      return false;
    }

    if (await _getAndPrintInfo() == null) {
      // getInfo failed — maybe eflash loader is already running
      _flashID = await _readFlashID();
      if (_flashID != null) {
        addLogLine('Eflash loader is already uploaded!');
        return true;
      }
      addErrorLine('Initial get info failed.');
      addErrorLine(
          'This may happen if you don\'t reset between flash operations');
      addErrorLine(
          'So, make sure that BOOT is connected, do reset (or power off/on) and try again');
      return false;
    }

    // BL616 special handling: no eflash loader needed
    if (_blinfo!.variant == BKType.bl616) {
      await _executeCommand(0x3B,
          parms: Uint8List.fromList([0x80, 0x41, 0x01, 0x00]),
          start: 0,
          len: 4,
          bChecksum: true,
          timeout: 2,
          expectedReplyLen: 0);
      // do it twice for bl616
      _flashID = await _readFlashID();
      _flashID = await _readFlashID();
      if (_flashID == null) {
        addErrorLine('Failed to get BL616 flash id!');
        return false;
      }
      return true;
    } else if (_blinfo!.variant != chipType) {
      addErrorLine(
          'Selected chip type is ${chipType.displayName}, but current chip type is ${_blinfo!.variant.displayName}! Will continue anyway...');
    }

    await _loadAndRunPreprocessedImage();
    await Future.delayed(const Duration(milliseconds: 100));

    // resync in eflash loader
    if (!await sync()) {
      return false;
    }
    _flashID = await _readFlashID();

    return true;
  }

  // ── Flash read ────────────────────────────────────────────────────────

  /// Read flash data in 4096-byte chunks (command 0x32).
  ///
  /// Mirrors C# `readFlash(addr, amount)`.
  Future<Uint8List?> _readFlash({int addr = 0, int amount = 4096}) async {
    try {
      final startAddr = addr;
      final startAmount = amount;
      final ret = Uint8List(amount);
      setProgress(0, startAmount);
      setState('Reading');
      addLogLine('Starting read...');
      int destAddr = 0;
      while (amount > 0) {
        int length = 4096;
        if (amount < length) length = amount;

        final cmdBuffer = Uint8List(8);
        cmdBuffer[0] = addr & 0xFF;
        cmdBuffer[1] = (addr >> 8) & 0xFF;
        cmdBuffer[2] = (addr >> 16) & 0xFF;
        cmdBuffer[3] = (addr >> 24) & 0xFF;
        cmdBuffer[4] = length & 0xFF;
        cmdBuffer[5] = (length >> 8) & 0xFF;
        cmdBuffer[6] = (length >> 16) & 0xFF;
        cmdBuffer[7] = (length >> 24) & 0xFF;

        final rawReplyLen = 2 + 2 + length; // OK + length 2 bytes + data
        final result = await _executeCommand(0x32,
            parms: cmdBuffer,
            start: 0,
            len: cmdBuffer.length,
            bChecksum: true,
            timeout: 5,
            expectedReplyLen: rawReplyLen);

        if (result == null) {
          setState('Read error');
          addErrorLine('Read fail - no reply');
          return null;
        }

        final dataLen = result.length - 2;
        if (dataLen != length) {
          addErrorLine('\nRead fail - size mismatch, will resync and continue');
          if (!await sync()) return null;
          continue;
        }
        ret.setRange(destAddr, destAddr + dataLen, result, 2);
        if (isCancelled) return null;
        addr += dataLen;
        amount -= dataLen;
        destAddr += dataLen;
        setProgress(destAddr, startAmount);
      }
      addLogLine('');
      if (!await _checkSHA256(startAddr, startAmount, ret)) {
        setState('SHA mismatch!');
        return null;
      }
      setState('Read done');
      addLogLine('Read complete!');
      return ret;
    } catch (ex) {
      addLogLine('');
      addErrorLine(ex.toString());
      return null;
    }
  }

  // ── SHA256 verification ───────────────────────────────────────────────

  /// Verify SHA256 hash of flash data against local computation.
  ///
  /// Mirrors C# `CheckSHA256(addr, length, data)`.
  Future<bool> _checkSHA256(int addr, int length, Uint8List data) async {
    final sha256cmd = Uint8List(8);
    sha256cmd[0] = addr & 0xFF;
    sha256cmd[1] = (addr >> 8) & 0xFF;
    sha256cmd[2] = (addr >> 16) & 0xFF;
    sha256cmd[3] = (addr >> 24) & 0xFF;
    sha256cmd[4] = length & 0xFF;
    sha256cmd[5] = (length >> 8) & 0xFF;
    sha256cmd[6] = (length >> 16) & 0xFF;
    sha256cmd[7] = (length >> 24) & 0xFF;
    final sha256result = await _executeCommand(0x3D,
        parms: sha256cmd,
        start: 0,
        len: sha256cmd.length,
        bChecksum: true,
        timeout: 10,
        expectedReplyLen: 2 + 32);
    if (sha256result == null) {
      addErrorLine('Failed to get hash');
      return false;
    }
    // Compute local SHA256
    final localHash = sha256.convert(data);
    final sha256read = hashToStr(Uint8List.fromList(localHash.bytes));
    final sha256flash = hashToStr(Uint8List.fromList(sha256result.sublist(2)));
    if (sha256flash != sha256read) {
      addErrorLine('Hash mismatch!\nexpected\t$sha256read\ngot\t$sha256flash');
      return false;
    } else {
      addSuccess('Hash matches $sha256read!\n');
      return true;
    }
  }

  // ── Flash write ───────────────────────────────────────────────────────

  /// Write data to flash with erase and SHA256 verification.
  ///
  /// Mirrors C# `writeFlash(data, adr, len)`.
  Future<bool> _writeFlash(Uint8List data, int adr, {int len = -1}) async {
    try {
      const bufLen = 4096;
      if (len < 0) len = data.length;
      int ofs = 0;
      final startAddr = adr;
      setProgress(0, len);
      await doErase(startSector: adr, sectors: (len + 4095) ~/ 4096);
      addLogLine('Starting flash write $len');
      final buffer = Uint8List(bufLen + 4);
      setState('Writing');
      await Future.delayed(const Duration(milliseconds: 1000));
      while (ofs < len) {
        if (isCancelled) return false;
        if (ofs % 0x1000 == 0) addLog('.${formatHex(ofs)}.');
        int chunk = len - ofs;
        if (chunk > bufLen) chunk = bufLen;
        buffer[0] = adr & 0xFF;
        buffer[1] = (adr >> 8) & 0xFF;
        buffer[2] = (adr >> 16) & 0xFF;
        buffer[3] = (adr >> 24) & 0xFF;
        buffer.setRange(4, 4 + chunk, data, ofs);
        final bufferLen = chunk + 4;
        int errCnt = 0;
        while (await _executeCommand(0x31,
                parms: buffer,
                start: 0,
                len: bufferLen,
                bChecksum: true,
                timeout: 5) ==
            null && errCnt < 10) {
          errCnt++;
        }
        if (errCnt >= 10) {
          throw Exception('Write failed!');
        }
        ofs += chunk;
        adr += chunk;
        setProgress(ofs, len);
      }
      addLogLine('');
      if (!await _checkSHA256(startAddr, len, data)) {
        setState('SHA mismatch!');
        return false;
      }
      setState('Writing done');
      addLogLine('Done flash write $len');
      return true;
    } catch (exc) {
      addErrorLine(exc.toString());
      return false;
    }
  }

  // ── Erase ─────────────────────────────────────────────────────────────

  /// Erase flash sectors.
  ///
  /// If [eraseAll] is true, performs full chip erase (command 0x3C).
  /// Otherwise erases a sector range (command 0x30).
  @override
  Future<bool> doErase({int startSector = 0, int sectors = 10, bool eraseAll = false}) async {
    setState('Erasing...');
    if (eraseAll) {
      if (!await _doGenericSetup()) {
        return false;
      }
      addLogLine('Erasing...');
      final res = await _executeCommand(0x3C,
          bChecksum: true, timeout: 30);
      if (res != null) {
        setState('Erase done');
      } else {
        setState('Erase failed!');
        return false;
      }
    } else {
      if (sectors < 1) return false;
      final end = sectors * sectorSize + startSector - 1;
      addLogLine(
          'Erasing from 0x${startSector.toRadixString(16).toUpperCase()} to 0x${(end + 1).toRadixString(16).toUpperCase()}');
      final cmdBuffer = Uint8List(8);
      cmdBuffer[0] = startSector & 0xFF;
      cmdBuffer[1] = (startSector >> 8) & 0xFF;
      cmdBuffer[2] = (startSector >> 16) & 0xFF;
      cmdBuffer[3] = (startSector >> 24) & 0xFF;
      cmdBuffer[4] = end & 0xFF;
      cmdBuffer[5] = (end >> 8) & 0xFF;
      cmdBuffer[6] = (end >> 16) & 0xFF;
      cmdBuffer[7] = (end >> 24) & 0xFF;
      final res = await _executeCommand(0x30,
          parms: cmdBuffer,
          start: 0,
          len: cmdBuffer.length,
          bChecksum: true,
          timeout: 30);
      if (res != null) {
        setState('Erase done');
      } else {
        setState('Erase failed!');
        return false;
      }
    }
    _consumePending();
    return true;
  }

  // ── doReadInternal ────────────────────────────────────────────────────

  /// Read flash and store result internally.
  Future<bool> _doReadInternal({int addr = 0, int amount = 0x200000}) async {
    final res = await _readFlash(addr: addr, amount: amount);
    if (res != null) {
      _readResult = res;
    }
    return false;
  }

  // ── Public overrides ──────────────────────────────────────────────────

  @override
  Future<void> doRead(
      {int startSector = 0, int sectors = 10, bool fullRead = false}) async {
    try {
      if (!await _doGenericSetup()) return;
      if (fullRead) sectors = (_flashSizeMB * 256).toInt();
      await _doReadInternal(
          addr: startSector, amount: sectors * sectorSize);
    } catch (ex) {
      addErrorLine(ex.toString());
    }
  }

  @override
  Future<void> doWrite(int startSector, Uint8List data) async {
    try {
      if (!await _doGenericSetup()) return;
      await _writeFlash(data, startSector);
    } catch (ex) {
      addErrorLine(ex.toString());
    }
  }

  /// Combined read-and-write operation.
  ///
  /// Mirrors C# `doReadAndWrite(startSector, sectors, sourceFileName, rwMode)`.
  Future<void> doReadAndWrite(
      int startSector, int sectors, String sourceFileName, WriteMode rwMode) async {
    try {
      if (!await _doGenericSetup()) return;

      if (rwMode == WriteMode.readAndWrite) {
        sectors = (_flashSizeMB * 256).toInt();
        await _doReadInternal(
            addr: startSector, amount: sectors * sectorSize);
        if (_readResult == null) return;
        if (!await _saveReadResult(startSector)) return;
      }

      if (rwMode == WriteMode.onlyWrite || rwMode == WriteMode.readAndWrite) {
        if (sourceFileName.isEmpty) {
          addLogLine('No filename given!');
          return;
        }
        addLogLine('Reading $sourceFileName...');
        final data = Uint8List.fromList(await File(sourceFileName).readAsBytes());

        List<PartitionEntry> partitions;
        switch (_flashSizeMB) {
          case 0.5:
            if (chipType == BKType.bl602) {
              throw Exception('Flash is too small!');
            }
            partitions = partitions512kBL702;
            break;
          case 1:
            partitions = chipType == BKType.bl702
                ? partitions1mbBL702
                : partitions1MB;
            break;
          case 2:
            partitions = chipType == BKType.bl702
                ? partitions2mbBL702
                : partitions2MB;
            break;
          default:
            partitions = List.from(partitions4MB);
            if (chipType == BKType.bl702) {
              partitions.firstWhere((x) => x.name == 'FW').address0 = 0x3000;
            }
            break;
        }

        // Check for BFNP magic (raw flash image)
        if (data.length >= 4 &&
            data[0] == 0x42 && data[1] == 0x46 && data[2] == 0x4E && data[3] == 0x50) {
          await _writeFlash(data, 0);
        } else {
          final fwPartition = partitions.firstWhere((x) => x.name == 'FW');
          if (data.length > fwPartition.length0) {
            throw Exception('The size of the selected file exceeds the length of the partition!');
          }

          final flash = (_flashID![2] << 16) | (_flashID![3] << 8) | _flashID![4];
          FlashConfig flashConfig;
          if (flashDict.containsKey(flash)) {
            flashConfig = flashDict[flash]!;
          } else {
            addErrorLine(
                'There is no flash config for flash with id: 0x${flash.toRadixString(16).toUpperCase()}. Will use for 0xEF4015. This might result in unknown behaviour.');
            flashConfig = flashDict[0xEF4015]!;
          }

          if (chipType != BKType.bl602 && chipType != BKType.bl702) {
            addErrorLine('Firmware write is not supported on ${chipType.displayName}.');
            return;
          }

          var apphdr = createBootHeader(flashConfig, data, chipType);
          var firmwareData = data;
          if (chipType == BKType.bl602) {
            firmwareData = Uint8List.fromList([...data, 0, 0, 0, 0]);
          }
          var wd = padArray(apphdr, sectorSize);

          addLogLine('Writing...');
          if (chipType == BKType.bl702) {
            final bpartitions = ptBuild(partitions);
            final fdata = Uint8List.fromList([...wd, ...bpartitions, ...firmwareData]);
            if (!await _writeFlash(fdata, 0x0)) return;
          } else {
            var boot = await _loadAssetBinary('BL602_Boot.bin');
            var boothdr = createBootHeader(flashConfig, boot, chipType);
            boothdr = padArray(boothdr, sectorSize);
            boot = Uint8List.fromList([...boothdr, ...boot]);
            final bpartitions = ptBuild(partitions);
            boot = padArray(boot, 0xE000);
            boot = Uint8List.fromList([...boot, ...bpartitions]);
            final fdata = Uint8List.fromList([...boot, ...wd, ...firmwareData]);
            if (!await _writeFlash(fdata, 0x0)) return;
          }

          if (chipType == BKType.bl602) {
            addLogLine('Writing dts...');
            final dts = await _loadAssetBinary('BL602_Dts.bin');
            final factoryPartition = partitions.firstWhere((x) => x.name == 'factory');
            if (!await _writeFlash(dts, factoryPartition.address0)) return;
          }
        }
      }
    } catch (ex) {
      addErrorLine(ex.toString());
    }
  }

  // ── Save read result ──────────────────────────────────────────────────

  /// Save the read result to a file in the backups directory.
  Future<bool> _saveReadResult(int startOffset) async {
    if (_readResult == null) {
      addError('There was no result to save.\n');
      return false;
    }
    final now = DateTime.now();
    final dateStr =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    final bkName = backupName != null && backupName!.isNotEmpty ? '_$backupName' : '';
    final fileName = 'readResult_${chipType.displayName}${bkName}_$dateStr.bin';

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final backupsDir = Directory('${appDir.path}/backups');
      if (!backupsDir.existsSync()) {
        backupsDir.createSync(recursive: true);
      }
      final fullPath = '${backupsDir.path}/$fileName';
      await File(fullPath).writeAsBytes(_readResult!);
      addSuccess('Wrote ${_readResult!.length} to $fileName\n');
      return true;
    } catch (ex) {
      addErrorLine(ex.toString());
      return false;
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
    _rxSub = null;
  }
}
