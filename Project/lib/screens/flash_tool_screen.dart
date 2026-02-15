import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'dart:io' show Platform;
import 'package:provider/provider.dart';
import '../providers/serial_provider.dart';
import '../services/firmware_storage.dart';
import '../services/firmware_downloader.dart';
import '../widgets/download_dialog.dart';

class FlashToolScreen extends StatefulWidget {
  const FlashToolScreen({super.key});

  @override
  State<FlashToolScreen> createState() => _FlashToolScreenState();
}

class _FlashToolScreenState extends State<FlashToolScreen> {
  final ScrollController _logScrollController = ScrollController();
  final TextEditingController _customBaudController = TextEditingController();

  final List<int> _commonBaudRates = [9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600];
  bool _useCustomBaud = false;

  // --- GUI-layer state (not in provider) ---
  final List<String> _logLines = [];
  double _progress = 0.0;
  String _selectedPlatform = 'BK7231T';
  String _selectedFirmware = '(none)';
  String? _customFirmwarePath;
  bool _isDragOver = false;

  // Firmware storage service (shared singleton)
  final FirmwareStorage _storage = FirmwareStorage();

  // Dynamic firmware list loaded from disk
  List<String> _availableFirmwares = ['(none)'];

  static const List<String> _platforms = [
    'BK7231T',
    'BK7231N',
    'BK7231M',
    'BK7238',
    'BK7236',
    'BK7252',
    'BK7252N',
    'BK7258',
    'BL602',
    'BL702',
    'W600',
    'W800',
    'LN882H',
    'XR809',
    'RTL8710B',
    'ESP32',
  ];

  @override
  void initState() {
    super.initState();
    _refreshFirmwareList();
  }

  @override
  void dispose() {
    _logScrollController.dispose();
    _customBaudController.dispose();
    super.dispose();
  }

  /// Reload the firmware dropdown from disk (or in-memory on web).
  Future<void> _refreshFirmwareList() async {
    final prefix = FirmwareDownloader.getFirmwarePrefix(_selectedPlatform);
    final files = await _storage.listFiles('firmwares', prefix: prefix);
    if (mounted) {
      setState(() {
        _availableFirmwares = ['(none)', ...files];
        // Keep current selection if still valid, else reset
        if (!_availableFirmwares.contains(_selectedFirmware)) {
          _selectedFirmware = '(none)';
        }
      });
    }
    // If we have no selection yet, try to restore the last downloaded
    if (_selectedFirmware == '(none)' && _customFirmwarePath == null) {
      final last = await _storage.getLastSaved('firmwares');
      if (last != null && _availableFirmwares.contains(last) && mounted) {
        setState(() => _selectedFirmware = last);
      }
    }
  }

  void _addLog(String message) {
    final now = DateTime.now();
    final ts = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    setState(() {
      _logLines.add('[$ts] $message');
    });
    _scrollLogToBottom();
  }

