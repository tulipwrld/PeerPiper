// lib/p2p/p2p_service.dart
//
// Abstract service + stub implementation.
// RealP2PService (real_p2p_service.dart) is the production implementation.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../models/group.dart';
import '../models/message.dart';
import '../models/peer.dart';

class P2PLogEntry {
  final DateTime ts;
  final String text;
  final String peerId;

  const P2PLogEntry({
    required this.ts,
    required this.text,
    this.peerId = '',
  });

  String get hhmmss {
    final h = ts.hour.toString().padLeft(2, '0');
    final m = ts.minute.toString().padLeft(2, '0');
    final s = ts.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}

abstract class P2PService extends ChangeNotifier {
  String get myName;
  String? get myUid;
  String get myIp;
  bool get hasLocalAiHost;
  bool get isOnline;
  bool get isInitialized;

  Map<String, Peer> get peers;
  Set<String> get aiPeerIds;
  Map<String, ChatGroup> get groups;
  List<ChatMessage> get messages;
  List<P2PLogEntry> get logs;
  Map<String, List<P2PLogEntry>> get logsByPeer;

  Future<void> init({String password});
  Future<void> sendMessage(String targetUid, String text);
  Future<void> sendAiMessage(String targetUid, String text);
  Future<void> broadcastMessage(String text);
  Future<void> sendFile(String targetUid, String filename, Uint8List data);
  Future<void> sendGroupMessage(List<String> memberUids, String text);
  Future<void> sendGroupMessageToGroup(String groupId, String text);
  Future<ChatGroup> createGroup(String name, List<String> memberUids);
  Future<void> updateGroupMembers(String groupId, List<String> memberUids);
  Future<String?> exportLogsToTxt();
  void refreshPeers();
  void addLocalMessage(ChatMessage msg);

  // Change local display name and persist it.
  Future<void> setMyName(String name);
}

class P2PServiceStub extends P2PService {
  String _myName = 'MY_NODE';
  String _myIp = '—';
  bool _isOnline = false;
  bool _isInitialized = false;

  final Map<String, Peer> _peers = {};
  final Map<String, ChatGroup> _groups = {};
  final List<ChatMessage> _messages = [];
  final List<P2PLogEntry> _logs = [];
  final Map<String, List<dynamic>> _logsByPeer = {};

  @override
  String get myName => _myName;
  @override
  String? get myUid => null;
  @override
  String get myIp => _myIp;
  @override
  bool get hasLocalAiHost => false;
  @override
  bool get isOnline => _isOnline;
  @override
  bool get isInitialized => _isInitialized;
  @override
  Map<String, Peer> get peers => Map.unmodifiable(_peers);
  @override
  Set<String> get aiPeerIds => const <String>{};
  @override
  Map<String, ChatGroup> get groups => Map.unmodifiable(_groups);
  @override
  List<ChatMessage> get messages => List.unmodifiable(_messages);
  @override
  List<P2PLogEntry> get logs => List.unmodifiable(_logs);
  @override
  Map<String, List<P2PLogEntry>> get logsByPeer => Map.unmodifiable(
        {
          for (final e in _logsByPeer.entries)
            e.key: List<P2PLogEntry>.unmodifiable(
              e.value.whereType<P2PLogEntry>(),
            )
        },
      );

  @override
  Future<void> init({String password = 'default'}) async {
    await Future.delayed(const Duration(milliseconds: 600));

    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        if (iface.addresses.isNotEmpty) {
          _myIp = iface.addresses.first.address;
          break;
        }
      }
    } catch (_) {
      _myIp = '127.0.0.1';
    }

    _isOnline = true;
    _isInitialized = true;
    notifyListeners();
  }

  @override
  Future<void> sendMessage(String targetUid, String text) async {}

  @override
  Future<void> sendAiMessage(String targetUid, String text) async {}

  @override
  Future<void> broadcastMessage(String text) async {
    for (final uid in _peers.keys) {
      await sendMessage(uid, text);
    }
  }

  @override
  Future<void> sendFile(String targetUid, String filename, Uint8List data) async {}

  @override
  Future<void> sendGroupMessage(List<String> memberUids, String text) async {}
  @override
  Future<void> sendGroupMessageToGroup(String groupId, String text) async {}
  @override
  Future<ChatGroup> createGroup(String name, List<String> memberUids) async {
    throw UnimplementedError();
  }
  @override
  Future<void> updateGroupMembers(String groupId, List<String> memberUids) async {}
  @override
  Future<String?> exportLogsToTxt() async => null;

  @override
  void refreshPeers() => notifyListeners();

  @override
  void addLocalMessage(ChatMessage msg) {
    _messages.add(msg);
    notifyListeners();
  }

  @override
  Future<void> setMyName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    _myName = trimmed;
    notifyListeners();
  }

  @override
  void dispose() => super.dispose();
}

