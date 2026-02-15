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
