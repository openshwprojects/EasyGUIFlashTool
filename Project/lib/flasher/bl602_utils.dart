/// BL602/BL702 utility functions ported from C# `BL602Utils.cs`.
///
/// Contains partition table definitions, partition table build/parse,
/// and boot header creation for firmware flashing.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'base_flasher.dart';
import 'bl602_flash_list.dart';
import 'crc.dart';

// ─── Partition entry ────────────────────────────────────────────────────────

class PartitionEntry {
  int partitionType;
  int typeFlag; // active slot, 0 or 1
  String name;
  int address0;
  int address1;
  int length0;
  int length1;

  PartitionEntry({
    required this.partitionType,
    required this.typeFlag,
    required this.name,
    required this.address0,
    this.address1 = 0,
    required this.length0,
    this.length1 = 0,
  });
}

// ─── Partition tables (static data from C#) ─────────────────────────────────

final List<PartitionEntry> partitions2MB = [
  PartitionEntry(partitionType: 0, typeFlag: 0, name: 'FW',
      address0: 0x10000, length0: 0x102000, address1: 0x112000, length1: 0x90000),
  PartitionEntry(partitionType: 3, typeFlag: 0, name: 'media',
      address0: 0x1A2000, length0: 0x47000),
  PartitionEntry(partitionType: 4, typeFlag: 0, name: 'PSM',
      address0: 0x1E9000, length0: 0x13000),
  PartitionEntry(partitionType: 7, typeFlag: 0, name: 'factory',
      address0: 0x1FC000, length0: 0x4000),
];

final List<PartitionEntry> partitions1MB = [
  PartitionEntry(partitionType: 0, typeFlag: 0, name: 'FW',
      address0: 0x10000, length0: 0xDC000),
  PartitionEntry(partitionType: 3, typeFlag: 0, name: 'media',
      address0: 0xEC000, length0: 0xB000),
  PartitionEntry(partitionType: 4, typeFlag: 0, name: 'PSM',
      address0: 0xF7000, length0: 0x5000),
  PartitionEntry(partitionType: 7, typeFlag: 0, name: 'factory',
      address0: 0xFC000, length0: 0x4000),
];

final List<PartitionEntry> partitions4MB = [
  PartitionEntry(partitionType: 0, typeFlag: 0, name: 'FW',
      address0: 0x10000, length0: 0x120000, address1: 0x130000, length1: 0xB9000),
  PartitionEntry(partitionType: 3, typeFlag: 0, name: 'media',
      address0: 0x200000, length0: 0x200000),
  PartitionEntry(partitionType: 4, typeFlag: 0, name: 'PSM',
      address0: 0x1E9000, length0: 0x13000),
  PartitionEntry(partitionType: 7, typeFlag: 0, name: 'factory',
      address0: 0x1FC000, length0: 0x4000),
];

final List<PartitionEntry> partitions512kBL702 = [
  PartitionEntry(partitionType: 0, typeFlag: 0, name: 'FW',
      address0: 0x3000, length0: 0x70000),
  PartitionEntry(partitionType: 3, typeFlag: 0, name: 'media',
      address0: 0x73000, length0: 0x9000),
  PartitionEntry(partitionType: 4, typeFlag: 0, name: 'PSM',
      address0: 0x7A000, length0: 0x5000),
];

final List<PartitionEntry> partitions1mbBL702 = [
  PartitionEntry(partitionType: 0, typeFlag: 0, name: 'FW',
      address0: 0x3000, length0: 0xDC000),
  PartitionEntry(partitionType: 3, typeFlag: 0, name: 'media',
      address0: 0xDF000, length0: 0x18000),
  PartitionEntry(partitionType: 4, typeFlag: 0, name: 'PSM',
      address0: 0xF7000, length0: 0x9000),
];

