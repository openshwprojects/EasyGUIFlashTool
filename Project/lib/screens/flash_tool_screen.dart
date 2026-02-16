import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'dart:io' show Platform;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/serial_provider.dart';
import '../services/firmware_storage.dart';
import '../services/file_saver.dart';
import '../widgets/download_dialog.dart';
import '../models/chip_platform.dart';
import '../constants.dart';
import '../flasher/bk7231_flasher.dart';
import '../flasher/base_flasher.dart';
import 'package:desktop_drop/desktop_drop.dart';
import '../services/file_opener.dart';

class FlashToolScreen extends StatefulWidget {
  const FlashToolScreen({super.key});

  @override
  State<FlashToolScreen> createState() => _FlashToolScreenState();
}

class _FlashToolScreenState extends State<FlashToolScreen> {
  final ScrollController _logScrollController = ScrollController();
  String _statusMessage = '';
  final TextEditingController _customBaudController = TextEditingController();

  final List<int> _commonBaudRates = kCommonBaudRates;
  bool _useCustomBaud = false;

  // --- GUI-layer state (not in provider) ---
  final List<String> _logLines = [];
  double _progress = 0.0;
  ChipPlatform _selectedPlatform = ChipPlatform.bk7231t;
  String _selectedFirmware = '(none)';
  String? _customFirmwarePath;
  bool _isDragOver = false;
  bool _flasherRunning = false;
  bool _hasError = false;

  // Firmware storage service (shared singleton)
  final FirmwareStorage _storage = FirmwareStorage();

  // Dynamic firmware list loaded from disk
  List<String> _availableFirmwares = ['(none)'];

  @override
  void initState() {
    super.initState();
    _restoreSettings();
  }

  Future<void> _restoreSettings() async {
    final prefs = await SharedPreferences.getInstance();
    
    // 1. Restore Platform
    final savedPlatformName = prefs.getString('ui_platform');
    if (savedPlatformName != null) {
      try {
        // Match enum by name, e.g. "bk7231t"
        final p = ChipPlatform.values.firstWhere((e) => e.name == savedPlatformName);
        if (mounted) {
          setState(() => _selectedPlatform = p);
        }
      } catch (_) {
        // Saved platform invalid or changed, ignore
      }
    }

    // 2. Refresh firmware list for the selected platform
    await _refreshFirmwareList();

    // 3. Restore Firmware Selection
    final savedFirmware = prefs.getString('ui_firmware');
    if (savedFirmware != null && mounted) {
      // Only select if it's still available in the list
      if (_availableFirmwares.contains(savedFirmware)) {
        setState(() => _selectedFirmware = savedFirmware);
      }
    }
  }

  Future<void> _saveUiSetting(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }

  @override
  void dispose() {
    _logScrollController.dispose();
    _customBaudController.dispose();
    super.dispose();
  }

