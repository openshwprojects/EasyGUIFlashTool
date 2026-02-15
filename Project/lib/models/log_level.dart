/// Shared log severity levels used across the application.
///
/// Used by both the flasher protocol layer and the firmware downloader
/// so that log consumers (UI, etc.) only deal with a single type.
enum LogLevel { info, warning, error, success }
