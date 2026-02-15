/// Application-wide constants.
///
/// Centralises magic strings and numeric literals so they are defined once
/// and referenced everywhere.
library;

// ─── Serial / Baud ──────────────────────────────────────────────────────────

/// Common baud rates offered in the serial-port dropdown.
const List<int> kCommonBaudRates = [
  9600,
  19200,
  38400,
  57600,
  115200,
  230400,
  460800,
  921600,
];

/// Default baud rate used when no preference has been set.
const int kDefaultBaudRate = 115200;

// ─── Firmware / Storage ─────────────────────────────────────────────────────

/// GitHub Releases API URL for the OpenBK7231T_App firmware.
const String kFirmwareReleasesUrl =
    'https://api.github.com/repos/openshwprojects/OpenBK7231T_App/releases';

/// Sub-directory name used by [FirmwareStorage] for downloaded firmware files.
const String kFirmwareStorageSubdir = 'firmwares';
