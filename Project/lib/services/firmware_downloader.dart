import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:http/http.dart' as http;
import 'firmware_storage.dart';
import '../models/chip_platform.dart';
import '../constants.dart';

// Conditionally import dart:html only on web
// We use url_launcher instead for cross-platform URL opening
import 'package:url_launcher/url_launcher.dart' as launcher;

/// Result of a firmware download.
class DownloadResult {
  final String fileName;
  final String? filePath; // null on web
  final Uint8List bytes;
  /// If true, the file was opened in the browser (web) rather than downloaded in-app.
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

enum LogLevel { info, success, warning, error }

/// Downloads the latest OpenBK7231T_App firmware from GitHub Releases.
/// Mirrors the logic in FormDownloader.cs from the C# flasher.
class FirmwareDownloader {
  static const String _releasesUrl = kFirmwareReleasesUrl;

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

    try {
      log('Target platform: $platform');
      log('Downloading main Releases page...');

      // --- Step 1: fetch the releases page ---
      final client = http.Client();
      try {
        final releasesResp = await client.get(
          Uri.parse(_releasesUrl),
          headers: {'User-Agent': 'EasyGUIFlashTool'},
        );
        if (releasesResp.statusCode != 200 || releasesResp.body.length <= 1) {
          log('Failed to download Releases page (${releasesResp.statusCode})',
              level: LogLevel.error);
          return null;
        }

        String html = releasesResp.body;
        log('Got reply length ${html.length}');

        // --- Step 2: find the first release tag link ---
        const marker = 'openshwprojects/OpenBK7231T_App/releases/tag/';
        int pos = html.indexOf(marker);
        if (pos >= 0) {
          // Walk back to enclosing quote
          int sx = html.lastIndexOf('"', pos);
          if (sx >= 0) {
            sx++;
            int end = html.indexOf('"', pos);
            if (end > sx) {
              String tagLink = 'https://github.com${html.substring(sx, end)}';
              log('Found release tag: $tagLink');
              // Fetch expanded release page
              final tagResp = await client.get(
                Uri.parse(tagLink),
                headers: {'User-Agent': 'EasyGUIFlashTool'},
              );
              if (tagResp.statusCode == 200 && tagResp.body.length > 1) {
                html = tagResp.body;
              }
            }
          }
        }

        // --- Step 3: search for the firmware download link ---
        final pfx = platform.firmwarePrefix;
        log('Searching for prefix: $pfx');

        String firmwareUrl = '';
        int start = 0;
        bool found = false;
        while (true) {
          int ofs = html.indexOf(pfx, start);
          if (ofs == -1) {
            log('Failed to find binary link for $pfx in releases page!',
                level: LogLevel.error);
            log('You can manually download firmware from: $_releasesUrl',
                level: LogLevel.error);
            return null;
          }

          firmwareUrl = _pickQuotedString(html, ofs);
          if (firmwareUrl.contains('OTA') ||
              firmwareUrl.contains('ota') ||
              firmwareUrl.contains('_gz')) {
            start = ofs + firmwareUrl.length;
            continue;
          }
          found = true;
          break;
        }

        if (!found) {
          log('Failed to find non-OTA firmware link!', level: LogLevel.error);
          return null;
        }

        // Make sure URL is absolute
        if (!firmwareUrl.startsWith('http')) {
          firmwareUrl = 'https://github.com$firmwareUrl';
        }

        final fileName = Uri.parse(firmwareUrl).pathSegments.last;
        log('Found link: $firmwareUrl');

        // --- Step 4: download the binary ---
        if (kIsWeb) {
          // On web, we can't stream-download due to CORS on GitHub's CDN.
          // Open the download URL in a new browser tab instead.
          log('Web platform — opening download in browser due to CORS limitation (browser security).', level: LogLevel.warning);
          final uri = Uri.parse(firmwareUrl);
          if (await launcher.canLaunchUrl(uri)) {
            await launcher.launchUrl(uri, mode: launcher.LaunchMode.externalApplication);
            log('Download opened in new browser tab!', level: LogLevel.success);
            log('Drag and drop the downloaded file here, or use the "Open" button.', level: LogLevel.info);
          } else {
            log('Could not open URL. Please download manually:', level: LogLevel.error);
            log(firmwareUrl, level: LogLevel.error);
          }
          return DownloadResult(
            fileName: fileName,
            bytes: Uint8List(0),
            openedInBrowser: true,
          );
        }

        // Native platforms: stream-download with progress
        log('Downloading $fileName ...');
        final request = http.Request('GET', Uri.parse(firmwareUrl));
        request.headers['User-Agent'] = 'EasyGUIFlashTool';
        final streamed = await client.send(request);
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

        // --- Step 5: save via FirmwareStorage ---
        final path = await storage.saveFile(kFirmwareStorageSubdir, fileName, bytes);
        if (path != null) {
          log('Saved to $path', level: LogLevel.success);
        } else {
          log('Saved in-memory (web)', level: LogLevel.success);
        }
        log('Download ready!', level: LogLevel.success);

        return DownloadResult(fileName: fileName, filePath: path, bytes: bytes);
      } finally {
        client.close();
      }
    } catch (ex) {
      onLog?.call('Exception: $ex', level: LogLevel.error);
      onLog?.call(
        "It's possible your system does not support the TLS version needed by GitHub.",
        level: LogLevel.error,
      );
      onLog?.call('Please manually download firmware from: $_releasesUrl',
          level: LogLevel.error);
      final pfx = platform.firmwarePrefix;
      onLog?.call('Choose the file with prefix $pfx', level: LogLevel.error);
      return null;
    }
  }

  /// Pick the string enclosed in quotes around position [at] in [buffer].
  /// Mirrors FormDownloader.pickQuotedString().
  static String _pickQuotedString(String buffer, int at) {
    int start = at;
    while (start > 0 && buffer[start] != '"') {
      start--;
    }
    start++;
    int end = at;
    while (end + 1 < buffer.length && buffer[end] != '"') {
      end++;
    }
    return buffer.substring(start, end);
  }
}
