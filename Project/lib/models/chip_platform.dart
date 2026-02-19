/// Supported chip platforms for the flash tool.
///
/// Each variant carries its display name and knows how to derive its
/// firmware-file prefix (mirroring the C# `FormMain.getFirmwarePrefix`).

import '../flasher/base_flasher.dart';

enum ChipPlatform {
  bk7231t('BK7231T'),
  bk7231u('BK7231U'),
  bk7231n('BK7231N'),
  bk7231m('BK7231M'),
  bk7238('BK7238'),
  bk7236('BK7236'),
  bk7252('BK7252'),
  bk7252n('BK7252N'),
  bk7258('BK7258'),
  bl602('BL602'),
  bl702('BL702'),
  w600('W600'),
  w800('W800'),
  ln882h('LN882H'),
  xr809('XR809'),
  rtl8710b('RTL8710B'),
  esp32('ESP32');

  const ChipPlatform(this.displayName);

  /// Human-readable label shown in the UI dropdown.
  final String displayName;

  /// Firmware-file prefix used to match release assets on GitHub.
  ///
  /// Mirrors the C# `FormMain.getFirmwarePrefix(BKType)` logic:
  /// - QIO variants  → `Open<name>_QIO_`
  /// - UA  variants  → `Open<name>_UA_`
  /// - Everything else → `Open<name>_`
  String get firmwarePrefix {
    switch (this) {
      case ChipPlatform.bk7231n:
      case ChipPlatform.bk7231m:
      case ChipPlatform.bk7236:
      case ChipPlatform.bk7238:
      case ChipPlatform.bk7252n:
      case ChipPlatform.bk7258:
        return 'Open${displayName}_QIO_';
      case ChipPlatform.bk7231t:
      case ChipPlatform.bk7231u:
      case ChipPlatform.bk7252:
        return 'Open${displayName}_UA_';
      default:
        return 'Open${displayName}_';
    }
  }

  @override
  String toString() => displayName;
}

/// Extension to convert UI [ChipPlatform] to the flasher's [BKType] enum.
/// Returns null for non-BK platforms (BL602, W600, ESP32, etc.).
///
/// Import: `import '../flasher/base_flasher.dart';`
extension ChipPlatformFlasher on ChipPlatform {
  BKType? get bkType {
    switch (this) {
      case ChipPlatform.bk7231t: return BKType.bk7231t;
      case ChipPlatform.bk7231u: return BKType.bk7231u;
      case ChipPlatform.bk7231n: return BKType.bk7231n;
      case ChipPlatform.bk7231m: return BKType.bk7231m;
      case ChipPlatform.bk7238:  return BKType.bk7238;
      case ChipPlatform.bk7236:  return BKType.bk7236;
      case ChipPlatform.bk7252:  return BKType.bk7252;
      case ChipPlatform.bk7252n: return BKType.bk7252n;
      case ChipPlatform.bk7258:  return BKType.bk7258;
      default: return null;
    }
  }
}
