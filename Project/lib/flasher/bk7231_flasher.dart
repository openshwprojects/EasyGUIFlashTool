/// BK7231 flasher implementation, ported from C# `BK7231Flasher.cs`.
///
/// Implements the full HCI-based protocol: bus acquisition via DTR/RTS,
/// baud-rate negotiation, flash chip identification, protect/unprotect,
/// 4 KB sector read/write, block-level erase, and CRC verification.
library;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../serial/serial_transport.dart';
import 'base_flasher.dart';
import 'bk_flash_list.dart';
import 'crc.dart';

// ─── Command codes (from BK7231 HCI protocol) ──────────────────────────────

class _Cmd {
  static const int linkCheck   = 0x00;
  static const int writeReg    = 0x01;
  static const int readReg     = 0x03;
  static const int flashWrite  = 0x06;
  static const int flashWrite4K = 0x07;
  static const int flashRead4K = 0x09;
  static const int flashErase4K = 0x0b;
  static const int flashReadSR = 0x0c;
  static const int flashWriteSR = 0x0d;
  static const int flashGetMID = 0x0e;
  static const int setBaudRate = 0x0f;
  static const int flashErase  = 0x0f;
  static const int checkCRC    = 0x10;
}

/// BK7231 flasher — full protocol port from C#.
class BK7231Flasher extends BaseFlasher {
  static final Random _rand = Random();

  static const int sectorSize = 0x1000;
  static const int blockSize  = 0x10000;
  static const int sectorsPerBlock = blockSize ~/ sectorSize;
  static const int bootloaderSize = 0x11000;

  static const String tuyaEncryptionKey   = '510fb093 a3cbeadc 5993a17e c7adeb03';
  static const String emptyEncryptionKey  = '00000000 00000000 00000000 00000000';

  int _flashSize   = 0x200000;
  int _totalSectors = 0x200000 ~/ sectorSize;

  /// Result of the last read operation.
  Uint8List? _readResult;

  String _lastEncryptionKey = '';
  bool _bDebugUART = false;
  int _deviceMID = 0;
  BKFlash? _flashInfo;

  /// Receive buffer — incoming stream data is accumulated here.
  final _rxBuffer = <int>[];
  StreamSubscription<Uint8List>? _rxSub;

  /// Guards the DTR/RTS warning so it is only shown once per flash operation.
  bool _dtrRtsWarningShown = false;

  BK7231Flasher({
    required super.transport,
    super.chipType = BKType.bk7231n,
    super.baudrate = 921600,
  });

  // ════════════════════════════════════════════════════════════════════════
  //  PUBLIC API  (overrides from BaseFlasher)
  // ════════════════════════════════════════════════════════════════════════

  @override
  Future<void> doRead({int startSector = 0, int sectors = 10, bool fullRead = false}) async {
    try {
      setProgress(0, sectors);
      addLogLine('Starting read!');
      addLogLine('Read parms: start ${formatHex(startSector)} '
          '(sector ${startSector ~/ sectorSize}), '
          'len ${formatHex(sectors * sectorSize)} ($sectors sectors)');
      if (!await _doGenericSetup()) return;
      if (fullRead) sectors = _totalSectors;
      _readResult = await _readChunk(startSector, sectors);
      // reset flash size
      _flashSize = 0x200000;
      _totalSectors = _flashSize ~/ sectorSize;
    } catch (e) {
      addError('Exception caught: $e\n');
    }
  }

  @override
  Future<void> doWrite(int startSector, Uint8List data) async {
    try {
      final sectors = data.length ~/ sectorSize;
      setProgress(0, sectors);
      addLogLine('Starting write!');
      if (!await _doGenericSetup()) return;
      if (!await _eraseRange(startSector, sectors)) return;
      addLogLine('All selected sectors erased!');
      addLogLine('Writing ${formatHex(sectors * sectorSize)} at ${formatHex(startSector)}, see progress bar for updates....');
      for (int sec = 0; sec < sectors; sec++) {
        if (isCancelled) return;
        final secAddr = startSector + sectorSize * sec;
        setState('Writing ${formatHex(secAddr)} out of ${formatHex(startSector + sectors * sectorSize)}...');
        if (!await _writeSector4K(secAddr, data, sectorSize * sec)) {
          setState('Write sector failed!');
          addError(' Writing sector ${formatHex(secAddr)} failed!\n');
          return;
        }
        setProgress(sec + 1, sectors);
        // Yield to let Flutter process progress update and user input
        await Future.delayed(const Duration(milliseconds: 1));
      }
      addLogLine('Write finished, now verifying CRC...');
      if (!await _checkCRC(startSector, sectors, data)) return;
      setState('Write success!');
      addSuccess('Write success!');
    } catch (e) {
      addError('Exception caught: $e\n');
    }
  }

