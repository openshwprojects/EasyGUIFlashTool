import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart' as launcher;
import 'firmware_storage.dart';
import '../models/chip_platform.dart';
import '../models/log_level.dart';
import '../constants.dart';

/// Result of a firmware download.
class DownloadResult {
  final String fileName;
  final String? filePath; // null on web
  final Uint8List bytes;

  /// If true, the browser-managed web download flow was used instead of returning firmware bytes directly to the app.
  final bool openedInBrowser;

  DownloadResult({
    required this.fileName,
    this.filePath,
    required this.bytes,
    this.openedInBrowser = false,
  });
}

/// Callback types used by the downloader.
typedef LogCallback = void Function(String message, {LogLevel level});
typedef ProgressCallback = void Function(int received, int total);

/// Downloads the latest OpenBK7231T_App firmware from GitHub Releases.
///
/// On Flutter web we must stay on the GitHub API / browser-download URLs path.
/// Fetching and scraping github.com release HTML pages triggers browser fetch/CORS
/// failures that were previously reported as misleading "TLS" errors.
class FirmwareDownloader {
  static const String _releasesUrl = kFirmwareReleasesUrl;
  static const String _latestReleaseUrl = '$_releasesUrl/latest';

  /// Download the latest firmware for [platform], saving via [storage].
  /// Progress and log messages are reported through callbacks.
  static Future<DownloadResult?> downloadLatest({
    required ChipPlatform platform,
    required FirmwareStorage storage,
    LogCallback? onLog,
    ProgressCallback? onProgress,
  }) async {
    void log(String msg, {LogLevel level = LogLevel.info}) {
      debugPrint('FirmwareDownloader: $msg');
      onLog?.call(msg, level: level);
    }

    final client = http.Client();
    try {
      log('Target platform: $platform');
      log('Querying GitHub Releases API...');

      final release = await _fetchBestReleaseForPlatform(
        client: client,
        platform: platform,
        onLog: log,
      );
      if (release == null) {
        return null;
      }

      final asset = _findMatchingAsset(release, platform);
      if (asset == null) {
        final pfx = platform.firmwarePrefix;
        log('Failed to find a firmware asset for prefix: $pfx',
            level: LogLevel.error);
        log('Please manually download firmware from: $_releasesUrl',
            level: LogLevel.error);
        log('Choose the file with prefix $pfx', level: LogLevel.error);
        return null;
      }

      final fileName = (asset['name'] as String?)?.trim() ?? '';
      final firmwareUrl =
          (asset['browser_download_url'] as String?)?.trim() ?? '';

      if (fileName.isEmpty || firmwareUrl.isEmpty) {
        log('GitHub release asset metadata was incomplete.',
            level: LogLevel.error);
        return null;
      }

      log('Selected asset: $fileName');
      log('Resolved download URL: $firmwareUrl');

      if (kIsWeb) {
        log(
          'Web platform — opening the browser download URL directly to avoid browser cross-origin fetch issues.',
          level: LogLevel.info,
        );

        final opened = await launcher.launchUrl(
          Uri.parse(firmwareUrl),
          webOnlyWindowName: '_blank',
        );

        if (opened) {
          log('Download opened in a new browser tab.',
              level: LogLevel.success);
          log('Drag and drop the downloaded file here, or use the "Open" button.');
        } else {
          log('Could not open the download URL automatically.',
              level: LogLevel.error);
          log('Please manually download firmware from: $firmwareUrl',
              level: LogLevel.error);
        }

        return DownloadResult(
          fileName: fileName,
          bytes: Uint8List(0),
          openedInBrowser: opened,
        );
      }

      log('Downloading $fileName ...');
      final request = http.Request('GET', Uri.parse(firmwareUrl));
      request.headers['User-Agent'] = 'EasyGUIFlashTool';
      final streamed = await client.send(request);

      if (streamed.statusCode != 200) {
        log('Firmware download failed (${streamed.statusCode}).',
            level: LogLevel.error);
        log('URL: $firmwareUrl', level: LogLevel.error);
        return null;
      }

      final totalBytes = streamed.contentLength ?? -1;
      final bytesBuilder = BytesBuilder(copy: false);
      int received = 0;

      await for (final chunk in streamed.stream) {
        bytesBuilder.add(chunk);
        received += chunk.length;
        onProgress?.call(received, totalBytes);
      }

      final bytes = bytesBuilder.toBytes();
      log('Downloaded ${bytes.length} bytes');

      final path = await storage.saveFile(kFirmwareStorageSubdir, fileName, bytes);
      if (path != null) {
        log('Saved to $path', level: LogLevel.success);
      } else {
        log('Saved in-memory', level: LogLevel.success);
      }
      log('Download ready!', level: LogLevel.success);

      return DownloadResult(fileName: fileName, filePath: path, bytes: bytes);
    } catch (ex) {
      final pfx = platform.firmwarePrefix;
      onLog?.call('Exception: $ex', level: LogLevel.error);
      onLog?.call(
        'GitHub download lookup failed. In the web build this is usually a browser fetch/CORS issue, not a TLS-version problem.',
        level: LogLevel.error,
      );
      onLog?.call('Please manually download firmware from: $_releasesUrl',
          level: LogLevel.error);
      onLog?.call('Choose the file with prefix $pfx', level: LogLevel.error);
      return null;
    } finally {
      client.close();
    }
  }

