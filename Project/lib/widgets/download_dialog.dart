import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'dart:typed_data';
import 'package:desktop_drop/desktop_drop.dart';
import '../services/firmware_downloader.dart';
import '../services/firmware_storage.dart';
import '../models/chip_platform.dart';
import '../models/log_level.dart';
import '../constants.dart';
import 'linkified_text.dart';

/// Modal dialog that downloads the latest firmware for a given platform,
/// showing a scrolling log area and a progress bar.
/// On web, shows a drag-and-drop zone after opening the download in a new tab.
class DownloadDialog extends StatefulWidget {
  final ChipPlatform platform;
  final FirmwareStorage storage;

  const DownloadDialog({
    super.key,
    required this.platform,
    required this.storage,
  });

  /// Show the dialog as a modal and return the DownloadResult (or null).
  static Future<DownloadResult?> show(
    BuildContext context, {
    required ChipPlatform platform,
    required FirmwareStorage storage,
  }) {
    return showDialog<DownloadResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => DownloadDialog(platform: platform, storage: storage),
    );
  }

  @override
  State<DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends State<DownloadDialog> {
  final List<_LogEntry> _log = [];
  final ScrollController _scrollCtrl = ScrollController();
  double _progress = 0.0;
  bool _done = false;
  bool _isDragOver = false;
  bool _webOpenedInBrowser = false;
  DownloadResult? _result;

  @override
  void initState() {
    super.initState();
    _startDownload();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _startDownload() async {
    _result = await FirmwareDownloader.downloadLatest(
      platform: widget.platform,
      storage: widget.storage,
      onLog: (msg, {level = LogLevel.info}) {
        if (!mounted) return;
        setState(() {
          _log.add(_LogEntry(msg, level));
        });
        _scrollToBottom();
      },
      onProgress: (received, total) {
        if (!mounted) return;
        setState(() {
          _progress = total > 0 ? received / total : 0;
        });
      },
    );
    if (mounted) {
      setState(() {
        _done = true;
        _webOpenedInBrowser = _result?.openedInBrowser ?? false;
      });
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// Handle a dropped file — save to storage and auto-close.
  Future<void> _handleDroppedFile(String fileName, Uint8List bytes) async {
    setState(() {
      _log.add(_LogEntry('Received: $fileName (${bytes.length} bytes)', LogLevel.info));
    });
    _scrollToBottom();

    final path = await widget.storage.saveFile(kFirmwareStorageSubdir, fileName, bytes);
    final result = DownloadResult(
      fileName: fileName,
      filePath: path,
      bytes: bytes,
    );

    setState(() {
      _log.add(_LogEntry('File loaded successfully!', LogLevel.success));
      _result = result;
    });
    _scrollToBottom();

    // Auto-close after a brief moment so user sees the success
    await Future.delayed(const Duration(milliseconds: 600));
    if (mounted) {
      Navigator.of(context).pop(result);
    }
  }

  Color _colorFor(LogLevel level) {
    switch (level) {
      case LogLevel.error:
        return Colors.red.shade300;
      case LogLevel.warning:
        return Colors.orange.shade300;
      case LogLevel.success:
        return Colors.greenAccent;
      case LogLevel.info:
      default:
        return Colors.white70;
    }
  }

  @override
  Widget build(BuildContext context) {
    final pct = (_progress * 100).toInt();

    return AlertDialog(
      backgroundColor: const Color(0xFF1E1E2E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(
            _done
                ? (_result != null ? Icons.check_circle : Icons.error)
                : Icons.cloud_download,
            color: _done
                ? (_result != null ? Colors.greenAccent : Colors.red)
                : Colors.deepOrange,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Download Firmware — ${widget.platform}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 520,
        height: _webOpenedInBrowser ? 420 : 340,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Progress bar
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: _done ? 1.0 : (_progress > 0 ? _progress : null),
                      minHeight: 10,
                      backgroundColor: Colors.grey.shade800,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        _done
                            ? (_result != null ? Colors.green : Colors.red)
                            : Colors.deepOrange,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  _done ? 'Done' : '$pct%',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Log area
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.grey.shade700),
                ),
                child: ListView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.all(10),
                  itemCount: _log.length,
                  itemBuilder: (_, i) {
                    final entry = _log[i];
                    return LinkifiedText(
                      entry.message,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: _colorFor(entry.level),
                        height: 1.5,
                      ),
                    );
                  },
                ),
              ),
            ),

            // Drag-and-drop zone — shown on web after download opened in browser
            if (_webOpenedInBrowser) ...[
              const SizedBox(height: 12),
              _buildDropZone(),
            ],
          ],
        ),
      ),
      actions: [
        // Copy log button
        IconButton(
          icon: const Icon(Icons.copy, size: 18),
          tooltip: 'Copy log to clipboard',
          onPressed: _log.isEmpty
              ? null
              : () {
                  final text = _log.map((e) => e.message).join('\n');
                  Clipboard.setData(ClipboardData(text: text));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Log copied to clipboard'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_done ? _result : null),
          child: Text(
            _done ? 'Close' : 'Cancel',
            style: const TextStyle(
              color: Colors.deepOrange,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDropZone() {
    return DropTarget(
      onDragEntered: (_) => setState(() => _isDragOver = true),
      onDragExited: (_) => setState(() => _isDragOver = false),
      onDragDone: (details) async {
        setState(() => _isDragOver = false);
        if (details.files.isEmpty) return;

        final droppedFile = details.files.first;
        final fileName = droppedFile.name;
        final bytes = await droppedFile.readAsBytes();
        await _handleDroppedFile(fileName, bytes);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 70,
        decoration: BoxDecoration(
          color: _isDragOver
              ? Colors.deepOrange.withOpacity(0.15)
              : Colors.grey.shade900,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: _isDragOver ? Colors.deepOrange : Colors.grey.shade600,
            width: _isDragOver ? 2 : 1,
            strokeAlign: BorderSide.strokeAlignInside,
          ),
        ),
        child: Center(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.file_download,
                color: _isDragOver ? Colors.deepOrange : Colors.grey.shade400,
                size: 24,
              ),
              const SizedBox(width: 10),
              Text(
                '...or just drag & drop the downloaded file here',
                style: TextStyle(
                  color: _isDragOver ? Colors.deepOrange : Colors.grey.shade400,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LogEntry {
  final String message;
  final LogLevel level;
  _LogEntry(this.message, this.level);
}
