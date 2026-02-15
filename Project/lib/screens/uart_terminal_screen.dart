import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io' show Platform;
import 'package:provider/provider.dart';
import '../providers/serial_provider.dart';
import '../models/uart_message.dart';

class UartTerminalScreen extends StatefulWidget {
  const UartTerminalScreen({super.key});

  @override
  State<UartTerminalScreen> createState() => _UartTerminalScreenState();
}

class _UartTerminalScreenState extends State<UartTerminalScreen> {
  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _customBaudController = TextEditingController();
  final TextEditingController _filterController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _messageFocusNode = FocusNode();
  String _filterText = '';
  
  final List<int> _commonBaudRates = [9600, 19200, 38400, 57600, 115200];
  bool _useCustomBaud = false;

  @override
  void dispose() {
    _messageController.dispose();
    _customBaudController.dispose();
    _filterController.dispose();
    _scrollController.dispose();
    _messageFocusNode.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    final provider = context.read<SerialProvider>();
    provider.sendMessage(text);
    _messageController.clear();
    _scrollToBottom();
    _messageFocusNode.requestFocus();
  }

  bool _isDesktop() {
    if (kIsWeb) return false;
    return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('UART Terminal'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            onPressed: () {
              context.read<SerialProvider>().clearMessages();
            },
            tooltip: 'Clear messages',
          ),
        ],
      ),
      body: Column(
        children: [
          // Top control bar (includes filter)
          _buildControlBar(),
          
          const Divider(height: 1),
          
          // Message log
          Expanded(
            child: _buildMessageLog(),
          ),
          
          const Divider(height: 1),
          
          // Input area
          _buildInputArea(),
        ],
      ),
    );
  }

  Widget _buildControlBar() {
    return Consumer<SerialProvider>(
      builder: (context, provider, _) {
        return Container(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // Port selection (Desktop only)
              if (_isDesktop()) _buildPortSelector(provider),
              
              // Baud rate selection
              _buildBaudRateSelector(provider),
              
              // Connect/Disconnect button
              _buildConnectionButton(provider),
              
              // DTR/RTS toggle buttons
              _buildSignalToggle('DTR', provider.dtr, provider.isConnected, provider.toggleDTR),
              _buildSignalToggle('RTS', provider.rts, provider.isConnected, provider.toggleRTS),
              
              // Status indicator
              _buildStatusIndicator(provider),
              
              // Filter
              _buildFilterField(provider),
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
            icon: const Icon(Icons.refresh),
            onPressed: provider.refreshPorts,
            tooltip: 'Refresh ports',
          ),
        ],
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DropdownButton<String>(
          value: provider.selectedPort != null && ports.contains(provider.selectedPort)
              ? provider.selectedPort
              : ports.first,
          hint: const Text('Select Port'),
          items: ports.map((port) {
            return DropdownMenuItem(
              value: port,
              child: Text(port),
            );
          }).toList(),
          onChanged: provider.isConnected
              ? null
              : (value) {
                  if (value != null) {
                    provider.setPort(value);
                  }
                },
        ),
        IconButton(
          icon: const Icon(Icons.refresh),
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
        if (!_useCustomBaud)
          DropdownButton<int>(
            value: _commonBaudRates.contains(provider.baudRate)
                ? provider.baudRate
                : _commonBaudRates.last,
            items: _commonBaudRates.map((rate) {
              return DropdownMenuItem(
                value: rate,
                child: Text('$rate'),
              );
            }).toList(),
            onChanged: provider.isConnected
                ? null
                : (value) {
                    if (value != null) {
                      provider.setBaudRate(value);
                    }
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
                final baudRate = int.tryParse(value);
                if (baudRate != null && baudRate > 0) {
                  provider.setBaudRate(baudRate);
                }
              },
            ),
          ),
        const SizedBox(width: 4),
        IconButton(
          icon: Icon(_useCustomBaud ? Icons.list : Icons.edit),
          iconSize: 20,
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
    return ElevatedButton.icon(
      onPressed: () async {
        if (provider.isConnected) {
          await provider.disconnect();
        } else {
          // If using custom baud, apply it first
          if (_useCustomBaud) {
            final baudRate = int.tryParse(_customBaudController.text);
            if (baudRate != null && baudRate > 0) {
              provider.setBaudRate(baudRate);
            }
          }
          
          final success = await provider.connect();
          if (!success && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Failed to connect. Check port and permissions.'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      },
      icon: Icon(provider.isConnected ? Icons.link_off : Icons.link),
      label: Text(provider.isConnected ? 'Disconnect' : 'Connect'),
      style: ElevatedButton.styleFrom(
        backgroundColor: provider.isConnected ? Colors.red : Colors.green,
      ),
    );
  }

  Widget _buildSignalToggle(String label, bool isActive, bool isConnected, VoidCallback onToggle) {
    return OutlinedButton(
      onPressed: isConnected ? onToggle : null,
      style: OutlinedButton.styleFrom(
        backgroundColor: isActive ? Colors.orange : null,
        foregroundColor: isActive ? Colors.white : null,
        side: BorderSide(
          color: isConnected
              ? (isActive ? Colors.orange : Colors.grey)
              : Colors.grey.shade400,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        minimumSize: const Size(0, 36),
      ),
      child: Text(
        '$label: ${isActive ? "ON" : "OFF"}',
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildStatusIndicator(SerialProvider provider) {
    return Chip(
      avatar: CircleAvatar(
        backgroundColor: provider.isConnected ? Colors.green : Colors.grey,
        radius: 6,
      ),
      label: Text(
        provider.isConnected ? 'Connected' : 'Disconnected',
        style: const TextStyle(fontSize: 12),
      ),
    );
  }

  Widget _buildFilterField(SerialProvider provider) {
    final total = provider.messages.length;
    final filtered = _filterText.isEmpty
        ? total
        : provider.messages
            .where((m) => m.content.toLowerCase().contains(_filterText.toLowerCase()))
            .length;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 200,
          height: 36,
          child: TextField(
            controller: _filterController,
            decoration: InputDecoration(
              hintText: 'Filter...',
              prefixIcon: const Icon(Icons.search, size: 18),
              prefixIconConstraints: const BoxConstraints(minWidth: 36),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              suffixIcon: _filterText.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 16),
                      padding: EdgeInsets.zero,
                      onPressed: () {
                        _filterController.clear();
                        setState(() => _filterText = '');
                      },
                    )
                  : null,
            ),
            style: const TextStyle(fontSize: 13),
            onChanged: (value) {
              setState(() => _filterText = value);
            },
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '$filtered/$total',
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ],
    );
  }

  Widget _buildMessageLog() {
    return Consumer<SerialProvider>(
      builder: (context, provider, _) {
        if (provider.messages.isEmpty) {
          return const Center(
            child: Text(
              'No messages yet.\nConnect to a device and start communicating!',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
          );
        }

        final filtered = _filterText.isEmpty
            ? provider.messages
            : provider.messages
                .where((m) => m.content.toLowerCase().contains(_filterText.toLowerCase()))
                .toList();

        if (filtered.isEmpty) {
          return const Center(
            child: Text(
              'No messages match the filter.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
          );
        }

        // Auto-scroll when new messages arrive (only if not filtering)
        if (_filterText.isEmpty) {
          _scrollToBottom();
        }

        return ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.all(8),
          itemCount: filtered.length,
          itemBuilder: (context, index) {
            return _buildMessageBubble(filtered[index]);
          },
        );
      },
    );
  }

  Widget _buildMessageBubble(UartMessage message) {
    final isReceived = message.isReceived;
    final isSystem = message.isSystem;
    
    final Color color;
    final Alignment alignment;
    
    if (isSystem) {
      color = Colors.cyan.shade700;
      alignment = Alignment.center;
    } else if (isReceived) {
      color = Colors.green.shade700;
      alignment = Alignment.centerLeft;
    } else {
      color = Colors.yellow.shade700;
      alignment = Alignment.centerRight;
    }

    return Align(
      alignment: alignment,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message.content,
              style: const TextStyle(
                color: Colors.white,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _formatTimestamp(message.timestamp),
              style: TextStyle(
                color: Colors.white.withOpacity(0.7),
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTimestamp(DateTime timestamp) {
    return '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}:'
        '${timestamp.second.toString().padLeft(2, '0')}.'
        '${(timestamp.millisecond ~/ 10).toString().padLeft(2, '0')}';
  }

  Widget _buildInputArea() {
    final provider = context.read<SerialProvider>();
    final inputText = _messageController.text;
    final suggestions = inputText.trim().isNotEmpty
        ? provider.commandHistory.getSuggestions(inputText)
        : <String>[];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Suggestion chips — always present in tree to keep structure stable
        Container(
          width: double.infinity,
          padding: suggestions.isNotEmpty
              ? const EdgeInsets.symmetric(horizontal: 12, vertical: 4)
              : EdgeInsets.zero,
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: suggestions.map((cmd) {
              final freq = provider.commandHistory.getFrequency(cmd);
              return InputChip(
                label: Text(
                  '$cmd ($freq)',
                  style: const TextStyle(fontSize: 12),
                ),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
                deleteIcon: const Icon(Icons.close, size: 14),
                onDeleted: () async {
                  await provider.commandHistory.deleteCommand(cmd);
                  setState(() {});
                },
                onPressed: () {
                  _messageController.text = cmd;
                  _messageController.selection = TextSelection.fromPosition(
                    TextPosition(offset: cmd.length),
                  );
                  setState(() {});
                  _messageFocusNode.requestFocus();
                },
              );
            }).toList(),
          ),
        ),
        // Input row — only rebuilds when isConnected changes
        Selector<SerialProvider, bool>(
          selector: (_, p) => p.isConnected,
          builder: (context, isConnected, _) {
            return Container(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      focusNode: _messageFocusNode,
                      enabled: isConnected,
                      decoration: const InputDecoration(
                        hintText: 'Type message...',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    onPressed: isConnected ? _sendMessage : null,
                    icon: const Icon(Icons.send),
                    label: const Text('Send'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 16,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

