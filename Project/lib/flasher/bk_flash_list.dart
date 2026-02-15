/// BK7231 flash chip database, ported from C# `BKFlashList.cs`.
///
/// Contains identification and protect/unprotect parameters for 40+
/// SPI flash ICs used in Beken-based IoT devices.
library;

import 'dart:typed_data';

/// Descriptor for a single SPI flash IC.
class BKFlash {
  final int mid;
  final String icName;
  final String manufacturer;
  final int szMem;
  final int szSR;
  final int cwUnp;
  final int cwEnp;
  final int cwMsk;
  final int sb;
  final int lb;
  final Uint8List cwdRd;
  final Uint8List cwdWr;

  const BKFlash({
    required this.mid,
    required this.icName,
    required this.manufacturer,
    required this.szMem,
    required this.szSR,
    required this.cwUnp,
    required this.cwEnp,
    required this.cwMsk,
    required this.sb,
    required this.lb,
    required this.cwdRd,
    required this.cwdWr,
  });

  @override
  String toString() =>
      'mid: ${mid.toRadixString(16).toUpperCase()}, '
      'icName: $icName, manufacturer: $manufacturer, '
      'szMem: ${szMem.toRadixString(16)}, szSR: $szSR, '
      'cwUnp: ${cwUnp.toRadixString(16)}, cwEnp: ${cwEnp.toRadixString(16)}, '
      'cwMsk: ${cwMsk.toRadixString(16)}, sb: $sb, lb: $lb';
}

/// Singleton database of known BK7231 flash chips.
class BKFlashList {
  BKFlashList._() {
    _populate();
  }

  static final BKFlashList singleton = BKFlashList._();

  final List<BKFlash> _flashes = [];

  // ── Helpers ─────────────────────────────────────────────────────────────

  /// Bit-field deposit: `(v & ((1 << bl) - 1)) << bs`
  static int bfd(int v, int bs, int bl) => (v & ((1 << bl) - 1)) << bs;

  /// Single bit: `1 << v`
  static int bit(int v) => 1 << v;

  // ── Lookup ──────────────────────────────────────────────────────────────

  /// Find flash descriptor by Manufacturer ID.  Returns `null` if unknown.
  BKFlash? findFlashForMID(int mid) {
    for (final f in _flashes) {
      if (f.mid == mid) return f;
    }
    return null;
  }

  // ── Internal population ─────────────────────────────────────────────────

  void _add(BKFlash f) => _flashes.add(f);

