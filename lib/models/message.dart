// lib/models/message.dart

/// A single chat message — mirrors Python's add_message() parameters.
class ChatMessage {
  final String sender;
  final String text;
  final DateTime timestamp;

  /// True for messages sent by the local user.
  final bool isOwn;

  /// True when sent to all peers (BROADCAST).
  final bool isBroadcast;

  /// True for system/temp notifications (equivalent to show_temp_message).
  final bool isSystem;

  /// UID of the peer this message belongs to.
  /// Incoming: sender uid. Outgoing: target uid. Empty for broadcast/system.
  final String peerId;

  const ChatMessage({
    required this.sender,
    required this.text,
    required this.timestamp,
    this.isOwn = false,
    this.isBroadcast = false,
    this.isSystem = false,
    this.peerId = '',
  });

  /// HH:MM — matches Python's datetime.now().strftime('%H:%M').
  String get formattedTime {
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}