  @override
  Future<bool> doErase({int startSector = 0, int sectors = 10, bool eraseAll = false}) async {
    try {
      setProgress(0, sectors);
      addLog('Erase started with ofs ${formatHex(startSector)} and len in sectors $sectors');
      if (!await _doGenericSetup()) return false;
      if (!await _doEraseInternal(startSector, sectors)) return false;
    } catch (e) {
      addError('Exception caught: $e\n');
    }
    return true;
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
  //  SERIAL I/O  (async replacement for C# blocking serial.Read)
  // ════════════════════════════════════════════════════════════════════════

  Future<bool> _openPort() async {
    try {
      final ok = await transport.connect();
      if (!ok) {
        addError('Serial port open failed!\n');
        return false;
      }
      // Start buffering incoming bytes
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

  /// Send [txbuf], then wait up to [timeout] seconds for [rxLen] bytes.
  Future<Uint8List?> _startCmd(Uint8List? txbuf, {int rxLen = 0, double timeout = 0.05}) async {
    _consumePending();
    if (txbuf != null) {
      transport.write(txbuf);
    }
    if (rxLen <= 0) return null;

    final effectiveTimeout = timeout * cfgReadTimeOutMultForLoop;
    final deadline = DateTime.now().add(Duration(milliseconds: (effectiveTimeout * 1000).toInt()));

    while (DateTime.now().isBefore(deadline)) {
      if (_rxBuffer.length >= rxLen) {
        final ret = Uint8List.fromList(_rxBuffer.sublist(0, rxLen));
        _rxBuffer.removeRange(0, rxLen);
        return ret;
      }
      // Yield a full event-loop turn so Flutter can process UI input
      // (clicks, window drag). Duration.zero only yields a microtask.
      await Future.delayed(const Duration(milliseconds: 1));
    }

    if (_rxBuffer.length >= rxLen) {
      final ret = Uint8List.fromList(_rxBuffer.sublist(0, rxLen));
      _rxBuffer.removeRange(0, rxLen);
      return ret;
    }

    if (rxLen > 10) {
      addLog('failed with rxBuffer ${_rxBuffer.length} (expected $rxLen)\n');
      if (_rxBuffer.isNotEmpty) {
        final preview = _rxBuffer.take(16).map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join();
        addLog('The beginning of buffer contains $preview data.\n');
      }
    }
    return null;
  }

  // ════════════════════════════════════════════════════════════════════════
  //  COMMAND BUILDERS
  // ════════════════════════════════════════════════════════════════════════

  Uint8List _buildCmdLinkCheck() =>
      Uint8List.fromList([0x01, 0xe0, 0xfc, 0x01, _Cmd.linkCheck]);

  Uint8List _buildCmdReadReg(int addr) =>
      Uint8List.fromList([
        0x01, 0xe0, 0xfc, 1 + 4, _Cmd.readReg,
        addr & 0xff, (addr >> 8) & 0xff, (addr >> 16) & 0xff, (addr >> 24) & 0xff,
      ]);

  Uint8List _buildCmdWriteReg(int addr, int val) =>
      Uint8List.fromList([
        0x01, 0xe0, 0xfc, 1 + 4 + 4, _Cmd.writeReg,
        addr & 0xff, (addr >> 8) & 0xff, (addr >> 16) & 0xff, (addr >> 24) & 0xff,
        val & 0xff, (val >> 8) & 0xff, (val >> 16) & 0xff, (val >> 24) & 0xff,
      ]);

  Uint8List _buildCmdEraseSector4K(int addr) {
    final length = 1 + 4;
    return Uint8List.fromList([
      0x01, 0xe0, 0xfc, 0xff, 0xf4, length & 0xff, 0,
      _Cmd.flashErase4K,
      addr & 0xff, (addr >> 8) & 0xff, (addr >> 16) & 0xff, (addr >> 24) & 0xff,
    ]);
  }

  Uint8List _buildCmdFlashErase(int addr, int szcmd) {
    final length = 1 + 4 + 1;
    return Uint8List.fromList([
      0x01, 0xe0, 0xfc, 0xff, 0xf4, length & 0xff, 0,
      _Cmd.flashErase, szcmd & 0xff,
      addr & 0xff, (addr >> 8) & 0xff, (addr >> 16) & 0xff, (addr >> 24) & 0xff,
    ]);
  }

  Uint8List _buildCmdSetBaudRate(int baud, int delayMs) =>
      Uint8List.fromList([
        0x01, 0xe0, 0xfc, 1 + 4 + 1, _Cmd.setBaudRate,
        baud & 0xff, (baud >> 8) & 0xff, (baud >> 16) & 0xff, (baud >> 24) & 0xff,
        delayMs & 0xff,
      ]);

  Uint8List _buildCmdCheckCRC(int startAddr, int endAddr) =>
      Uint8List.fromList([
        0x01, 0xe0, 0xfc, 1 + 4 + 4, _Cmd.checkCRC,
        startAddr & 0xff, (startAddr >> 8) & 0xff, (startAddr >> 16) & 0xff, (startAddr >> 24) & 0xff,
        endAddr & 0xff, (endAddr >> 8) & 0xff, (endAddr >> 16) & 0xff, (endAddr >> 24) & 0xff,
      ]);

  Uint8List _buildCmdFlashGetMID(int addr) {
    final length = 1 + 4;
    return Uint8List.fromList([
      0x01, 0xe0, 0xfc, 0xff, 0xf4, length & 0xff, (length >> 8) & 0xff,
      _Cmd.flashGetMID,
      addr & 0xff, (addr >> 8) & 0xff, (addr >> 16) & 0xff, (addr >> 24) & 0xff,
    ]);
  }

  Uint8List _buildCmdFlashWriteSR(int regAddr, int val) {
    final length = 1 + 1 + 1;
    return Uint8List.fromList([
      0x01, 0xe0, 0xfc, 0xff, 0xf4, length & 0xff, (length >> 8) & 0xff,
      _Cmd.flashWriteSR, regAddr & 0xff, val & 0xff,
    ]);
  }

  Uint8List _buildCmdFlashWriteSR2(int regAddr, int val) {
    final length = 1 + 1 + 2;
    return Uint8List.fromList([
      0x01, 0xe0, 0xfc, 0xff, 0xf4, length & 0xff, (length >> 8) & 0xff,
      _Cmd.flashWriteSR, regAddr & 0xff, val & 0xff, (val >> 8) & 0xff,
    ]);
  }

  Uint8List _buildCmdFlashReadSR(int addr) {
    final length = 1 + 1;
    return Uint8List.fromList([
      0x01, 0xe0, 0xfc, 0xff, 0xf4, length & 0xff, (length >> 8) & 0xff,
      _Cmd.flashReadSR, addr & 0xff,
    ]);
  }

  Uint8List _buildCmdFlashWrite4K(int addr, Uint8List data, int startOfs) {
    final length = 1 + 4 + 4 * 1024;
    final buf = Uint8List(12 + 4 * 1024);
    buf[0] = 0x01; buf[1] = 0xe0; buf[2] = 0xfc;
    buf[3] = 0xff; buf[4] = 0xf4;
    buf[5] = length & 0xff; buf[6] = (length >> 8) & 0xff;
    buf[7] = _Cmd.flashWrite4K;
    buf[8]  = addr & 0xff; buf[9] = (addr >> 8) & 0xff;
    buf[10] = (addr >> 16) & 0xff; buf[11] = (addr >> 24) & 0xff;
    final lenToCopy = min(4096, data.length - startOfs);
    buf.setRange(12, 12 + lenToCopy, data, startOfs);
    return buf;
  }

  Uint8List _buildCmdFlashRead4K(int addr) {
    final length = 1 + 4;
    return Uint8List.fromList([
      0x01, 0xe0, 0xfc, 0xff, 0xf4, length & 0xff, (length >> 8) & 0xff,
      _Cmd.flashRead4K,
      addr & 0xff, (addr >> 8) & 0xff, (addr >> 16) & 0xff, (addr >> 24) & 0xff,
    ]);
  }

  // ════════════════════════════════════════════════════════════════════════
  //  EXPECTED RX LENGTHS
  // ════════════════════════════════════════════════════════════════════════

  static int get _rxLenLinkCheck      => 3 + 3 + 1 + 1;
  static int get _rxLenCheckCRC       => 3 + 3 + 1 + 4;
  static int get _rxLenSetBaudRate    => 3 + 3 + 1 + 4 + 1;
  static int get _rxLenEraseSector4K  => 3 + 3 + 3 + (1 + 1 + 4);
  static int get _rxLenFlashErase     => 3 + 3 + 3 + (1 + 1 + 1 + 4);
  static int get _rxLenFlashWrite4K   => 3 + 3 + 3 + (1 + 1 + 4);
  static int get _rxLenFlashWrite     => 3 + 3 + 3 + (1 + 1 + 4 + 1);
  static int get _rxLenFlashRead4K    => 3 + 3 + 3 + (1 + 1 + 4 + 4 * 1024);
  static int get _rxLenReadFlashReg   => 3 + 3 + 3 + (1 + 1 + 1 + 3);
  static int get _rxLenWriteFlashReg  => 3 + 3 + 3 + (1 + 1 + 1 + 3);
  static int get _rxLenReadFlashSR    => 3 + 3 + 3 + (1 + 1 + 1 + 1);
  static int get _rxLenFlashWriteSR   => 3 + 3 + 3 + (1 + 1 + 1 + 1);
  static int get _rxLenFlashWriteSR2  => 3 + 3 + 3 + (1 + 1 + 1 + 2);
  static int get _rxLenFlashGetID     => 3 + 3 + 3 + (1 + 1 + 4);

  // ════════════════════════════════════════════════════════════════════════
  //  RESPONSE CHECKERS
  // ════════════════════════════════════════════════════════════════════════

  static bool _cmpBytes(Uint8List a, List<int> b, int len) {
    if (a.length < len || b.length < len) return false;
    for (int i = 0; i < len; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  bool _checkRespondLinkCheck(Uint8List buf) {
    final expected = [0x04, 0x0e, 0x05, 0x01, 0xe0, 0xfc, _Cmd.linkCheck + 1, 0x00];
    return buf.length >= expected.length && _cmpBytes(buf, expected, expected.length);
  }

  int _checkRespondCheckCRC(Uint8List buf) {
    final expected = [0x04, 0x0e, 3 + 1 + 4, 0x01, 0xe0, 0xfc, _Cmd.checkCRC];
    if (buf.length >= expected.length && _cmpBytes(buf, expected, expected.length)) {
      return (buf[10] << 24) | (buf[9] << 16) | (buf[8] << 8) | buf[7];
    }
    addLog('CheckRespond_CheckCRC: ERROR\n');
    return 0;
  }

  bool _checkRespondWriteReg(Uint8List buf, int addr, int val) {
    final expected = [0x04, 0x0e, 3 + 1 + 4 + 4, 0x01, 0xe0, 0xfc, _Cmd.writeReg,
      addr & 0xff, (addr >> 8) & 0xff, (addr >> 16) & 0xff, (addr >> 24) & 0xff,
      val & 0xff, (val >> 8) & 0xff, (val >> 16) & 0xff, (val >> 24) & 0xff];
    if (buf.length >= expected.length && _cmpBytes(buf, expected, expected.length)) {
      return true;
    }
    addLog('CheckRespond_WriteReg: ERROR\n');
    return false;
  }

  Uint8List? _checkRespondReadFlashReg(Uint8List buf, int addr) {
    final expected = [0x04, 0x0e, 3 + 1 + 4 + 4, 0x01, 0xe0, 0xfc, _Cmd.readReg,
      addr & 0xff, (addr >> 8) & 0xff, (addr >> 16) & 0xff, (addr >> 24) & 0xff];
    if (buf.length >= expected.length && _cmpBytes(buf, expected, expected.length)) {
      return Uint8List.fromList([buf[11], buf[12], buf[13], buf[14]]);
    }
    addError('CheckRespond_ReadFlashReg: bad value returned?\n');
    return null;
  }

  bool _checkRespondFlashWrite4K(Uint8List buf, int addr) {
    final expected = [0x04, 0x0e, 0xff, 0x01, 0xe0, 0xfc, 0xf4,
      (1 + 1 + 4) & 0xff, 0, _Cmd.flashWrite4K];
    if (buf.length >= expected.length && _cmpBytes(buf, expected, expected.length)) {
      final r = (buf[14] << 24) | (buf[13] << 16) | (buf[12] << 8) | buf[11];
      if (r != addr) {
        addError('CheckRespond_FlashWrite4K: address mismatch\n');
        return false;
      }
      return true;
    }
    addError('CheckRespond_FlashWrite4K: bad value\n');
    return false;
  }

  bool _checkRespondFlashRead4K(Uint8List buf) {
    final len = 1 + 1 + (4 + 4 * 1024);
    final expected = [0x04, 0x0e, 0xff, 0x01, 0xe0, 0xfc, 0xf4,
      len & 0xff, (len >> 8) & 0xff, _Cmd.flashRead4K];
    if (buf.length >= expected.length && _cmpBytes(buf, expected, expected.length)) {
      return true;
    }
    addLog('CheckRespond_FlashRead4K: ERROR\n');
    return false;
  }

  int _checkRespondFlashGetMID(Uint8List buf) {
    final expected = [0x04, 0x0e, 0xff, 0x01, 0xe0, 0xfc, 0xf4,
      (1 + 4) & 0xff, ((1 + 4) >> 8) & 0xff, _Cmd.flashGetMID];
    if (buf.length >= expected.length && _cmpBytes(buf, expected, expected.length)) {
      return ((buf[14] << 24) | (buf[13] << 16) | (buf[12] << 8) | buf[11]) >> 8;
    }
    // BootROM bug workaround
    final expected2 = List<int>.from(expected);
    expected2[7] += 1;
    if (buf.length >= expected2.length && _cmpBytes(buf, expected2, expected2.length)) {
      return ((buf[14] << 24) | (buf[13] << 16) | (buf[12] << 8) | buf[11]) >> 8;
    }
    addError('CheckRespond_FlashGetMID: bad value\n');
    return 0;
  }

  Uint8List? _checkRespondFlashReadSR(Uint8List buf) {
    final len = 1 + 1 + (1 + 1);
    final expected = [0x04, 0x0e, 0xff, 0x01, 0xe0, 0xfc, 0xf4,
      len & 0xff, (len >> 8) & 0xff, _Cmd.flashReadSR];
    if (buf.length >= expected.length && _cmpBytes(buf, expected, expected.length)) {
      return Uint8List.fromList([buf[10], buf[12]]);
    }
    addError('CheckRespond_FlashReadSR: bad value\n');
    return null;
  }

  bool _checkRespondFlashWriteSR(Uint8List buf, int regAddr, int val) {
    final len = 1 + 1 + (1 + 1);
    final expected = [0x04, 0x0e, 0xff, 0x01, 0xe0, 0xfc, 0xf4,
      len & 0xff, (len >> 8) & 0xff, _Cmd.flashWriteSR];
    return buf.length >= expected.length && _cmpBytes(buf, expected, expected.length)
        && val == buf[12] && regAddr == buf[11];
  }

  bool _checkRespondFlashWriteSR2(Uint8List buf, int regAddr, int val) {
    final len = 1 + 1 + (1 + 2);
    final expected = [0x04, 0x0e, 0xff, 0x01, 0xe0, 0xfc, 0xf4,
      len & 0xff, (len >> 8) & 0xff, _Cmd.flashWriteSR];
    return buf.length >= expected.length && _cmpBytes(buf, expected, expected.length)
        && (val & 0xff) == buf[12] && ((val >> 8) & 0xff) == buf[13];
  }

  bool _checkRespondSetBaudRate(Uint8List buf, int baud, int delayMs) {
    final expected = Uint8List.fromList([
      0x04, 0x0e, 3 + 1 + 4 + 1, 0x01, 0xe0, 0xfc, _Cmd.setBaudRate,
      baud & 0xff, (baud >> 8) & 0xff, (baud >> 16) & 0xff, (baud >> 24) & 0xff,
      delayMs & 0xff,
    ]);
    if (buf.length < expected.length) return false;
    return _cmpBytes(buf, expected.toList(), expected.length);
  }

  bool _checkRespondEraseSector4K(Uint8List buf) {
    final expected = [0x04, 0x0e, 0xff, 0x01, 0xe0, 0xfc, 0xf4, 0x06, 0x00, _Cmd.flashErase4K];
    return buf.length >= expected.length && _cmpBytes(buf, expected, expected.length);
  }

  bool _checkRespondFlashErase(Uint8List buf, int szcmd) {
    final expected = [0x04, 0x0e, 0xff, 0x01, 0xe0, 0xfc, 0xf4, 1 + 1 + (1 + 4), 0x00, _Cmd.flashErase];
    return buf.length >= expected.length && _cmpBytes(buf, expected, expected.length)
        && szcmd == buf[11];
  }

  // ════════════════════════════════════════════════════════════════════════
  //  MID-LEVEL PROTOCOL HELPERS
  // ════════════════════════════════════════════════════════════════════════

  Future<bool> _linkCheck() async {
    // Increased timeout from 0.001 (1ms) to 0.01 (10ms) because Dart's
    // Future.delayed granularity is too coarse, causing immediate timeout.
    final rxbuf = await _startCmd(_buildCmdLinkCheck(), rxLen: _rxLenLinkCheck, timeout: 0.01);
    return rxbuf != null && _checkRespondLinkCheck(rxbuf);
  }

  Future<bool> _getBus() async {
    addLog('Getting bus... (now, please do reboot by CEN or by power off/on)\n');

    // Chip bootloader always starts at 115200 — force the transport
    // to 115200 regardless of what the UI configured.
    await transport.setBaudRate(115200);
    for (int tr = 0; tr < 100 && !isCancelled; tr++) {
      final dtrOk = await transport.setDTR(true);
      final rtsOk = await transport.setRTS(true);
      if ((!dtrOk || !rtsOk) && !_dtrRtsWarningShown) {
        _dtrRtsWarningShown = true;
        addErrorLine('\u26a0 WARNING: DTR/RTS signals could not be set. '
            'Auto-reset will NOT work. You must manually reset the device '
            'into bootloader mode (e.g. by doing a short power on/off cycle '
            'or short CEN to ground). '
            'This is a known issue with some browser/hosting configurations.');
      }
      await Future.delayed(const Duration(milliseconds: 50));
      await transport.setDTR(false);
      await transport.setRTS(false);

      if (tr % 5 == 0) {
        // Try OBK commandline reboot as fallback
        transport.write(Uint8List.fromList([...'reboot\r\n'.codeUnits]));
      }

      for (int l = 0; l < 100 && !isCancelled; l++) {
        if (await _linkCheck()) {
          addSuccess('Getting bus success!\n');
          return true;
        }
        // Yield every 10 iterations to keep UI responsive
        if (l % 10 == 9) {
          await Future.delayed(const Duration(milliseconds: 1));
        }
      }
      addWarning('Getting bus failed, will try again - $tr/100!\n');
      if (tr % 10 == 9) {
        addWarning('Reminder: you should do a device reboot now\n');
      }
    }
    return false;
  }

  Future<bool> _setBaudrate(int baud, int delayMs) async {
    final txbuf = _buildCmdSetBaudRate(baud, delayMs);
    await _startCmd(txbuf, rxLen: 0, timeout: 0.5);
    // Wait just long enough for the 12-byte TX to complete at 115200.
    // The original C# used delayMs/2 (100ms), but on platforms where
    // setBaudRate requires a close/reopen (e.g. Web Serial), the
    // remaining time must be enough for that cycle to finish before
    // the chip's configured delay expires and it sends the ACK.
    await Future.delayed(const Duration(milliseconds: 20));
    // Switch transport baud rate
    await transport.setBaudRate(baud);
    final rxbuf = await _startCmd(null, rxLen: _rxLenSetBaudRate, timeout: 0.5);
    if (rxbuf != null && _checkRespondSetBaudRate(rxbuf, baud, delayMs)) {
      return true;
    }
    // Revert
    await transport.setBaudRate(115200);
    return false;
  }

  Future<bool> _doGetBusAndSetBaudRate() async {
    setState('Getting bus...');
    if (!await _getBus()) {
      addError('Failed to get bus!\n');
      setState('Failed to get bus!');
      return false;
    }
    await Future.delayed(const Duration(milliseconds: 50));

    for (int attempt = 0; attempt < 10; attempt++) {
      addSuccess('Going to set baud rate setting ($baudrate)!\n');
      setState('Setting baud rate...');
      if (await _setBaudrate(baudrate, 200)) break;
      addError('Failed to set baud rate!\n');
      if (attempt >= 9) return false;
      await Future.delayed(const Duration(milliseconds: 50));
    }
    await Future.delayed(const Duration(milliseconds: 50));
    return true;
  }

  Future<int> _getFlashMID() async {
    final txbuf = _buildCmdFlashGetMID(0x9f);
    final rxbuf = await _startCmd(txbuf, rxLen: _rxLenFlashGetID);
    if (rxbuf != null) return _checkRespondFlashGetMID(rxbuf);
    return 0;
  }

  Future<bool> _writeFlashReg(int addr, int val) async {
    final txbuf = _buildCmdWriteReg(addr, val);
    final rxbuf = await _startCmd(txbuf, rxLen: _rxLenWriteFlashReg);
    if (rxbuf != null) return _checkRespondWriteReg(rxbuf, addr, val);
    return false;
  }

  Future<Uint8List?> _readFlashReg(int addr) async {
    final txbuf = _buildCmdReadReg(addr);
    final rxbuf = await _startCmd(txbuf, rxLen: _rxLenReadFlashReg);
    if (rxbuf != null) return _checkRespondReadFlashReg(rxbuf, addr);
    return null;
  }

  Future<int> _readFlashRegInt(int addr) async {
    final r = await _readFlashReg(addr);
    if (r != null) {
      return (r[3] << 24) | (r[2] << 16) | (r[1] << 8) | r[0];
    }
    return 0;
  }

  Future<Uint8List?> _readFlashSR(int addr) async {
    final txbuf = _buildCmdFlashReadSR(addr);
    final rxbuf = await _startCmd(txbuf, rxLen: _rxLenReadFlashSR);
    if (rxbuf != null) return _checkRespondFlashReadSR(rxbuf);
    return null;
  }

  Future<bool> _writeFlashSR(int size, int addr, int val) async {
    Uint8List txbuf;
    int rxlen;
    if (size == 1) {
      txbuf = _buildCmdFlashWriteSR(addr, val);
      rxlen = _rxLenFlashWriteSR;
    } else {
      txbuf = _buildCmdFlashWriteSR2(addr, val);
      rxlen = _rxLenFlashWriteSR2;
    }
    final rxbuf = await _startCmd(txbuf, rxLen: rxlen);
    if (rxbuf != null) {
      if (size == 1) return _checkRespondFlashWriteSR(rxbuf, addr, val);
      return _checkRespondFlashWriteSR2(rxbuf, addr, val);
    }
    return false;
  }

  // ════════════════════════════════════════════════════════════════════════
  //  SECTOR-LEVEL OPERATIONS
  // ════════════════════════════════════════════════════════════════════════

  bool _isSectorModificationAllowed(int addr) {
    if (addr >= _flashSize) {
      addError('ERROR: Out of range write/erase attempt detected');
      return false;
    }
    addr %= _flashSize;
    if (chipType != BKType.bk7231t && chipType != BKType.bk7231u) return true;
    if (addr >= 0 && addr < bootloaderSize) {
      addError('ERROR: T bootloader overwriting attempt detected');
      return false;
    }
    return true;
  }

  Future<Uint8List?> _readSector(int addr) async {
    final txbuf = _buildCmdFlashRead4K(addr);
    final rxbuf = await _startCmd(txbuf, rxLen: _rxLenFlashRead4K, timeout: 15);
    if (rxbuf != null && _checkRespondFlashRead4K(rxbuf)) return rxbuf;
    return null;
  }

  Future<bool> _writeSector4K(int addr, Uint8List data, int startOfs) async {
    if (!_isSectorModificationAllowed(addr)) return false;
    final txbuf = _buildCmdFlashWrite4K(addr, data, startOfs);
    // C# serial.Write blocks until TX completes, _then_ the 50ms timeout starts.
    // Dart transport.write is non-blocking, so we must account for the TX time
    // of the 4108-byte command (~356ms at 115200 baud) plus flash programming.
    final rxbuf = await _startCmd(txbuf, rxLen: _rxLenFlashWrite4K, timeout: 1.0);
    if (rxbuf != null) return _checkRespondFlashWrite4K(rxbuf, addr);
    return false;
  }

  Future<bool> _eraseSector(int addr, int szcmd) async {
    if (!_isSectorModificationAllowed(addr)) return false;
    final txbuf = _buildCmdFlashErase(addr, szcmd);
    final rxbuf = await _startCmd(txbuf, rxLen: _rxLenFlashErase, timeout: 1.0);
    if (rxbuf != null) return _checkRespondFlashErase(rxbuf, szcmd);
    return false;
  }

  Future<int> _calcCRCOnDevice(int start, int end) async {
    if (chipType != BKType.bk7231t && chipType != BKType.bk7231u) {
      end = end - 1;
    }
    final txbuf = _buildCmdCheckCRC(start, end);
    final rxbuf = await _startCmd(txbuf, rxLen: _rxLenCheckCRC, timeout: 5.0);
    if (rxbuf != null) return _checkRespondCheckCRC(rxbuf);
    return 0;
  }

  // ════════════════════════════════════════════════════════════════════════
  //  HIGH-LEVEL OPERATIONS
  // ════════════════════════════════════════════════════════════════════════

  Future<bool> _doGenericSetup() async {
    addLog('Flasher mode: $chipType\n');

    if (!await _openPort()) {
      setState('Open serial failed!');
      addError('Failed to open serial port!\n');
      return false;
    }
    addSuccess('Serial port open!\n');

    if (!await _doGetBusAndSetBaudRate()) return false;

    _lastEncryptionKey = '';
    if (chipType != BKType.bk7231t && chipType != BKType.bk7231u) {
      // Read chip ID
      Uint8List chipIdRaw;
      if (chipType == BKType.bk7236 || chipType == BKType.bk7258) {
        chipIdRaw = (await _readFlashReg(0x44010000 + (0x1 << 2))) ?? Uint8List(4);
      } else {
        chipIdRaw = (await _readFlashReg(0x800000)) ?? Uint8List(4);
      }
      // Reverse and build string
      final reversed = chipIdRaw.reversed.toList();
      final chipId = reversed.where((ch) => ch != 0 && ch != 1)
          .map((ch) => ch.toRadixString(16)).join();
      if (chipId.isEmpty) {
        addWarning('Failed to get chip ID!\n');
      } else {
        addLog('Chip ID: 0x$chipId\n');
      }

      if (!await _doUnprotect()) return false;

      if (chipType != BKType.bk7238 && chipType != BKType.bk7252n) {
        addLog('Going to read encryption key...\n');
        final (key, coeffs) = await _readEncryptionKey();
        addLog('Encryption key read done!\n');
        addLog('Encryption key: $key\n');

        String expectedKey;
        if (chipType == BKType.bk7231n) {
          expectedKey = tuyaEncryptionKey;
        } else if (chipType == BKType.bk7231m) {
          expectedKey = emptyEncryptionKey;
        } else {
          expectedKey = emptyEncryptionKey;
        }

        if (key != expectedKey) {
          if (key != emptyEncryptionKey && coeffs.toSet().length == 1) {
            addErrorLine('WARNING! Non-standard encryption key for $chipType!');
            if (!bSkipKeyCheck) return false;
          }
          addError('^*^*^*^* WARNING! Non-standard encryption key! ^*^*^*^*\n');
          if (!bSkipKeyCheck) return false;
        }
        _lastEncryptionKey = key;
      }
    }
    return true;
  }

  Future<bool> _doUnprotect() async {
    addLog('Will try to read device flash MID (for unprotect):\n');
    _deviceMID = await _getFlashMID();
    if (_deviceMID == 0) {
      addError('Failed to read device MID!\n');
      return false;
    }
    addSuccess('Flash MID loaded: ${_deviceMID.toRadixString(16).toUpperCase()}\n');

    _flashInfo = BKFlashList.singleton.findFlashForMID(_deviceMID);
    if (_flashInfo == null) {
      addError('Failed to find flash def for device MID!\n');
      return false;
    }
    addSuccess('Flash def found: $_flashInfo\n');

    _flashSize = _flashInfo!.szMem;
    _totalSectors = _flashSize ~/ sectorSize;
    addLog('Flash size is ${_flashSize ~/ 1024 ~/ 1024}MB\n');

    return await _setProtectState(true);
  }

  Future<bool> _setProtectState(bool unprotect) async {
    addSuccess('Entering SetProtectState($unprotect)...\n');
    final fi = _flashInfo!;
    final cw = unprotect ? fi.cwUnp : fi.cwEnp;

    for (int tryNum = 0; tryNum < 10; tryNum++) {
      int sr = 0;
      // Read SR registers
      for (int i = 0; i < fi.szSR; i++) {
        final srBytes = await _readFlashSR(fi.cwdRd[i]);
        if (srBytes != null) {
          sr |= srBytes[1] << (8 * i);
          addLog('sr: ${sr.toRadixString(16)}\n');
        } else {
          addError('SetProtectState failed because ReadFlashSR failed!\n');
          return false;
        }
      }

      addLog('final sr: ${sr.toRadixString(16)}, msk: ${fi.cwMsk.toRadixString(16)}\n');

      if ((sr & fi.cwMsk) == BKFlashList.bfd(cw, fi.sb, fi.lb)) break;

      if (tryNum >= 9) {
        addError('SetProtectState($unprotect) failed after 10 retries!\n');
        return false;
      }
      // Set the (un)protect word
      int srt = sr & (fi.cwMsk ^ 0xffffffff);
      srt |= BKFlashList.bfd(cw, fi.sb, fi.lb);
      await _writeFlashSR(fi.szSR, fi.cwdWr[0], srt & 0xffff);
      await Future.delayed(const Duration(milliseconds: 10));
    }

    addSuccess('SetProtectState($unprotect) success!\n');
    return true;
  }

  Future<(String, List<int>)> _readEncryptionKey() async {
    const sctrlEfuseCtrl = 0x00800074;
    const sctrlEfuseOptr = 0x00800078;
    final efuse = Uint8List(16);

    for (int addr = 0; addr < 16; addr++) {
      int reg = await _readFlashRegInt(sctrlEfuseCtrl);
      reg = (reg & ~0x1F02) | (addr << 8) | 1;
      await _writeFlashReg(sctrlEfuseCtrl, reg);
      while ((reg & 1) != 0) {
        reg = await _readFlashRegInt(sctrlEfuseCtrl);
      }
      reg = await _readFlashRegInt(sctrlEfuseOptr);
      if ((reg & 0x100) != 0) {
        efuse[addr] = reg & 0xff;
      }
    }

    final coeffs = List<int>.generate(4, (i) =>
        efuse[i * 4] |
        (efuse[i * 4 + 1] << 8) |
        (efuse[i * 4 + 2] << 16) |
        (efuse[i * 4 + 3] << 24));

    final key = coeffs.map((c) => c.toRadixString(16).padLeft(8, '0')).join(' ');
    return (key, coeffs);
  }

  Future<bool> _doEraseInternal(int startSector, int sectors) async {
    setProgress(0, sectors);
    setState('Erasing...');
    addLog('Going to do erase, start ${formatHex(startSector)}, sec count $sectors!\n');
    if (!await _eraseRange(startSector, sectors)) return false;
    addLog('\nAll selected sectors erased!\n');
    return true;
  }

  Future<bool> _eraseRange(int startSector, int sectors) async {
    int current = startSector ~/ sectorSize;
    final end = current + sectors;

    Future<bool> erase4k() async {
      final addr = current * sectorSize;
      for (int tries = 0; ; tries++) {
        setState('Erasing sector ${formatHex(addr)}...');
        if (await _eraseSector(addr, 0x20)) {
          current++;
          setProgress(current + 1, sectors);
          await Future.delayed(const Duration(milliseconds: 1));
          return true;
        }
        if (tries > 5) {
          setState('Erase failed.');
          addError(' Erasing sector ${formatHex(addr)} failed!\n');
          return false;
        }
        addWarning(' failed, will retry! ');
      }
    }

    // Erase sectors until 64KB aligned
    while (current < end && (current % sectorsPerBlock) != 0) {
      if (isCancelled) return false;
      if (!await erase4k()) return false;
    }

    // Erase 64KB blocks
    while ((end - current) >= sectorsPerBlock) {
      if (isCancelled) return false;
      final addr = current * sectorSize;
      for (int tries = 0; ; tries++) {
        setState('Erasing block ${formatHex(addr)}...');
        if (await _eraseSector(addr, 0xD8)) {
          current += sectorsPerBlock;
          setProgress(current + 1, sectors);
          await Future.delayed(const Duration(milliseconds: 1));
          break;
        }
        if (tries > 5) {
          setState('Erase failed.');
          addError(' Erasing block ${formatHex(addr)} failed!\n');
          return false;
        }
        addWarning(' failed, will retry! ');
      }
    }

    // Erase remaining sectors
    while (current < end) {
      if (isCancelled) return false;
      if (!await erase4k()) return false;
    }

    return true;
  }

  Future<Uint8List?> _readChunk(int startSector, int sectors) async {
    setState('Reading...');
    setProgress(0, sectors);
    final result = BytesBuilder();

    // 4K page align
    startSector = startSector & 0xfffff000;
    addLog('Going to start reading at offset ${formatHex(startSector)}...\n');
    addLogLine('Reading ${formatHex(sectors * sectorSize)} at ${formatHex(startSector)}, see progress bar for updates....');

    for (int i = 0; i < sectors; i++) {
      if (isCancelled) return null;
      int addr = startSector + sectorSize * i;
      setState('Reading ${formatHex(addr)} out of ${formatHex(startSector + sectors * sectorSize)}...');

      // BK7231T wrap-around hack
      if (chipType == BKType.bk7231t || chipType == BKType.bk7231u) {
        addr += _flashSize;
      }

      final res = await _readSector(addr);
      if (res == null) {
        setState('Reading failed.');
        addError('Failed! ');
        return null;
      }
      // Skip header (15 bytes)
      result.add(res.sublist(15));
      setProgress(i + 1, sectors);
    // Yield to let Flutter process progress update and user input
    await Future.delayed(const Duration(milliseconds: 1));
    }

    addLog('\nBasic read operation finished, now verifying...\n');
    final data = result.toBytes();

    if (!_checkAbnormal(data)) return null;
    if (!await _checkCRC(startSector, sectors, data)) return null;

    setState('Reading success!');
    addSuccess('All read!\n');
    addLog('Loaded total ${formatHex(sectors * sectorSize)} bytes\n');
    return data;
  }

  bool _checkAbnormal(Uint8List data) {
    if (data.every((b) => b == 0x00)) {
      setState('Only 0x00 bytes read!');
      addError('Data is entirely filled with 0x00, something went wrong!\n');
      return false;
    }
    if (data.every((b) => b == 0xFF)) {
      setState('Only 0xff bytes read!');
      addError('Data is entirely filled with 0xff, something went wrong!\n');
      return false;
    }
    return true;
  }

  Future<bool> _checkCRC(int startSector, int total, Uint8List data) async {
    setState('Doing CRC verification...');
    addLog('Starting CRC check for $total sectors at offset ${formatHex(startSector)}\n');
    final last = startSector + total * sectorSize;
    final bkCrc = await _calcCRCOnDevice(startSector, last);
    final ourCrc = CRC.crc32(0xffffffff, data);
    if (bkCrc != ourCrc) {
      setState('CRC mismatch!');
      addError('CRC mismatch!\n');
      addError('BK sent ${formatHex(bkCrc)}, our CRC ${formatHex(ourCrc)}\n');
      addError('Maybe you have wrong chip type set?\n');
      if (bIgnoreCRCErr) {
        addWarning('IgnoreCRCErr checked, proceeding despite CRC mismatch\n');
        return true;
      }
      return false;
    }
    addSuccess('CRC matches ${formatHex(bkCrc)}!\n');
    return true;
  }
}