  static Future<Map<String, dynamic>?> _fetchBestReleaseForPlatform({
    required http.Client client,
    required ChipPlatform platform,
    required void Function(String msg, {LogLevel level}) onLog,
  }) async {
    final latestResp = await client.get(
      Uri.parse(_latestReleaseUrl),
      headers: const {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'EasyGUIFlashTool',
      },
    );

    if (latestResp.statusCode == 200 && latestResp.body.isNotEmpty) {
      onLog('Fetched latest release JSON (${latestResp.body.length} chars)');
      final decoded = jsonDecode(latestResp.body);
      if (decoded is Map<String, dynamic>) {
        final asset = _findMatchingAsset(decoded, platform);
        if (asset != null) {
          final tag = (decoded['tag_name'] as String?) ?? '(unknown tag)';
          onLog('Latest release tag: $tag');
          return decoded;
        }
        onLog(
          'Latest release did not contain a matching asset for ${platform.firmwarePrefix}; falling back to the full releases list.',
          level: LogLevel.warning,
        );
      }
    } else {
      onLog('Latest release lookup failed (${latestResp.statusCode}); falling back to the full releases list.',
          level: LogLevel.warning);
    }

    final releasesResp = await client.get(
      Uri.parse(_releasesUrl),
      headers: const {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'EasyGUIFlashTool',
      },
    );

    if (releasesResp.statusCode != 200 || releasesResp.body.isEmpty) {
      onLog('Failed to query GitHub Releases API (${releasesResp.statusCode}).',
          level: LogLevel.error);
      return null;
    }

    onLog('Fetched releases list JSON (${releasesResp.body.length} chars)');
    final decoded = jsonDecode(releasesResp.body);
    if (decoded is! List) {
      onLog('Unexpected GitHub Releases API response shape.',
          level: LogLevel.error);
      return null;
    }

    for (final entry in decoded) {
      if (entry is Map<String, dynamic>) {
        final asset = _findMatchingAsset(entry, platform);
        if (asset != null) {
          final tag = (entry['tag_name'] as String?) ?? '(unknown tag)';
          onLog('Selected release tag from list: $tag');
          return entry;
        }
      }
    }

    onLog('No release in the GitHub Releases API contained a matching asset.',
        level: LogLevel.error);
    return null;
  }

  static Map<String, dynamic>? _findMatchingAsset(
    Map<String, dynamic> release,
    ChipPlatform platform,
  ) {
    final rawAssets = release['assets'];
    if (rawAssets is! List) {
      return null;
    }

    final prefix = platform.firmwarePrefix;
    for (final item in rawAssets) {
      if (item is! Map<String, dynamic>) {
        continue;
      }

      final name = (item['name'] as String?) ?? '';
      if (!name.startsWith(prefix)) {
        continue;
      }
      if (name.contains('OTA') || name.contains('ota') || name.contains('_gz')) {
        continue;
      }

      final url = (item['browser_download_url'] as String?) ?? '';
      if (url.isEmpty) {
        continue;
      }
      return item;
    }

    return null;
  }
}
