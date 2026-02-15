enum MessageDirection { sent, received, system }

class UartMessage {
  final String content;
  final DateTime timestamp;
  final MessageDirection direction;

  UartMessage({
    required this.content,
    required this.timestamp,
    required this.direction,
  });

  bool get isSent => direction == MessageDirection.sent;
  bool get isReceived => direction == MessageDirection.received;
  bool get isSystem => direction == MessageDirection.system;
}
