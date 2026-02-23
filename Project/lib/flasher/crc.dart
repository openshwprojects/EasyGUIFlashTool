/// CRC utilities ported from BK7231Flasher C# `CRC.cs`.
///
/// Only CRC-32 (used by the BK7231 flash protocol) is ported.
library;

import 'dart:typed_data';

/// CRC-32 implementation matching the BK7231 bootloader.
///
/// Uses polynomial 0xEDB88320 (bit-reversed standard CRC-32).
class CRC {
  static Uint32List? _table;

  /// Lazily initialise the lookup table (called automatically).
  static void _initTable() {
    _table = Uint32List(256);
    for (int i = 0; i < 256; i++) {
      int c = i;
      for (int j = 0; j < 8; j++) {
        if ((c & 1) != 0) {
          c = (0xEDB88320 ^ (c >>> 1));
        } else {
          c = c >>> 1;
        }
      }
      _table![i] = c;
    }
  }

  /// Compute CRC-32 over [buffer].
  ///
  /// [crc] is the initial CRC value (typically `0xFFFFFFFF`).
  /// [offset] and [length] allow operating on a sub-range.
  static int crc32(int crc, Uint8List buffer, [int offset = 0, int? length]) {
    if (_table == null) _initTable();
    final len = length ?? (buffer.length - offset);
    for (int i = offset; i < offset + len; i++) {
      final c = buffer[i];
      crc = (_table![((crc ^ c) & 0xFF)] ^ (crc >>> 8));
    }
    return crc;
  }
}

// ─── CRC-16 variants used by WM flasher & XMODEM ───────────────────────────

/// Which CRC-16 polynomial / init to use.
enum CRC16Type {
  /// CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflect.
  ccittFalse,

  /// CRC-16/XMODEM: poly 0x1021, init 0x0000, no reflect.
  xmodem,
}

/// CRC-16 with configurable init value, poly 0x1021, no reflection.
///
/// Table is lazily built once per [CRC16Type] and reused.
class CRC16 {
  // One lookup table per type.
  static final Map<CRC16Type, Uint16List> _tables = {};

  static Uint16List _getTable(CRC16Type type) {
    return _tables[type] ??= _buildTable();
  }

  static Uint16List _buildTable() {
    const int poly = 0x1021;
    final t = Uint16List(256);
    for (int b = 0; b < 256; b++) {
      int crc = b << 8;
      for (int i = 0; i < 8; i++) {
        if ((crc & 0x8000) != 0) {
          crc = ((crc << 1) ^ poly) & 0xFFFF;
        } else {
          crc = (crc << 1) & 0xFFFF;
        }
      }
      t[b] = crc;
    }
    return t;
  }

  static int _initFor(CRC16Type type) {
    switch (type) {
      case CRC16Type.ccittFalse:
        return 0xFFFF;
      case CRC16Type.xmodem:
        return 0x0000;
    }
  }

  /// Compute CRC-16 over [data] (or a sub-range).
  static int compute(CRC16Type type, Uint8List data,
      [int offset = 0, int? length]) {
    final table = _getTable(type);
    int crc = _initFor(type);
    final len = length ?? (data.length - offset);
    for (int i = offset; i < offset + len; i++) {
      final idx = ((crc >> 8) ^ data[i]) & 0xFF;
      crc = (table[idx] ^ ((crc << 8) & 0xFFFF));
    }
    return crc;
  }
}