final List<PartitionEntry> partitions2mbBL702 = [
  PartitionEntry(partitionType: 0, typeFlag: 0, name: 'FW',
      address0: 0x3000, length0: 0x10A000, address1: 0x10D000, length1: 0x95000),
  PartitionEntry(partitionType: 3, typeFlag: 0, name: 'media',
      address0: 0x1A2000, length0: 0x47000),
  PartitionEntry(partitionType: 4, typeFlag: 0, name: 'PSM',
      address0: 0x1E9000, length0: 0x13000),
];

// ─── Constants ──────────────────────────────────────────────────────────────

const int partitionMagicCode = 0x54504642; // "BFPT" little-endian
const int headerSize = 16;
const int entrySize = 36;
const int sectorSize = 0x1000;

// ─── Partition table build ──────────────────────────────────────────────────

/// Build a partition table binary (matches C# `PT_Build`).
Uint8List ptBuild(List<PartitionEntry> entries) {
  if (entries.length > 16) {
    throw ArgumentError('Maximum 16 entries allowed');
  }

  final ms = BytesBuilder();

  // Header (16 bytes)
  final hdr = Uint8List(headerSize);
  _writeLE32(hdr, 0, partitionMagicCode); // Magic
  _writeLE16(hdr, 4, 0); // Reserved
  _writeLE16(hdr, 6, entries.length); // Count
  _writeLE32(hdr, 8, 0); // Age
  _writeLE32(hdr, 12, 0); // HeaderCRC (filled later)
  ms.add(hdr);

  // Entries
  for (final e in entries) {
    final entry = Uint8List(entrySize);
    entry[0] = e.partitionType;
    entry[2] = e.typeFlag;

    final nameBytes = ascii.encode(e.name);
    for (int i = 0; i < nameBytes.length && i < 8; i++) {
      entry[3 + i] = nameBytes[i];
    }

    _writeLE32(entry, 12, e.address0);
    _writeLE32(entry, 16, e.address1);
    _writeLE32(entry, 20, e.length0);
    _writeLE32(entry, 24, e.length1);
    ms.add(entry);
  }

  // Entries CRC32
  final built = ms.toBytes();
  final entriesCrc = CRC.crc32(0xFFFFFFFF, Uint8List.fromList(built),
      headerSize, entries.length * entrySize) ^ 0xFFFFFFFF;
  final crcBytes = Uint8List(4);
  _writeLE32(crcBytes, 0, entriesCrc);
  ms.add(crcBytes);

  // Now compute header CRC32 over first 12 bytes
  var result = Uint8List.fromList(ms.toBytes());
  final headerCrc = CRC.crc32(0xFFFFFFFF, result, 0, 12) ^ 0xFFFFFFFF;
  _writeLE32(result, 12, headerCrc);

  // Create padded partition table (0x2000 bytes, duplicated at 0x1000)
  final pTable = Uint8List(0x2000);
  pTable.setRange(0, result.length, result);
  pTable.setRange(0x1000, 0x1000 + result.length, result);

  return pTable;
}

// ─── Partition table parse ──────────────────────────────────────────────────

/// Parse a partition table from binary data (matches C# `PT_Parse`).
List<PartitionEntry> ptParse(Uint8List data) {
  final magic = _readLE32(data, 0);
  if (magic != partitionMagicCode) {
    throw FormatException('Bad partition magic');
  }

  // Verify header CRC
  final headerCrc = CRC.crc32(0xFFFFFFFF, data, 0, 12) ^ 0xFFFFFFFF;
  final storedHeaderCrc = _readLE32(data, 12);
  if (headerCrc != storedHeaderCrc) {
    throw FormatException('Header CRC mismatch');
  }

  final count = _readLE16(data, 6);
  final entriesLength = count * entrySize;

  // Verify entries CRC
  final entriesCrc = CRC.crc32(0xFFFFFFFF, data, headerSize, entriesLength) ^ 0xFFFFFFFF;
  final storedEntriesCrc = _readLE32(data, headerSize + entriesLength);
  if (entriesCrc != storedEntriesCrc) {
    throw FormatException('Entries CRC mismatch');
  }

  final list = <PartitionEntry>[];
  for (int i = 0; i < count; i++) {
    final baseOffset = headerSize + i * entrySize;
    final nameEnd = baseOffset + 3 + 8;
    var nameStr = '';
    for (int j = baseOffset + 3; j < nameEnd && j < data.length; j++) {
      if (data[j] == 0) break;
      nameStr += String.fromCharCode(data[j]);
    }

    list.add(PartitionEntry(
      partitionType: data[baseOffset],
      typeFlag: data[baseOffset + 2],
      name: nameStr,
      address0: _readLE32(data, baseOffset + 12),
      address1: _readLE32(data, baseOffset + 16),
      length0: _readLE32(data, baseOffset + 20),
      length1: _readLE32(data, baseOffset + 24),
    ));
  }
  return list;
}