  void _scrollLogToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollController.hasClients) {
        _logScrollController.animateTo(
          _logScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  bool _isDesktop() {
    if (kIsWeb) return false;
    return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.developer_board, color: colorScheme.primary),
            const SizedBox(width: 10),
            const Text('EasyGUI Flash Tool'),
          ],
        ),
        actions: const [],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Top controls: flow inline, wrap when narrow
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _buildConnectionSection(),
                _buildPlatformSection(),
                _buildFirmwareSection(),
              ],
            ),
            const SizedBox(height: 16),

            // Divider
            Divider(color: colorScheme.outlineVariant),
            const SizedBox(height: 12),

            // Action buttons
            _buildActionButtons(),
            const SizedBox(height: 16),

            // Progress bar
            _buildProgressBar(),
            const SizedBox(height: 16),

            // Log field (expanded)
            Expanded(child: _buildLogField()),
          ],
        ),
      ),
    );
  }

  // ─── Section 1: COM Port + Baud + Open/Close + Connection State ───

  Widget _buildConnectionSection() {
    return Consumer<SerialProvider>(
      builder: (context, provider, _) {
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // Port dropdown
              if (_isDesktop()) _buildPortSelector(provider),

              // Baud rate
              _buildBaudRateSelector(provider),

              // Open / Close button
              _buildConnectionButton(provider),

              // Connection state indicator
              _buildStatusChip(provider),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPortSelector(SerialProvider provider) {
    final ports = provider.getAvailablePorts();

    if (ports.isEmpty) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Chip(
            avatar: Icon(Icons.usb_off, size: 18),
            label: Text('No ports'),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: provider.refreshPorts,
            tooltip: 'Refresh ports',
          ),
        ],
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.usb, size: 20),
        const SizedBox(width: 6),
        DropdownButton<String>(
          value: provider.selectedPort != null && ports.contains(provider.selectedPort)
              ? provider.selectedPort
              : ports.first,
          hint: const Text('Select Port'),
          items: ports.map((port) {
            return DropdownMenuItem(value: port, child: Text(port));
          }).toList(),
          onChanged: provider.isConnected
              ? null
              : (value) {
                  if (value != null) provider.setPort(value);
                },
        ),
        IconButton(
          icon: const Icon(Icons.refresh, size: 20),
          onPressed: provider.isConnected ? null : provider.refreshPorts,
          tooltip: 'Refresh ports',
        ),
      ],
    );
  }

  Widget _buildBaudRateSelector(SerialProvider provider) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.speed, size: 20),
        const SizedBox(width: 6),
        if (!_useCustomBaud)
          DropdownButton<int>(
            value: _commonBaudRates.contains(provider.baudRate)
                ? provider.baudRate
                : _commonBaudRates[4], // default 115200
            items: _commonBaudRates.map((rate) {
              return DropdownMenuItem(value: rate, child: Text('$rate'));
            }).toList(),
            onChanged: provider.isConnected
                ? null
                : (value) {
                    if (value != null) provider.setBaudRate(value);
                  },
          )
        else
          SizedBox(
            width: 100,
            child: TextField(
              controller: _customBaudController,
              enabled: !provider.isConnected,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Custom',
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              ),
              onSubmitted: (value) {
                final baud = int.tryParse(value);
                if (baud != null && baud > 0) provider.setBaudRate(baud);
              },
            ),
          ),
        const SizedBox(width: 4),
        IconButton(
          icon: Icon(_useCustomBaud ? Icons.list : Icons.edit, size: 20),
          onPressed: provider.isConnected
              ? null
              : () {
                  setState(() {
                    _useCustomBaud = !_useCustomBaud;
                    if (_useCustomBaud) {
                      _customBaudController.text = provider.baudRate.toString();
                    }
                  });
                },
          tooltip: _useCustomBaud ? 'Use preset' : 'Custom baud',
        ),
      ],
    );
  }

  Widget _buildConnectionButton(SerialProvider provider) {
    final isOpen = provider.isConnected;
    return ElevatedButton.icon(
      onPressed: () async {
        if (isOpen) {
          await provider.disconnect();
          _addLog('Port closed.');
        } else {
          if (_useCustomBaud) {
            final baud = int.tryParse(_customBaudController.text);
            if (baud != null && baud > 0) provider.setBaudRate(baud);
          }
          final ok = await provider.connect();
          if (ok) {
            _addLog('Port opened at ${provider.baudRate} baud.');
          } else {
            _addLog('ERROR: Failed to open port.');
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Failed to open port. Check permissions.'),
                  backgroundColor: Colors.red,
                ),
              );
            }
          }
        }
      },
      icon: Icon(isOpen ? Icons.link_off : Icons.link, size: 18),
      label: Text(isOpen ? 'Close' : 'Open'),
      style: ElevatedButton.styleFrom(
        backgroundColor: isOpen ? Colors.red.shade700 : Colors.green.shade700,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      ),
    );
  }

  Widget _buildStatusChip(SerialProvider provider) {
    final connected = provider.isConnected;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: connected
            ? Colors.green.withOpacity(0.15)
            : Colors.grey.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: connected ? Colors.green : Colors.grey,
          width: 1.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: connected ? Colors.green : Colors.grey,
              boxShadow: connected
                  ? [BoxShadow(color: Colors.green.withOpacity(0.5), blurRadius: 6)]
                  : null,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            connected ? 'Connected' : 'Disconnected',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: connected ? Colors.green.shade300 : Colors.grey,
            ),
          ),
        ],
      ),
    );
  }

  // ─── Section 2: Platform Selection ───

  Widget _buildPlatformSection() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.memory, size: 20),
          const SizedBox(width: 10),
          const Text('Platform:', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(width: 12),
          DropdownButton<String>(
            value: _selectedPlatform,
            underline: const SizedBox(),
            items: _platforms.map((p) {
              return DropdownMenuItem(value: p, child: Text(p));
            }).toList(),
            onChanged: (value) {
              if (value != null) {
                setState(() => _selectedPlatform = value);
                _addLog('Platform changed to $value');
                _refreshFirmwareList();
              }
            },
          ),
        ],
      ),
    );
  }

  // ─── Section 3: Firmware Selection (with drag & drop) ───

  Widget _buildFirmwareSection() {
    return DragTarget<Object>(
      onWillAcceptWithDetails: (_) {
        setState(() => _isDragOver = true);
        return true;
      },
      onLeave: (_) => setState(() => _isDragOver = false),
      onAcceptWithDetails: (details) {
        setState(() {
          _isDragOver = false;
          _customFirmwarePath = 'dropped_firmware.bin';
          _selectedFirmware = '(none)';
        });
        _addLog('Firmware dropped: dropped_firmware.bin (placeholder)');
      },
      builder: (context, candidateData, rejectedData) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _isDragOver
                ? Colors.deepOrange.withOpacity(0.15)
                : Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            border: _isDragOver
                ? Border.all(color: Colors.deepOrange, width: 2)
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _isDragOver ? Icons.file_download : Icons.sd_storage,
                size: 20,
                color: _isDragOver ? Colors.deepOrange : null,
              ),
              const SizedBox(width: 10),
              Text(
                _isDragOver ? 'Drop file here' : 'Firmware:',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: _isDragOver ? Colors.deepOrange : null,
                ),
              ),
              if (!_isDragOver) ...[
                const SizedBox(width: 12),
                DropdownButton<String>(
                  value: _selectedFirmware,
                  underline: const SizedBox(),
                  items: _availableFirmwares.map((f) {
                    return DropdownMenuItem(value: f, child: Text(f));
                  }).toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setState(() {
                        _selectedFirmware = value;
                        _customFirmwarePath = null;
                      });
                      _addLog('Firmware selected: $value');
                    }
                  },
                ),
                if (_customFirmwarePath != null) ...[
                  const SizedBox(width: 8),
                  Tooltip(
                    message: _customFirmwarePath!,
                    child: Chip(
                      label: Text(
                        _customFirmwarePath!,
                        style: const TextStyle(fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                      deleteIcon: const Icon(Icons.close, size: 16),
                      onDeleted: () {
                        setState(() => _customFirmwarePath = null);
                        _addLog('Custom firmware cleared.');
                      },
                    ),
                  ),
                ],
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () {
                    // Placeholder — will integrate file_picker later
                    setState(() {
                      _customFirmwarePath = 'custom_firmware.bin';
                      _selectedFirmware = '(none)';
                    });
                    _addLog('Open firmware file: custom_firmware.bin (placeholder)');
                  },
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('Open'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  ),
                ),
                const SizedBox(width: 6),
                ElevatedButton.icon(
                  onPressed: () async {
                    final result = await DownloadDialog.show(
                      context,
                      platform: _selectedPlatform,
                      storage: _storage,
                    );
                    if (result != null) {
                      _addLog('Downloaded: ${result.fileName}');
                      await _refreshFirmwareList();
                      // Auto-select the newly downloaded firmware
                      if (mounted && _availableFirmwares.contains(result.fileName)) {
                        setState(() {
                          _selectedFirmware = result.fileName;
                          _customFirmwarePath = null;
                        });
                      }
                    }
                  },
                  icon: const Icon(Icons.cloud_download, size: 18),
                  label: const Text('Download'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  // ─── Action Buttons ───

  Widget _buildActionButtons() {
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: [
        _buildActionButton(
          icon: Icons.sync,
          label: 'Backup & Flash',
          color: Colors.deepOrange,
          onPressed: () {
            _addLog('=== Starting Backup & Flash ===');
            _addLog('Platform: $_selectedPlatform');
            _addLog('Firmware: ${_customFirmwarePath ?? _selectedFirmware}');
            _simulateProgress();
          },
        ),
        _buildActionButton(
          icon: Icons.download,
          label: 'Backup (Read) Only',
          color: Colors.blue,
          onPressed: () {
            _addLog('=== Starting Backup (Read) ===');
            _addLog('Platform: $_selectedPlatform');
            _simulateProgress();
          },
        ),
        _buildActionButton(
          icon: Icons.upload,
          label: 'Write Firmware',
          color: Colors.teal,
          onPressed: () {
            _addLog('=== Starting Firmware Write ===');
            _addLog('Platform: $_selectedPlatform');
            _addLog('Firmware: ${_customFirmwarePath ?? _selectedFirmware}');
            _simulateProgress();
          },
        ),
        _buildActionButton(
          icon: Icons.verified,
          label: 'Verify',
          color: Colors.indigo,
          onPressed: () {
            _addLog('=== Starting Verify ===');
            _addLog('Platform: $_selectedPlatform');
            _simulateProgress();
          },
        ),
        _buildActionButton(
          icon: Icons.delete_forever,
          label: 'Erase',
          color: Colors.red.shade700,
          onPressed: () {
            _addLog('=== Starting Erase ===');
            _addLog('Platform: $_selectedPlatform');
            _simulateProgress();
          },
        ),
      ],
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        elevation: 3,
      ),
    );
  }

  void _simulateProgress() {
    setState(() => _progress = 0.0);
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _progress = 0.15);
      _addLog('Connecting...');
    });
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _progress = 0.35);
      _addLog('Reading device info...');
    });
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _progress = 0.65);
      _addLog('Processing...');
    });
    Future.delayed(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => _progress = 1.0);
      _addLog('Done (placeholder simulation).');
    });
  }

  // ─── Progress Bar ───

  Widget _buildProgressBar() {
    final pct = (_progress * 100).toInt();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text('Progress:', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const Spacer(),
            Text('$pct%', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: _progress,
            minHeight: 14,
            backgroundColor: Colors.grey.shade800,
            valueColor: AlwaysStoppedAnimation<Color>(
              _progress >= 1.0 ? Colors.green : Colors.deepOrange,
            ),
          ),
        ),
      ],
    );
  }

  // ─── Log Field ───

  Widget _buildLogField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Log toolbar
        Row(
          children: [
            const Icon(Icons.terminal, size: 16, color: Colors.grey),
            const SizedBox(width: 6),
            const Text('Log', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.copy, size: 18),
              onPressed: _logLines.isEmpty
                  ? null
                  : () {
                      Clipboard.setData(ClipboardData(text: _logLines.join('\n')));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Log copied to clipboard'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
              tooltip: 'Copy log to clipboard',
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              icon: const Icon(Icons.save_alt, size: 18),
              onPressed: _logLines.isEmpty
                  ? null
                  : () {
                      // Placeholder — will integrate file save / download later
                      _addLog('Save log... (placeholder)');
                    },
              tooltip: 'Save log to file',
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              icon: const Icon(Icons.delete_sweep, size: 18),
              onPressed: _logLines.isEmpty
                  ? null
                  : () => setState(() => _logLines.clear()),
              tooltip: 'Clear log',
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        const SizedBox(height: 4),
        // Log body
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.grey.shade700),
            ),
            child: _logLines.isEmpty
                ? const Center(
                    child: Text(
                      'Log output will appear here.',
                      style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic),
                    ),
                  )
                : ListView.builder(
                    controller: _logScrollController,
                    padding: const EdgeInsets.all(10),
                    itemCount: _logLines.length,
                    itemBuilder: (context, index) {
                      return Text(
                        _logLines[index],
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: Colors.greenAccent,
                          height: 1.5,
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}