  /// Reload the firmware dropdown from disk (or in-memory on web).
  Future<void> _refreshFirmwareList() async {
    final prefix = _selectedPlatform.firmwarePrefix;
    final files = await _storage.listFiles(kFirmwareStorageSubdir, prefix: prefix);
    if (mounted) {
      setState(() {
        _availableFirmwares = ['(none)', ...files];
        // Keep current selection if still valid, else reset
        if (!_availableFirmwares.contains(_selectedFirmware)) {
          _selectedFirmware = '(none)';
        }
      });
    }
    
    // Auto-select last downloaded logic (fallback if no stored UI setting was effectively used)
    // We check if current selection is none AND custom is null
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
        return IgnorePointer(
          ignoring: _flasherRunning,
          child: AnimatedOpacity(
            opacity: _flasherRunning ? 0.4 : 1.0,
            duration: const Duration(milliseconds: 250),
            child: Container(
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
            ),
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
          DropdownButton<ChipPlatform>(
            value: _selectedPlatform,
            underline: const SizedBox(),
            items: ChipPlatform.values.map((p) {
              return DropdownMenuItem(value: p, child: Text(p.displayName));
            }).toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() => _selectedPlatform = value);
                  _saveUiSetting('ui_platform', value.name);
                  _addLog('Platform changed to ${value.displayName}');
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
    return DropTarget(
      onDragEntered: (_) => setState(() => _isDragOver = true),
      onDragExited: (_) => setState(() => _isDragOver = false),
      onDragDone: (details) async {
        setState(() => _isDragOver = false);
        if (details.files.isEmpty) return;
        final droppedFile = details.files.first;
        final fileName = droppedFile.name;
        if (!fileName.toLowerCase().endsWith('.bin') &&
            !fileName.toLowerCase().endsWith('.rbl')) {
          _addLog('WARNING: Dropped file "$fileName" is not a .bin/.rbl — ignoring.');
          return;
        }
        _addLog('Reading dropped file: $fileName ...');
        try {
          final bytes = await droppedFile.readAsBytes();
          _addLog('Dropped file size: ${bytes.length} bytes');
          await _storage.saveFile(kFirmwareStorageSubdir, fileName, bytes);
          _addLog('Saved dropped firmware: $fileName');
          await _refreshFirmwareList();
          if (mounted && _availableFirmwares.contains(fileName)) {
            setState(() {
              _selectedFirmware = fileName;
              _customFirmwarePath = null;
            });
            _saveUiSetting('ui_firmware', fileName);
          }
        } catch (e) {
          _addLog('ERROR reading dropped file: $e');
        }
      },
      child: AnimatedContainer(
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
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
                        _saveUiSetting('ui_firmware', value);
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
                    onPressed: () async {
                      try {
                        final result = await pickFirmwareFile();
                        if (result == null) return;
                        final fileName = result.name;
                        final bytes = result.bytes;
                        if (bytes.isEmpty) {
                          _addLog('ERROR: File "$fileName" is empty.');
                          return;
                        }
                        _addLog('Opened file: $fileName (${bytes.length} bytes)');
                        await _storage.saveFile(kFirmwareStorageSubdir, fileName, bytes);
                        _addLog('Saved firmware: $fileName');
                        await _refreshFirmwareList();
                        if (mounted && _availableFirmwares.contains(fileName)) {
                          setState(() {
                            _selectedFirmware = fileName;
                            _customFirmwarePath = null;
                          });
                          _saveUiSetting('ui_firmware', fileName);
                        }
                      } catch (e) {
                        _addLog('ERROR opening file: $e');
                      }
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
                          _saveUiSetting('ui_firmware', result.fileName);
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
            const SizedBox(height: 1),
            Text(
              'You can also drag and drop a .bin file here.',
              style: TextStyle(
                fontSize: 10,
                fontStyle: FontStyle.italic,
                height: 1.0,
                color: _isDragOver
                    ? Colors.deepOrange.withOpacity(0.8)
                    : Colors.grey.shade500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Action Buttons ───

  // ── Flasher integration helpers ──────────────────────────────────────

  BK7231Flasher? _currentFlasher;

  // ── Flasher integration helpers ──────────────────────────────────────

  void _createFlasher() {
    final provider = context.read<SerialProvider>();
    final bkType = _selectedPlatform.bkType;
    if (bkType == null) {
      _addLog('ERROR: ${_selectedPlatform.displayName} is not a BK-family chip — flasher not available.');
      return;
    }
    _currentFlasher = BK7231Flasher(
      transport: provider.transport,
      chipType: bkType,
      baudrate: provider.baudRate,
    );
    // Wire logging callbacks
    _currentFlasher!.onLog = (msg, level) {
      if (mounted) {
        _addLog(msg.trimRight());
        if (level == LogLevel.error && !_hasError) {
          setState(() => _hasError = true);
        }
      }
    };
    _currentFlasher!.onProgress = (current, total) {
      if (mounted) setState(() => _progress = total > 0 ? current / total : 0);
    };
    _currentFlasher!.onState = (msg) {
      if (mounted) setState(() => _statusMessage = msg);
    };
  }

  Future<void> _stopOperation() async {
    if (_currentFlasher != null) {
      _addLog('Stopping operation...');
      _currentFlasher!.isCancelled = true;
      // We don't close the port here immediately to allow the loop to exit gracefully
      // but if needed we could force it. The finally block in the runner will close it.
    }
  }

  Future<bool> _ensurePortOpen() async {
    final provider = context.read<SerialProvider>();
    if (provider.isConnected) return true;

    _addLog('Port not open. Attempting to open...');
    // This usually triggers permission prompt on supported platforms
    final ok = await provider.connect();
    if (!ok) {
      _addLog('ERROR: Failed to open port. Operation aborted.');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please allow port permission to continue.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
    return ok;
  }

  Future<void> _runFlasherRead({bool fullRead = false}) async {
    if (_flasherRunning) {
      _addLog('A flasher operation is already running.');
      return;
    }
    
    if (!await _ensurePortOpen()) return;

    _createFlasher();
    if (_currentFlasher == null) return;
    
    setState(() {
      _flasherRunning = true;
      _progress = 0;
      _hasError = false;
    });

    try {
      await _currentFlasher!.doRead(startSector: 0, sectors: 0x200000 ~/ 0x1000, fullRead: fullRead);
      final result = _currentFlasher!.getReadResult();
      if (result != null) {
        _addLog('Read complete: ${result.length} bytes');
        final now = DateTime.now();
        final timestamp = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
        final filename = 'read_result_$timestamp.bin';
        await saveFile(filename, result);
        _addLog('File saved/downloaded: $filename');
      } else {
        _addLog('Read failed or was cancelled.');
      }
    } catch (e) {
      _addLog('Exception during read: $e');
    } finally {
      await _cleanupFlasher();
    }
  }

  Future<void> _runFlasherErase() async {
    if (_flasherRunning) {
      _addLog('A flasher operation is already running.');
      return;
    }
    
    if (!await _ensurePortOpen()) return;

    _createFlasher();
    if (_currentFlasher == null) return;

    setState(() {
      _flasherRunning = true;
      _progress = 0;
      _hasError = false;
    });

    try {
      final ok = await _currentFlasher!.doErase(startSector: 0, sectors: 0x200000 ~/ 0x1000, eraseAll: true);
      _addLog(ok ? 'Erase complete!' : 'Erase failed or was cancelled.');
    } catch (e) {
      _addLog('Exception during erase: $e');
    } finally {
      await _cleanupFlasher();
    }
  }

  Future<void> _runFlasherWrite() async {
    if (_flasherRunning) {
      _addLog('A flasher operation is already running.');
      return;
    }
    
    if (!await _ensurePortOpen()) return;

    // Load firmware bytes
    if (_selectedFirmware == '(none)' && _customFirmwarePath == null) {
      _addLog('ERROR: No firmware selected. Please select or download a firmware first.');
      return;
    }
    final fwName = _customFirmwarePath ?? _selectedFirmware;
    _addLog('Loading firmware: $fwName ...');
    final firmwareData = await _storage.readFile(kFirmwareStorageSubdir, fwName);
    if (firmwareData == null || firmwareData.isEmpty) {
      _addLog('ERROR: Could not read firmware file "$fwName".');
      return;
    }
    _addLog('Firmware loaded: ${firmwareData.length} bytes');

    _createFlasher();
    if (_currentFlasher == null) return;

    setState(() {
      _flasherRunning = true;
      _progress = 0;
      _hasError = false;
    });

    try {
      await _currentFlasher!.doWrite(0, firmwareData);
      _addLog('Write operation finished.');
    } catch (e) {
      _addLog('Exception during write: $e');
    } finally {
      await _cleanupFlasher();
    }
  }

  Future<void> _runFlasherVerify() async {
    if (_flasherRunning) {
      _addLog('A flasher operation is already running.');
      return;
    }
    
    if (!await _ensurePortOpen()) return;

    // Load firmware bytes (same as _runFlasherWrite)
    if (_selectedFirmware == '(none)' && _customFirmwarePath == null) {
      _addLog('ERROR: No firmware selected. Please select or download a firmware first.');
      return;
    }
    final fwName = _customFirmwarePath ?? _selectedFirmware;
    _addLog('Loading firmware: $fwName ...');
    final firmwareData = await _storage.readFile(kFirmwareStorageSubdir, fwName);
    if (firmwareData == null || firmwareData.isEmpty) {
      _addLog('ERROR: Could not read firmware file "$fwName".');
      return;
    }
    _addLog('Firmware loaded: ${firmwareData.length} bytes');

    // Round up to sector boundary (4K = 0x1000)
    final sectors = (firmwareData.length + 0xFFF) ~/ 0x1000;
    _addLog('Will read $sectors sectors (${sectors * 0x1000} bytes) from device for verification...');

    _createFlasher();
    if (_currentFlasher == null) return;

    setState(() {
      _flasherRunning = true;
      _progress = 0;
      _hasError = false;
    });

    try {
      await _currentFlasher!.doRead(startSector: 0, sectors: sectors);
      final readData = _currentFlasher!.getReadResult();
      if (readData == null) {
        _addLog('Read failed or was cancelled — verify aborted.');
        return;
      }

      // Compare only up to firmware file length
      bool match = true;
      int mismatchOffset = -1;
      for (int i = 0; i < firmwareData.length; i++) {
        if (i >= readData.length || readData[i] != firmwareData[i]) {
          match = false;
          mismatchOffset = i;
          break;
        }
      }

      if (match) {
        _addLog('VERIFY OK — flash contents match firmware file (${firmwareData.length} bytes).');
      } else {
        final hex = '0x${mismatchOffset.toRadixString(16).toUpperCase()}';
        final expected = mismatchOffset < firmwareData.length
            ? '0x${firmwareData[mismatchOffset].toRadixString(16).toUpperCase().padLeft(2, '0')}'
            : 'N/A';
        final actual = mismatchOffset < readData.length
            ? '0x${readData[mismatchOffset].toRadixString(16).toUpperCase().padLeft(2, '0')}'
            : 'N/A';
        _addLog('VERIFY FAILED — first mismatch at offset $hex (expected $expected, got $actual).');
      }
    } catch (e) {
      _addLog('Exception during verify: $e');
    } finally {
      await _cleanupFlasher();
    }
  }
  
  Future<void> _cleanupFlasher() async {
    if (_currentFlasher != null) {
      await _currentFlasher!.closePort();
      _currentFlasher!.dispose();
      _currentFlasher = null;
    }
    
    // Sync SerialProvider state because Flasher closed the underlying transport
    if (mounted) {
      final provider = context.read<SerialProvider>();
      if (provider.isConnected) {
        await provider.disconnect();
      }
      
      setState(() {
        _flasherRunning = false;
        if (!_hasError) _statusMessage = '';
      });
    }
  }

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
          onPressed: _flasherRunning
              ? null
              : () {
                  _addLog('=== Starting Backup & Flash ===');
                  _addLog('Platform: $_selectedPlatform');
                  _addLog('Firmware: ${_customFirmwarePath ?? _selectedFirmware}');
                  _runFlasherRead(fullRead: true);
                },
        ),
        _buildActionButton(
          icon: Icons.download,
          label: 'Backup (Read) Only',
          color: Colors.blue,
          onPressed: _flasherRunning
              ? null
              : () {
                  _addLog('=== Starting Backup (Read) ===');
                  _addLog('Platform: $_selectedPlatform');
                  _runFlasherRead(fullRead: true);
                },
        ),
        _buildActionButton(
          icon: Icons.upload,
          label: 'Write Firmware',
          color: Colors.teal,
          onPressed: _flasherRunning
              ? null
              : () {
                  _addLog('=== Starting Firmware Write ===');
                  _addLog('Platform: $_selectedPlatform');
                  _addLog('Firmware: ${_customFirmwarePath ?? _selectedFirmware}');
                  _runFlasherWrite();
                },
        ),
        _buildActionButton(
          icon: Icons.verified,
          label: 'Verify',
          color: Colors.indigo,
          onPressed: _flasherRunning
              ? null
              : () {
                  _addLog('=== Starting Verify ===');
                  _addLog('Platform: $_selectedPlatform');
                  _addLog('Firmware: ${_customFirmwarePath ?? _selectedFirmware}');
                  _runFlasherVerify();
                },
        ),
        _buildActionButton(
          icon: Icons.delete_forever,
          label: 'Erase',
          color: Colors.red.shade700,
          onPressed: _flasherRunning
              ? null
              : () {
                  _addLog('=== Starting Erase ===');
                  _addLog('Platform: $_selectedPlatform');
                  _runFlasherErase();
                },
        ),
        if (_flasherRunning)
          _buildActionButton(
            icon: Icons.stop_circle,
            label: 'STOP',
            color: Colors.red.shade900,
            onPressed: _stopOperation,
          ),
      ],
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback? onPressed,
  }) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        disabledBackgroundColor: color.withOpacity(0.3),
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white.withOpacity(0.5),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        elevation: onPressed != null ? 3 : 0,
      ),
    );
  }

  // ─── Progress Bar ───

  Widget _buildProgressBar() {
    final pct = (_progress * 100).toInt();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _statusMessage.isNotEmpty ? _statusMessage : 'Progress:', 
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  fontFamily: 'monospace',
                  color: _hasError ? Colors.red.shade300 : null,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text('$pct%', style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 13,
              color: _hasError ? Colors.red.shade300 : null,
            )),
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
              _hasError ? Colors.red : (_progress >= 1.0 ? Colors.green : Colors.deepOrange),
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
