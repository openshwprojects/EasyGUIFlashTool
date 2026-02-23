/// Minimal async XMODEM-1K sender, ported from C# `Xmodem.cs`.
///
/// Only the **sender** side is implemented — this is all WMFlasher needs.
/// Uses [SerialTransport] for cross-platform serial I/O.
library;

import 'dart:async';
import 'dart:typed_data';

import '../serial/serial_transport.dart';
import 'crc.dart';

// ─── XMODEM protocol bytes ─────────────────────────────────────────────────

const int _stx = 0x02; // 1024-byte packet header
const int _ack = 0x06;
const int _nak = 0x15;
const int _can = 0x18;
const int _eot = 0x04;
const int _charC = 0x43; // 'C' — CRC-mode initiation

/// Progress callback: (bytesSent, totalBytes, blockNum, fileOffset).
typedef XmodemProgressCallback = void Function(
    int bytesSent, int totalBytes, int blockNum, int offset);

// ─── XmodemSender ──────────────────────────────────────────────────────────

/// Async XMODEM-1K sender over [SerialTransport].
///
/// Sends data in 1024-byte packets with CRC-16/XMODEM error checking.
/// The receiver must initiate transfer by sending `'C'`.
class XmodemSender {
  final SerialTransport _transport;
  final List<int> _rxBuf = [];
  StreamSubscription<Uint8List>? _rxSub;

  // ── Configurable parameters (match C# defaults) ─────────────────────

  /// Max retries per packet before aborting.
  int maxRetries = 5;

  /// Timeout waiting for receiver initiation (ms).
  int initiationTimeoutMs = 5000;

  /// Timeout waiting for ACK/NAK after a packet (ms).
  int packetResponseTimeoutMs = 15000;

  /// Inactivity timeout — abort if receiver goes completely silent (ms).
  int inactivityTimeoutMs = 5000;

  /// Padding byte (0xFF for WM flasher).
  int paddingByte = 0xFF;

  /// Optional progress callback.
  XmodemProgressCallback? onPacketSent;

  XmodemSender(this._transport);

  // ── Low-level helpers ───────────────────────────────────────────────

  void _startListening() {
    _rxBuf.clear();
    _rxSub?.cancel();
    _rxSub = _transport.stream.listen((data) {
      _rxBuf.addAll(data);
    });
  }

  Future<void> _stopListening() async {
    await _rxSub?.cancel();
    _rxSub = null;
  }

  /// Wait for at least one byte within [timeoutMs]. Returns -1 on timeout.
  Future<int> _readByte(int timeoutMs) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (DateTime.now().isBefore(deadline)) {
      if (_rxBuf.isNotEmpty) {
        return _rxBuf.removeAt(0);
      }
      await Future.delayed(const Duration(milliseconds: 1));
    }
    return -1;
  }

  Future<void> _writeByte(int b) async {
    await _transport.write(Uint8List.fromList([b]));
  }

  Future<void> _writeBytes(Uint8List data) async {
    await _transport.write(data);
  }

  // ── Public API ──────────────────────────────────────────────────────

  /// Send [data] via XMODEM-1K.
  ///
  /// Returns the number of user data bytes successfully sent,
  /// or 0 on failure / cancellation.
  Future<int> send(Uint8List data) async {
    _startListening();
    try {
      return await _sendInternal(data);
    } finally {
      await _stopListening();
    }
  }

  Future<int> _sendInternal(Uint8List data) async {
    // ── Wait for receiver initiation ('C' or NAK) ───────────────────
    bool useCRC = true;
    final initByte = await _readByte(initiationTimeoutMs);
    if (initByte == _charC) {
      useCRC = true;
    } else if (initByte == _nak) {
      useCRC = false; // checksum mode fallback
    } else {
      return 0; // timeout or unexpected byte
    }

    // ── Send packets ────────────────────────────────────────────────
    const int packetSize = 1024;
    int blockNum = 1;
    int offset = 0;
    int totalSent = 0;

    // Pre-allocate packet buffer: header(1) + blk(1) + ~blk(1) + data(1024) + check(2)
    const packetLen = 3 + packetSize + 2;
    final packet = Uint8List(packetLen);

    while (offset < data.length) {
      // Fill data portion with padding
      const dataStart = 3;
      for (int i = 0; i < packetSize; i++) {
        packet[dataStart + i] =
            (offset + i < data.length) ? data[offset + i] : paddingByte;
      }

      // Build header
      packet[0] = _stx; // 1024-byte packet
      packet[1] = blockNum & 0xFF;
      packet[2] = (255 - blockNum) & 0xFF;

      // Compute check value
      if (useCRC) {
        final crc = CRC16.compute(
            CRC16Type.xmodem, packet, 3, packetSize);
        packet[3 + packetSize] = (crc >> 8) & 0xFF;
        packet[3 + packetSize + 1] = crc & 0xFF;
      } else {
        int sum = 0;
        for (int i = 0; i < packetSize; i++) {
          sum += packet[dataStart + i];
        }
        packet[3 + packetSize] = sum & 0xFF;
        // checksum mode: only 1 byte, but we still send the full buffer;
        // the extra byte is ignored by receiver
      }

      // Transmit with retries
      bool acked = false;
      for (int retry = 0; retry < maxRetries && !acked; retry++) {
        _rxBuf.clear();
        final sendLen = useCRC ? packet.length : packet.length - 1;
        await _writeBytes(Uint8List.sublistView(packet, 0, sendLen));

        final resp = await _readByte(packetResponseTimeoutMs);
        if (resp == _ack) {
          acked = true;
        } else if (resp == _can) {
          return 0; // receiver cancelled
        }
        // NAK or timeout → retry
      }

      if (!acked) return 0; // too many retries

      final chunkSent = (offset + packetSize <= data.length)
          ? packetSize
          : data.length - offset;
      totalSent += chunkSent;
      offset += packetSize;
      blockNum = (blockNum + 1) & 0xFF;

      onPacketSent?.call(totalSent, data.length, blockNum, offset);
    }

    // ── Send EOT ────────────────────────────────────────────────────
    for (int i = 0; i < maxRetries; i++) {
      await _writeByte(_eot);
      final resp = await _readByte(packetResponseTimeoutMs);
      if (resp == _ack) {
        return totalSent;
      }
    }

    return totalSent; // EOT not ACKed but data was sent
  }
}