// ─── Boot header creation ───────────────────────────────────────────────────

/// Create a 176-byte boot header for BL602/BL702 firmware.
///
/// Matches C# `CreateBootHeader(flashConfig, firmware, chipType)`.
Uint8List createBootHeader(FlashConfig fc, Uint8List firmware, BKType chipType) {
  final header = Uint8List(176);

  void writeBits(int value, int offset, int pos, int bitlen) {
    if (bitlen == 32) {
      _writeLE32(header, offset, value);
      return;
    }
    int oldVal = _readLE32(header, offset);
    int mask = ((1 << bitlen) - 1) << pos;
    int newVal = (oldVal & ~mask) | ((value << pos) & mask);
    _writeLE32(header, offset, newVal);
  }

  writeBits(0x504E4642, 0, 0, 32);
  writeBits(1, 4, 0, 32);

  // flash cfg
  writeBits(0x47464346, 8, 0, 32);
  writeBits(fc.io_mode, 12, 0, 8);
  writeBits(fc.cont_read_support, 12, 8, 8);
  if (chipType == BKType.bl602) {
    writeBits(1, 12, 16, 8); // sfctrl_clk_delay
    writeBits(1, 12, 24, 8); // sfctrl_clk_invert
  } else if (chipType == BKType.bl702) {
    writeBits(0, 12, 16, 8);
    writeBits(3, 12, 24, 8);
  }
  writeBits(fc.reset_en_cmd, 16, 0, 8);
  writeBits(fc.reset_cmd, 16, 8, 8);
  writeBits(fc.exit_contread_cmd, 16, 16, 8);
  writeBits(fc.exit_contread_cmd_size, 16, 24, 8);
  writeBits(fc.jedecid_cmd, 20, 0, 8);
  writeBits(fc.jedecid_cmd_dmy_clk, 20, 8, 8);
  writeBits(fc.qpi_jedecid_cmd, 20, 16, 8);
  writeBits(fc.qpi_jedecid_dmy_clk, 20, 24, 8);
  writeBits(fc.sector_size, 24, 0, 8);
  writeBits(fc.mfg_id, 24, 8, 8);
  writeBits(fc.page_size, 24, 16, 16);
  writeBits(fc.chip_erase_cmd, 28, 0, 8);
  writeBits(fc.sector_erase_cmd, 28, 8, 8);
  writeBits(fc.blk32k_erase_cmd, 28, 16, 8);
  writeBits(fc.blk64k_erase_cmd, 28, 24, 8);
  writeBits(fc.write_enable_cmd, 32, 0, 8);
  writeBits(fc.page_prog_cmd, 32, 8, 8);
  writeBits(fc.qpage_prog_cmd, 32, 16, 8);
  writeBits(fc.qual_page_prog_addr_mode, 32, 24, 8);
  writeBits(fc.fast_read_cmd, 36, 0, 8);
  writeBits(fc.fast_read_dmy_clk, 36, 8, 8);
  writeBits(fc.qpi_fast_read_cmd, 36, 16, 8);
  writeBits(fc.qpi_fast_read_dmy_clk, 36, 24, 8);
  writeBits(fc.fast_read_do_cmd, 40, 0, 8);
  writeBits(fc.fast_read_do_dmy_clk, 40, 8, 8);
  writeBits(fc.fast_read_dio_cmd, 40, 16, 8);
  writeBits(fc.fast_read_dio_dmy_clk, 40, 24, 8);
  writeBits(fc.fast_read_qo_cmd, 44, 0, 8);
  writeBits(fc.fast_read_qo_dmy_clk, 44, 8, 8);
  writeBits(fc.fast_read_qio_cmd, 44, 16, 8);
  writeBits(fc.fast_read_qio_dmy_clk, 44, 24, 8);
  writeBits(fc.qpi_fast_read_qio_cmd, 48, 0, 8);
  writeBits(fc.qpi_fast_read_qio_dmy_clk, 48, 8, 8);
  writeBits(fc.qpi_page_prog_cmd, 48, 16, 8);
  writeBits(fc.write_vreg_enable_cmd, 48, 24, 8);
  writeBits(fc.wel_reg_index, 52, 0, 8);
  writeBits(fc.qe_reg_index, 52, 8, 8);
  writeBits(fc.busy_reg_index, 52, 16, 8);
  writeBits(fc.wel_bit_pos, 52, 24, 8);
  writeBits(fc.qe_bit_pos, 56, 0, 8);
  writeBits(fc.busy_bit_pos, 56, 8, 8);
  writeBits(fc.wel_reg_write_len, 56, 16, 8);
  writeBits(fc.wel_reg_read_len, 56, 24, 8);
  writeBits(fc.qe_reg_write_len, 60, 0, 8);
  writeBits(fc.qe_reg_read_len, 60, 8, 8);
  writeBits(fc.release_power_down, 60, 16, 8);
  writeBits(fc.busy_reg_read_len, 60, 24, 8);
  writeBits(fc.reg_read_cmd0, 64, 0, 8);
  writeBits(fc.reg_read_cmd1, 64, 8, 8);
  writeBits(fc.reg_write_cmd0, 68, 0, 8);
  writeBits(fc.reg_write_cmd1, 68, 8, 8);
  writeBits(fc.enter_qpi_cmd, 72, 0, 8);
  writeBits(fc.exit_qpi_cmd, 72, 8, 8);
  writeBits(fc.cont_read_code, 72, 16, 8);
  writeBits(fc.cont_read_exit_code, 72, 24, 8);
  writeBits(fc.burst_wrap_cmd, 76, 0, 8);
  writeBits(fc.burst_wrap_dmy_clk, 76, 8, 8);
  writeBits(fc.burst_wrap_data_mode, 76, 16, 8);
  writeBits(fc.burst_wrap_code, 76, 24, 8);
  writeBits(fc.de_burst_wrap_cmd, 80, 0, 8);
  writeBits(fc.de_burst_wrap_cmd_dmy_clk, 80, 8, 8);
  writeBits(fc.de_burst_wrap_code_mode, 80, 16, 8);
  writeBits(fc.de_burst_wrap_code, 80, 24, 8);
  writeBits(fc.sector_erase_time, 84, 0, 16);
  writeBits(fc.blk32k_erase_time, 84, 16, 16);
  writeBits(fc.blk64k_erase_time, 88, 0, 16);
  writeBits(fc.page_prog_time, 88, 16, 16);
  writeBits(fc.chip_erase_time & 0xFFFF, 92, 0, 16);
  writeBits(fc.power_down_delay, 92, 16, 8);
  writeBits(fc.qe_data, 92, 24, 8);

  // flashcfg CRC32
  writeBits(CRC.crc32(0xFFFFFFFF, header, 12, 84) ^ 0xFFFFFFFF, 96, 0, 32);

  // clk cfg
  writeBits(0x47464350, 100, 0, 32); // clkcfg_magic_code
  if (chipType == BKType.bl602) {
    writeBits(4, 104, 0, 8);  // xtal_type 40M
    writeBits(4, 104, 8, 8);  // pll_clk 160M
    writeBits(0, 104, 16, 8); // hclk_div
    writeBits(1, 104, 24, 8); // bclk_div
    writeBits(3, 108, 0, 8);  // flash_clk_type 80M
    writeBits(1, 108, 8, 8);  // flash_clk_div
  } else if (chipType == BKType.bl702) {
    writeBits(1, 104, 0, 8);  // xtal_type 32M
    writeBits(1, 104, 8, 8);  // pll_clk XTAL
    writeBits(0, 104, 16, 8); // hclk_div
    writeBits(0, 104, 24, 8); // bclk_div
    writeBits(1, 108, 0, 8);  // flash_clk_type XCLK
    writeBits(0, 108, 8, 8);  // flash_clk_div
  }
  // clkcfg CRC32
  writeBits(CRC.crc32(0xFFFFFFFF, header, 104, 8) ^ 0xFFFFFFFF, 112, 0, 32);

  // bootcfg
  writeBits(0, 116, 0, 2);  // sign
  writeBits(0, 116, 2, 2);  // encrypt_type
  writeBits(0, 116, 4, 2);  // key_sel
  writeBits(1, 116, 8, 1);  // no_segment
  writeBits(1, 116, 9, 1);  // cache_enable
  writeBits(0, 116, 10, 1); // notload_in_bootrom
  writeBits(0, 116, 11, 1); // aes_region_lock
  writeBits(3, 116, 12, 4); // cache_way_disable
  writeBits(0, 116, 16, 1); // crc_ignore
  writeBits(0, 116, 17, 1); // hash_ignore
  if (chipType == BKType.bl702) {
    writeBits(1, 116, 19, 1); // boot2_enable
    writeBits(0, 116, 20, 1); // boot2_rollback
  }

  writeBits(firmware.length, 120, 0, 32); // img_len
  writeBits(0, 124, 0, 32); // bootentry
  writeBits(0x1000, 128, 0, 32); // img_start
  if (chipType == BKType.bl702) {
    writeBits(0x1000, 164, 0, 32); // boot2_pt_table_0
    writeBits(0x2000, 168, 0, 32); // boot2_pt_table_1
  }

  // SHA256 hash of firmware
  final sha = sha256.convert(firmware);
  for (int i = 0; i < 32; i++) {
    header[132 + i] = sha.bytes[i];
  }

  // final CRC32
  writeBits(CRC.crc32(0xFFFFFFFF, header, 0, 172) ^ 0xFFFFFFFF, 172, 0, 32);

  return header;
}

// ─── Utility: pad array ─────────────────────────────────────────────────────

/// Pad [data] to [targetSize] with zeroes.
Uint8List padArray(Uint8List data, int targetSize) {
  if (data.length >= targetSize) return data;
  final result = Uint8List(targetSize);
  result.setRange(0, data.length, data);
  return result;
}

// ─── Internal LE helpers ────────────────────────────────────────────────────

void _writeLE32(Uint8List buf, int offset, int value) {
  buf[offset] = value & 0xFF;
  buf[offset + 1] = (value >> 8) & 0xFF;
  buf[offset + 2] = (value >> 16) & 0xFF;
  buf[offset + 3] = (value >> 24) & 0xFF;
}

void _writeLE16(Uint8List buf, int offset, int value) {
  buf[offset] = value & 0xFF;
  buf[offset + 1] = (value >> 8) & 0xFF;
}

int _readLE32(Uint8List buf, int offset) {
  return buf[offset] |
      (buf[offset + 1] << 8) |
      (buf[offset + 2] << 16) |
      (buf[offset + 3] << 24);
}

int _readLE16(Uint8List buf, int offset) {
  return buf[offset] | (buf[offset + 1] << 8);
}