  void _populate() {
    // ─── 512 KB ───────────────────────────────────────────────────────────
    _add(BKFlash(mid: 0x1340e0, icName: 'PN25Q40A',  manufacturer: 'BY',   szMem: 512*1024,     szSR: 1, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,3), sb: 2, lb: 3, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
    _add(BKFlash(mid: 0x134051, icName: 'GD25D40',   manufacturer: 'GD',   szMem: 512*1024,     szSR: 1, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bfd(0x0f,2,3),         sb: 2, lb: 3, cwdRd: Uint8List.fromList([0x05,0xff,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
    _add(BKFlash(mid: 0x1364c8, icName: 'GD25Q41BT', manufacturer: 'GD',   szMem: 512*1024,     szSR: 1, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,3), sb: 2, lb: 3, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
    _add(BKFlash(mid: 0x1340c8, icName: 'GD25Q41B',  manufacturer: 'GD',   szMem: 512*1024,     szSR: 1, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,3), sb: 2, lb: 3, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
    _add(BKFlash(mid: 0x136085, icName: 'P25Q40',    manufacturer: 'Puya', szMem: 512*1024,     szSR: 2, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
    _add(BKFlash(mid: 0x1360cd, icName: 'TH25D40HB', manufacturer: 'TH',   szMem: 512*1024,     szSR: 2, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
    _add(BKFlash(mid: 0x13311c, icName: 'PN25F04B',  manufacturer: 'xtx',  szMem: 512*1024,     szSR: 1, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bfd(0x0f,2,4),         sb: 2, lb: 4, cwdRd: Uint8List.fromList([0x05,0xff,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));

    // ─── 1 MB ─────────────────────────────────────────────────────────────
    _add(BKFlash(mid: 0x1440e0, icName: 'PN25Q80A',   manufacturer: 'BY',   szMem: 1*1024*1024, szSR: 1, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,3), sb: 2, lb: 3, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
    _add(BKFlash(mid: 0x1464c8, icName: 'GD25WD80E',  manufacturer: 'GD',   szMem: 1*1024*1024, szSR: 1, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0xff,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
    _add(BKFlash(mid: 0x144051, icName: 'GD25D80',    manufacturer: 'GD',   szMem: 1*1024*1024, szSR: 1, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bfd(0x0f,2,3),         sb: 2, lb: 3, cwdRd: Uint8List.fromList([0x05,0xff,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
    _add(BKFlash(mid: 0x1440c8, icName: 'GD25D80',    manufacturer: 'GD',   szMem: 1*1024*1024, szSR: 2, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
    _add(BKFlash(mid: 0x146085, icName: 'P25Q80',     manufacturer: 'Puya', szMem: 1*1024*1024, szSR: 2, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
    _add(BKFlash(mid: 0x1460cd, icName: 'TH25Q80HB',  manufacturer: 'TH',   szMem: 1*1024*1024, szSR: 2, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
    _add(BKFlash(mid: 0x1423c2, icName: 'MX25V8035F', manufacturer: 'WH',   szMem: 1*1024*1024, szSR: 2, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(12)|bfd(0x1f,2,4), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x15,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
    _add(BKFlash(mid: 0x14405e, icName: 'PN25F08B',   manufacturer: 'xtx',  szMem: 1*1024*1024, szSR: 1, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bfd(0x0f,2,4),         sb: 2, lb: 4, cwdRd: Uint8List.fromList([0x05,0xff,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));

    // ─── 2 MB ─────────────────────────────────────────────────────────────
    _add(BKFlash(mid: 0x15701c, icName: 'EN25QH16B',  manufacturer: 'ESMT', szMem: 2*1024*1024, szSR: 1, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bfd(0xf,2,5),          sb: 2, lb: 4, cwdRd: Uint8List.fromList([0x05,0xff,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
    _add(BKFlash(mid: 0x1540c8, icName: 'GD25Q16B',   manufacturer: 'GD',   szMem: 2*1024*1024, szSR: 2, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
    _add(BKFlash(mid: 0x1565c8, icName: 'GD25WQ16E',  manufacturer: 'GD',   szMem: 2*1024*1024, szSR: 2, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
    _add(BKFlash(mid: 0x1560c4, icName: 'GT25Q16B',   manufacturer: 'GT',   szMem: 2*1024*1024, szSR: 3, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0x15,0xff]), cwdWr: Uint8List.fromList([0x01,0x31,0x11,0xff])));
    _add(BKFlash(mid: 0x154285, icName: 'P25Q16HB',   manufacturer: 'Puya', szMem: 2*1024*1024, szSR: 1, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0x31,0xff,0xff])));
    _add(BKFlash(mid: 0x152085, icName: 'P25Q16HBK',  manufacturer: 'Puya', szMem: 2*1024*1024, szSR: 2, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0x31,0xff,0xff])));
    _add(BKFlash(mid: 0x156085, icName: 'P25Q16SU',   manufacturer: 'Puya', szMem: 2*1024*1024, szSR: 2, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0x31,0xff,0xff])));
    _add(BKFlash(mid: 0x1560eb, icName: 'TH25Q16HB',  manufacturer: 'TH',   szMem: 2*1024*1024, szSR: 2, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
    _add(BKFlash(mid: 0x1523c2, icName: 'MX25V1635F', manufacturer: 'WH',   szMem: 2*1024*1024, szSR: 2, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(12)|bfd(0x1f,2,4), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x15,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
    _add(BKFlash(mid: 0x15400b, icName: 'XT25F16B',   manufacturer: 'xtx',  szMem: 2*1024*1024, szSR: 2, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));

    // ─── 4 MB ─────────────────────────────────────────────────────────────
    _add(BKFlash(mid: 0x16411c, icName: 'EN25QE32A',  manufacturer: 'ESMT', szMem: 4*1024*1024, szSR: 2, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
    _add(BKFlash(mid: 0x16611c, icName: 'EN25QW32A',  manufacturer: 'ESMT', szMem: 4*1024*1024, szSR: 2, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
    _add(BKFlash(mid: 0x1665c8, icName: 'GD25WQ32E',  manufacturer: 'GD',   szMem: 4*1024*1024, szSR: 2, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
    _add(BKFlash(mid: 0x1640c8, icName: 'GD25Q32E',   manufacturer: 'GD',   szMem: 4*1024*1024, szSR: 2, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
    _add(BKFlash(mid: 0x166085, icName: 'P25Q32H',    manufacturer: 'Puya', szMem: 4*1024*1024, szSR: 2, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
    _add(BKFlash(mid: 0x162085, icName: 'P25Q32HB',   manufacturer: 'Puya', szMem: 4*1024*1024, szSR: 2, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0x31,0xff,0xff])));
    _add(BKFlash(mid: 0x16400b, icName: 'XT25F32B',   manufacturer: 'xtx',  szMem: 4*1024*1024, szSR: 2, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));

    // ─── 8 MB ─────────────────────────────────────────────────────────────
    _add(BKFlash(mid: 0x1765c8, icName: 'GD25WQ64E',  manufacturer: 'GD',   szMem: 8*1024*1024, szSR: 2, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
    _add(BKFlash(mid: 0x176085, icName: 'P25Q64H',    manufacturer: 'Puya', szMem: 8*1024*1024, szSR: 2, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
    _add(BKFlash(mid: 0x17600b, icName: 'XT25Q64B',   manufacturer: 'xtx',  szMem: 8*1024*1024, szSR: 2, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
    _add(BKFlash(mid: 0x17400b, icName: 'XT25F64B',   manufacturer: 'xtx',  szMem: 8*1024*1024, szSR: 2, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));

    // ─── 16 MB ────────────────────────────────────────────────────────────
    _add(BKFlash(mid: 0x1860c8, icName: 'GD25LQ128E', manufacturer: 'GD',   szMem: 16*1024*1024, szSR: 2, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
    _add(BKFlash(mid: 0x1865c8, icName: 'GD25WQ128E', manufacturer: 'GD',   szMem: 16*1024*1024, szSR: 2, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
    _add(BKFlash(mid: 0x182085, icName: 'P25Q128HA',  manufacturer: 'Puya', szMem: 16*1024*1024, szSR: 2, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0x31,0xff,0xff])));
    _add(BKFlash(mid: 0x1840ef, icName: 'WB25Q128JV', manufacturer: 'WB',   szMem: 16*1024*1024, szSR: 2, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
    _add(BKFlash(mid: 0x184120, icName: 'XM25QU128C', manufacturer: 'XMC',  szMem: 16*1024*1024, szSR: 2, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
    _add(BKFlash(mid: 0x18400b, icName: 'XT25F128F',  manufacturer: 'xtx',  szMem: 16*1024*1024, szSR: 3, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0x15,0xff]), cwdWr: Uint8List.fromList([0x01,0x31,0x11,0xff])));
    _add(BKFlash(mid: 0x18600b, icName: 'XT25Q128B',  manufacturer: 'xtx',  szMem: 16*1024*1024, szSR: 3, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0x15,0xff]), cwdWr: Uint8List.fromList([0x01,0x31,0x11,0xff])));
    _add(BKFlash(mid: 0x18505e, icName: 'ZB25LQ128C', manufacturer: 'Zbit', szMem: 16*1024*1024, szSR: 2, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0x35,0x15,0xff]), cwdWr: Uint8List.fromList([0x01,0x31,0x11,0xff])));

    // ─── 32 MB ────────────────────────────────────────────────────────────
    _add(BKFlash(mid: 0x1968c8, icName: 'GD25LX256E', manufacturer: 'GD', szMem: 32*1024*1024, szSR: 1, cwUnp: 0x00, cwEnp: 0x07, cwMsk: bit(14)|bfd(0x1f,2,5), sb: 2, lb: 5, cwdRd: Uint8List.fromList([0x05,0xff,0xff,0xff]), cwdWr: Uint8List.fromList([0x01,0xff,0xff,0xff])));
  }
}
