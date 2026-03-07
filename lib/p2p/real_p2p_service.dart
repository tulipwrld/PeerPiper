// lib/p2p/real_p2p_service.dart
//
// Production P2PService. Orchestrates identity, mDNS, TCP, E2EE packets,
// ACK/retry, gossip, DTN, chunked file transfer, Sybil, rate-limit.
// CallService is wired here: sendSignal callback + decrypted signal dispatch.

import 'dart:async';
import 'dart:collection' show Queue;
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/group.dart';
import '../models/message.dart';
import '../models/peer.dart';
import 'call_service.dart';
import 'crypto_utils.dart';
import 'db_service.dart';
import 'discovery_service.dart';
import 'file_transfer.dart';
import 'gossip_service.dart';
import 'identity.dart';
import 'p2p_service.dart';
import 'packet.dart';
import 'tcp_transport.dart';

const _kKnownPeersKey = 'p2p_known_peers_v1';
const _kMyNameKey = 'p2p_my_name';
const _kGroupsKey = 'p2p_groups_v1';
const _kMaxLogs = 5000;

// ── ACK tracking ───────────────────────────────────────────────────────────
class _AckEntry {
  final String peerId;
  final Map<String, dynamic> header;
  int retries = 0;
  DateTime sentAt;
  _AckEntry(this.peerId, this.header) : sentAt = DateTime.now();
}

// ── Sybil staged peer ──────────────────────────────────────────────────────
class _PendingPeer {
  List<String> ips;
  final String name;
  final String xpub;
  final String challengeId;
  DateTime deadline;
  _PendingPeer({
    required this.ips,
    required this.name,
    required this.xpub,
    required this.challengeId,
  }) : deadline = DateTime.now().add(const Duration(seconds: 10));
}

// ── Ping tracking ──────────────────────────────────────────────────────────
class _PingEntry {
  final String peerId;
  final DateTime sentAt = DateTime.now();
  _PingEntry(this.peerId);
}

// ── Rate-limit bucket ──────────────────────────────────────────────────────
class _RateBucket {
  final _ts = Queue<int>();
  bool check({int limit = 120}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    while (_ts.isNotEmpty && now - _ts.first > 60000) _ts.removeFirst();
    if (_ts.length >= limit) return false;
    _ts.add(now);
    return true;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
class RealP2PService extends P2PService {
  NodeIdentity? _id;
  SecretKey? _masterKey;

  final Map<String, Peer> _onlinePeers = {};
  final Map<String, Peer> _knownPeers = {};
  final Map<String, ChatGroup> _groups = {};
  final List<ChatMessage> _messages = [];
  final List<P2PLogEntry> _logs = [];
  final Map<String, List<dynamic>> _logsByPeer = {};

  String _myName = 'MY_NODE';
  String _myIp = '--';
  bool _isOnline = false;
  bool _isInitialized = false;

  final _discovery = DiscoveryService();
  final _tcpServer = TcpServer();
  final _gossip = GossipService();
  final _fileSvc = FileTransferService();
  PacketBuilder? _pkt;

  // ── CallService (injected by provider, then wired in init()) ──────────────
  CallService? _callSvc;
  void wireCallService(CallService svc) => _callSvc = svc;

  final Map<String, _AckEntry> _pendingAcks = {};
  Timer? _ackTimer;

  final Map<String, _PendingPeer> _pendingPeers = {};
  Timer? _challengeTimer;

  final Map<String, _PingEntry> _pendingPings = {};
  Timer? _pingTimer;

  final Map<String, _RateBucket> _rateBuckets = {};
  static const int _kDtnFileChunkSize = 65536;

  // ── Getters ───────────────────────────────────────────────────────────────
  @override String get myName => _myName;
  @override String get myIp => _myIp;
  @override bool get isOnline => _isOnline;
  @override bool get isInitialized => _isInitialized;

  @override
  Map<String, Peer> get peers {
    final result = <String, Peer>{};
    for (final e in _knownPeers.entries) {
      result[e.key] = e.value.copyWith(isOnline: false);
    }
    for (final e in _onlinePeers.entries) {
      result[e.key] = e.value.copyWith(isOnline: true);
    }
    return Map.unmodifiable(result);
  }

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

  Map<String, Map<String, dynamic>> get _peersRaw => {
        for (final e in _onlinePeers.entries)
          e.key: {
            'ips': e.value.ips,
            'name': e.value.name,
            'xpub': e.value.xpub,
          }
      };

  // ── Init ──────────────────────────────────────────────────────────────────
  @override
  Future<void> init({String password = 'default'}) async {
    final prefs = await SharedPreferences.getInstance();
    final savedName = prefs.getString(_kMyNameKey);

    final salt = await IdentityService.getOrCreateMasterSalt();
    _masterKey = await CryptoUtils.deriveMasterKey(password, salt);
    _id = await IdentityService.loadOrCreate(_masterKey!);

    _myName = savedName ?? _sanitize(Platform.localHostname).toUpperCase();

    try {
      _myIp = await NetworkInfo().getWifiIP() ??
          await _fallbackIp() ?? '127.0.0.1';
    } catch (_) {
      _myIp = await _fallbackIp() ?? '127.0.0.1';
    }

    await _loadKnownPeers(prefs);
    await _loadGroups(prefs);

    _pkt = PacketBuilder(
      signKeyPair: _id!.signKeyPair,
      myId: _id!.myId,
      myName: _myName,
      myXPubHex: _id!.myXPubHex,
      myXKeyPair: _id!.xKeyPair,
    );
    await _loadRecentMessages();

    // Wire CallService callbacks
    if (_callSvc != null) {
      await _callSvc!.init();
      _callSvc!.sendSignal = _sendCallSignal;
      _callSvc!.lookupXpub = (uid) => _onlinePeers[uid]?.xpub;
      _callSvc!.onLog = (m) => _addLog(m);
    }

    _tcpServer.onPacket = _handleIncoming;
    await _tcpServer.start();

    _gossip.onLog = (m) => _addSystem('[GOSSIP] $m');
    _gossip.onGroupMessage =
        (originId, originName, text, groupId, groupMembers) {
      _ensureGroupFromNetwork(groupId, groupMembers, originName);
      _addIncoming(
          sender: '$originName [GROUP]',
          text: text,
          peerId: _groupPeerId(groupId));
      DbService.saveMessage(
          peerId: _groupPeerId(groupId),
          senderName: originName,
          senderId: originId, body: '[GROUP] $text');
    };
    _gossip.onStoredMessageReceived = (innerHeader, innerPayload) {
      unawaited(_handleIncoming(innerHeader, innerPayload, 'mesh'));
    };

    _fileSvc.hasActiveCall = () => _callSvc?.isInCall ?? false;
    _fileSvc.lookupPeer = (uid) => _peersRaw[uid];
    _fileSvc.onProgress = (tid, fn, recv, total) =>
        _addSystem('[FILE] $fn $recv/$total chunks');
    _fileSvc.onComplete = (tid, fn, data, hash, senderId, senderName) {
      unawaited(_handleIncomingFileComplete(
        filename: fn,
        data: data,
        senderId: senderId,
        senderName: senderName,
      ));
    };
    _fileSvc.onLog = _addSystem;

    _discovery.onPeerFound = _onPeerFound;
    _discovery.onPeerLost = _onPeerLost;
    _discovery.onLog = _addSystem;
    await _discovery.advertise(
        myName: _myName, myId: _id!.myId,
        myXPubHex: _id!.myXPubHex, port: kChatPort,
        myIp: _myIp == '--' ? null : _myIp);
    await _discovery.startBrowsing();

    _ackTimer = Timer.periodic(const Duration(seconds: 5), (_) => _ackRetryTick());
    _challengeTimer = Timer.periodic(const Duration(seconds: 5), (_) => _challengeExpiryTick());
    _pingTimer = Timer.periodic(const Duration(seconds: 60), (_) => _periodicPing());
    Timer.periodic(const Duration(hours: 1), (_) => DbService.cleanupExpiredForward());

    _isOnline = true;
    _isInitialized = true;
    _addSystem('=== Node: $_myName | ${_id!.myId.substring(0, 16)}... | $_myIp ===');
    notifyListeners();
  }

  // ── setMyName ─────────────────────────────────────────────────────────────
  @override
  Future<void> setMyName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    _myName = trimmed;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMyNameKey, trimmed);
    if (_id != null) {
      _pkt = PacketBuilder(
        signKeyPair: _id!.signKeyPair,
        myId: _id!.myId,
        myName: _myName,
        myXPubHex: _id!.myXPubHex,
        myXKeyPair: _id!.xKeyPair,
      );
    }
    notifyListeners();
  }

  // ── Peer persistence ──────────────────────────────────────────────────────
  Future<void> _loadRecentMessages() async {
    if (_id == null) return;
    try {
      final rows = await DbService.getRecentMessages(limit: 500);
      for (final row in rows.reversed) {
        final senderId = (row['sender_id'] as String?) ?? '';
        final senderName = (row['sender_name'] as String?) ?? 'Unknown';
        final body = (row['body'] as String?) ?? '';
        final peerId = (row['peer_id'] as String?) ?? '';
        if (body.isEmpty || peerId.isEmpty) continue;

        _messages.add(ChatMessage(
          sender: senderName,
          text: body,
          timestamp: _parseDbTime((row['timestamp'] as String?) ?? ''),
          isOwn: senderId == _id!.myId || senderName == 'Me',
          peerId: peerId,
        ));
      }
    } catch (e) {
      _addSystem('[DB] History load error: $e');
    }
  }
  @override
  Map<String, ChatGroup> get groups => Map.unmodifiable(_groups);

  DateTime _parseDbTime(String t) {
    final now = DateTime.now();
    final parts = t.split(':');
    if (parts.length != 3) return now;
    final h = int.tryParse(parts[0]) ?? now.hour;
    final m = int.tryParse(parts[1]) ?? now.minute;
    final s = int.tryParse(parts[2]) ?? now.second;
    return DateTime(now.year, now.month, now.day, h, m, s);
  }

  Future<void> _loadKnownPeers(SharedPreferences prefs) async {
    final json = prefs.getString(_kKnownPeersKey);
    if (json == null) return;
    try {
      final list = jsonDecode(json) as List;
      for (final item in list) {
        final p = Peer.fromJson(item as Map<String, dynamic>);
        if (p.uid != _id?.myId) _knownPeers[p.uid] = p;
      }
    } catch (_) {}
  }

  Future<void> _loadGroups(SharedPreferences prefs) async {
    final json = prefs.getString(_kGroupsKey);
    if (json == null) return;
    try {
      final list = jsonDecode(json) as List;
      for (final item in list) {
        final g = ChatGroup.fromJson(item as Map<String, dynamic>);
        _groups[g.id] = g;
      }
    } catch (_) {}
  }

  Future<void> _saveKnownPeers() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _kKnownPeersKey,
        jsonEncode(_knownPeers.values.map((p) => p.toJson()).toList()));
  }

  Future<void> _saveGroups() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kGroupsKey,
      jsonEncode(_groups.values.map((g) => g.toJson()).toList()),
    );
  }

  // ── Discovery ─────────────────────────────────────────────────────────────
  void _onPeerFound(String uid, List<String> ips, String name, String xpub) {
    if (uid == _id?.myId) return;
    if (_onlinePeers.containsKey(uid)) return;

    if (_pendingPeers.containsKey(uid)) {
      // Update IPs if we now have them (resolve() arrived late)
      if (ips.isNotEmpty) {
        _pendingPeers[uid]!.ips = ips;
        // Retry challenge with the real IP now that we have it
        final chalId = _pendingPeers[uid]!.challengeId;
        _sendChallenge(uid, chalId, ips);
      }
      return;
    }

    // Stage peer. IPs may be empty — that's OK.
    // If IPs are empty, we can't initiate the challenge, but the remote
    // side will send US a kPeerChallenge (it found our IP via mDNS),
    // and _handleIncoming picks up sourceIp to complete the handshake.
    final challengeId = const Uuid().v4().replaceAll('-', '');
    _pendingPeers[uid] = _PendingPeer(
      ips: ips, name: name, xpub: xpub, challengeId: challengeId,
    );

    if (ips.isNotEmpty) {
      _sendChallenge(uid, challengeId, ips);
    } else {
      _addSystem('[NET] Found $name (waiting for IP via TCP)');
    }
  }

  void _onPeerLost(String uid) {
    _pendingPeers.remove(uid);
    final removed = _onlinePeers.remove(uid);
    if (removed != null) {
      _knownPeers[uid] = removed.copyWith(isOnline: false);
      _addSystem('[NET] Disconnected: ${removed.name} (${_short(uid)})',
          peerId: uid);
      notifyListeners();
    }
  }

  Future<void> _sendChallenge(
      String uid, String challengeId, List<String> ips) async {
    if (_pkt == null || ips.isEmpty) return;
    try {
      await TcpClient.sendPacket(ips, await _pkt!.peerChallenge(challengeId));
    } catch (e) {
      // Connection failed — keep in pendingPeers, they may connect to us first
      debugPrint('[SYBIL] Challenge to ${_short(uid)} failed: $e');
    }
  }

  void _challengeExpiryTick() {
    final now = DateTime.now();
    _pendingPeers.removeWhere((uid, e) {
      if (e.deadline.isBefore(now)) {
        // Only remove if we actually had IPs and tried. Empty-IP entries
        // should live longer — refresh their deadline once.
        if (e.ips.isEmpty) {
          e.deadline = now.add(const Duration(seconds: 30));
          return false;
        }
        return true;
      }
      return false;
    });
  }

  void _promotePeer(String uid,
      {required String name,
      required List<String> ips,
      required String xpub}) {
    _pendingPeers.remove(uid);
    final peer = Peer(uid: uid, name: name, ips: ips, xpub: xpub, isOnline: true);
    _onlinePeers[uid] = peer;
    _knownPeers[uid] = peer;
    _saveKnownPeers();
    final ipStr = ips.isNotEmpty ? ips.first : '(no IP)';
    _addSystem('[NET] Online: $name @ $ipStr', peerId: uid);
    notifyListeners();

    _gossip.forwardStoredMessages(peerId: uid, peers: _peersRaw);
    if (_pkt != null) _fileSvc.resumeInterruptedTransfers(uid, _pkt!);
    _sendPing(uid);
  }

  // ── Send text ─────────────────────────────────────────────────────────────
  @override
  Future<void> sendMessage(String targetUid, String text) async {
    if (_pkt == null || _id == null) return;
    final peer = _onlinePeers[targetUid] ?? _knownPeers[targetUid];
    if (peer == null) {
      _addSystem('[DTN] Unknown peer: ${_short(targetUid)}');
      return;
    }

    final msgId = const Uuid().v4().replaceAll('-', '');
    final header = await _pkt!.e2eeText(peer.xpub, text, msgId);
    final isOnlineNow = _onlinePeers.containsKey(targetUid);

    try {
      if (!isOnlineNow) {
        throw ConnectionException('peer offline');
      }
      await TcpClient.sendPacket(peer.ips, header);
      await DbService.saveMessage(
          peerId: targetUid, senderName: 'Me',
          senderId: _id!.myId, body: text, msgId: msgId, delivered: 0);
      _pendingAcks[msgId] = _AckEntry(targetUid, header);
    } on ConnectionException {
      _addSystem('[DTN] Offline — storing for later: ${peer.name}');
      await DbService.saveMessage(
          peerId: targetUid, senderName: 'Me',
          senderId: _id!.myId, body: text, msgId: msgId, delivered: 0);
      await _gossip.storeAndForward(
          targetId: targetUid, innerHeader: header,
          myId: _id!.myId, peers: _peersRaw);
    }
  }

  @override
  Future<void> broadcastMessage(String text) async {
    for (final uid in _onlinePeers.keys) await sendMessage(uid, text);
  }

  @override
  Future<void> sendFile(
      String targetUid, String filename, Uint8List data) async {
    final peer = _onlinePeers[targetUid] ?? _knownPeers[targetUid];
    if (peer == null || _pkt == null || _masterKey == null || _id == null) {
      _addSystem('[!] Unknown peer — cannot send file');
      return;
    }
    if (!_onlinePeers.containsKey(targetUid)) {
      await _sendFileViaMesh(
        targetUid: targetUid,
        peer: peer,
        filename: filename,
        data: data,
      );
      return;
    }
    await _fileSvc.sendFile(
      peer: {'ips': peer.ips, 'name': peer.name, 'xpub': peer.xpub},
      peerId: targetUid,
      filename: filename,
      data: data,
      myId: _id!.myId,
      myName: _myName,
      myXPubHex: _id!.myXPubHex,
      myXKp: _id!.xKeyPair,
      masterKey: _masterKey!,
      pktBuilder: _pkt!,
    );
  }

  Future<void> _sendFileViaMesh({
    required String targetUid,
    required Peer peer,
    required String filename,
    required Uint8List data,
  }) async {
    if (_pkt == null || _id == null) return;
    final myId = _id!.myId;

    final transferId = const Uuid().v4().replaceAll('-', '');
    final fileHash = CryptoUtils.sha256Hex(data);
    final category = _classifyFile(filename);

    final fileKey = SecretKey(CryptoUtils.randomBytes(32).toList());
    final pairKey = await CryptoUtils.derivePairwiseKey(
      _id!.xKeyPair,
      peer.xpub,
      utf8.encode('direct-file-wrap-v1'),
    );
    final (wrapNonce, wrapCt) = await CryptoUtils.aesEncrypt(
      pairKey,
      await fileKey.extractBytes(),
      utf8.encode('wrap'),
    );

    final chunks = <Uint8List>[];
    for (var i = 0; i < data.length; i += _kDtnFileChunkSize) {
      chunks.add(data.sublist(
          i, (i + _kDtnFileChunkSize > data.length) ? data.length : i + _kDtnFileChunkSize));
    }

    final startHeader = await _pkt!.fileStart(
      peerXPubHex: peer.xpub,
      transferId: transferId,
      filename: p.basename(filename),
      category: category,
      totalChunks: chunks.length,
      fileHash: fileHash,
      sizePlain: data.length,
      wrapNonce: CryptoUtils.b64e(wrapNonce),
      wrapCt: CryptoUtils.b64e(wrapCt),
    );
    await _gossip.storeAndForward(
      targetId: targetUid,
      innerHeader: startHeader,
      myId: myId,
      peers: _peersRaw,
    );

    for (var idx = 0; idx < chunks.length; idx++) {
      final chunk = chunks[idx];
      final (nonce, enc) = await CryptoUtils.aesEncrypt(
        fileKey,
        chunk,
        utf8.encode('$transferId:$idx'),
      );
      final ch = await _pkt!.fileChunk(
        transferId: transferId,
        chunkIdx: idx,
        totalChunks: chunks.length,
        chunkHash: CryptoUtils.sha256Hex(chunk),
        chunkSizeEnc: enc.length,
        chunkNonce: CryptoUtils.b64e(nonce),
      );
      await _gossip.storeAndForward(
        targetId: targetUid,
        innerHeader: ch,
        innerPayload: enc,
        myId: myId,
        peers: _peersRaw,
      );
      if (chunks.length >= 10 && (idx + 1) % (chunks.length ~/ 10).clamp(1, chunks.length) == 0) {
        _addSystem(
          '[DTN FILE] ${p.basename(filename)} ${idx + 1}/${chunks.length} chunks queued',
          peerId: targetUid,
        );
      }
    }

    final complete = await _pkt!.fileComplete(
      transferId: transferId,
      fileHash: fileHash,
      totalChunks: chunks.length,
    );
    await _gossip.storeAndForward(
      targetId: targetUid,
      innerHeader: complete,
      myId: myId,
      peers: _peersRaw,
    );
    _addSystem(
      '[DTN FILE] ${p.basename(filename)} queued for offline delivery (${data.length} bytes)',
      peerId: targetUid,
    );
  }

  @override
  Future<void> sendGroupMessage(List<String> memberUids, String text) async {
    final myId = _id?.myId;
    final all = <String>{...memberUids, if (myId != null) myId}.toList();
    final gid = _gossip.groupIdForMembers(all);
    if (!_groups.containsKey(gid)) {
      _groups[gid] = ChatGroup(id: gid, name: 'Group', memberUids: all);
      await _saveGroups();
    }
    await sendGroupMessageToGroup(gid, text);
  }

  @override
  Future<void> sendGroupMessageToGroup(String groupId, String text) async {
    if (_pkt == null || _id == null) return;
    final group = _groups[groupId];
    if (group == null) return;
    final myId = _id!.myId;
    final allIds = <String>{...group.memberUids, myId}.toList();
    final memberUids = allIds.where((id) => id != myId).toList();
    final (senderKey, keyVersion, rotated) =
        _gossip.ensureOwnSenderKey(groupId, allIds);

    if (rotated) {
      await _gossip.distributeSenderKey(
          peers: _peersRaw, groupIds: allIds, groupId: groupId,
          senderKey: senderKey, keyVersion: keyVersion,
          myId: myId, myName: _myName, myXPubHex: _id!.myXPubHex,
          myXKp: _id!.xKeyPair, pktBuilder: _pkt!);
    }

    final skKey = SecretKey(senderKey);
    final aad = utf8.encode('$groupId:$keyVersion');
    final (nonce, ct) =
        await CryptoUtils.aesEncrypt(skKey, utf8.encode(text), aad);

    final gossipId = const Uuid().v4().replaceAll('-', '');
    final payload = await _pkt!.buildGossipPayload({
      'gossip_id': gossipId, 'ptype': 'group_text',
      'group_id': groupId, 'group_ids': allIds,
      'key_version': keyVersion,
      'nonce': CryptoUtils.b64e(nonce),
      'ciphertext': CryptoUtils.b64e(ct),
    });
    _gossip.markSeen(gossipId);
    final envelope = {'kind': kGossipGroupText, 'ttl': 5,
        'relay_id': myId, 'payload': payload};
    await DbService.saveMessage(
        peerId: _groupPeerId(groupId),
        senderName: 'Me',
        senderId: myId,
        body: text);
    await _gossip.spread(_peersRaw, envelope, myId,
        excludeIds: {myId}, includeIds: memberUids);
    _messages.add(ChatMessage(
      sender: 'YOU [GROUP]',
      text: text,
      timestamp: DateTime.now(),
      isOwn: true,
      peerId: _groupPeerId(groupId),
    ));
    notifyListeners();
  }

  @override
  Future<ChatGroup> createGroup(String name, List<String> memberUids) async {
    final n = name.trim().isEmpty ? 'Group' : name.trim();
    final norm = <String>{...memberUids, if (_id != null) _id!.myId}.toList()
      ..sort();
    final id = const Uuid().v4().replaceAll('-', '');
    final g = ChatGroup(id: id, name: n, memberUids: norm);
    _groups[id] = g;
    await _saveGroups();
    notifyListeners();
    return g;
  }

  @override
  Future<void> updateGroupMembers(String groupId, List<String> memberUids) async {
    final g = _groups[groupId];
    if (g == null) return;
    final norm = <String>{...memberUids, if (_id != null) _id!.myId}.toList()
      ..sort();
    _groups[groupId] = g.copyWith(memberUids: norm);
    await _saveGroups();
    notifyListeners();
  }

  // ── Call signaling (outgoing) ─────────────────────────────────────────────
  /// Called by CallService.sendSignal callback.
  Future<void> _sendCallSignal(
      String targetUid, Map<String, dynamic> signal) async {
    final peer = _onlinePeers[targetUid];
    if (peer == null || _pkt == null) return;
    try {
      final pkt = await _pkt!.callSignal(peer.xpub, signal['type'] as String, signal);
      await TcpClient.sendPacket(peer.ips, pkt);
    } catch (e) {
      _addLog('[CALL] Signal send error: $e', peerId: targetUid);
    }
  }

  // ── Ping ──────────────────────────────────────────────────────────────────
  Future<void> _sendPing(String uid) async {
    final peer = _onlinePeers[uid];
    if (peer == null || _pkt == null) return;
    final pingId = const Uuid().v4().replaceAll('-', '');
    _pendingPings[pingId] = _PingEntry(uid);
    try {
      await TcpClient.sendPacket(peer.ips, await _pkt!.ping(pingId));
    } catch (_) {
      _pendingPings.remove(pingId);
    }
  }

  void _periodicPing() {
    for (final uid in _onlinePeers.keys) _sendPing(uid);
  }

  // ── ACK retry ─────────────────────────────────────────────────────────────
  Future<void> _ackRetryTick() async {
    final now = DateTime.now();
    for (final kv in _pendingAcks.entries.toList()) {
      final msgId = kv.key;
      final ack = kv.value;
      if (now.difference(ack.sentAt).inSeconds < 5) continue;
      if (ack.retries >= 3) {
        _pendingAcks.remove(msgId);
        await DbService.markFailed(msgId);
        final peer = _onlinePeers[ack.peerId];
        if (peer != null && _id != null) {
          await _gossip.storeAndForward(
              targetId: ack.peerId, innerHeader: ack.header,
              myId: _id!.myId, peers: _peersRaw);
        }
        continue;
      }
      ack.retries++;
      ack.sentAt = now;
      final peer = _onlinePeers[ack.peerId];
      if (peer != null) {
        try { await TcpClient.sendPacket(peer.ips, ack.header); } catch (_) {}
      }
    }
  }

  // ── Incoming packet dispatcher ─────────────────────────────────────────────
  Future<void> _handleIncoming(
      Map<String, dynamic> header, Uint8List payload, String sourceIp) async {
    final kind = header['kind'] as String?;
    if (kind == null) return;

    // Gossip envelopes have unsigned outer wrappers — check before sig verify
    if (kind == kGossipSenderKey && _id != null) {
      await _gossip.handleGossipSenderKey(
          envelope: header, myId: _id!.myId, myXPubHex: _id!.myXPubHex,
          myXKp: _id!.xKeyPair, peers: _peersRaw);
      return;
    }
    if (kind == kGossipGroupText && _id != null) {
      await _gossip.handleGossipGroupText(
          envelope: header, myId: _id!.myId, peers: _peersRaw);
      return;
    }
    if (kind == kStoreForward && _id != null) {
      await _gossip.handleStoreForward(header, _id!.myId, _peersRaw);
      return;
    }

    if (!await PacketVerifier.verifyHeader(header)) {
      debugPrint('[SIG] Bad sig kind=$kind from $sourceIp');
      return;
    }

    final senderId = header['sender_id'] as String? ?? '';
    final senderName = header['sender_name'] as String? ?? 'Unknown';
    final senderXpub = header['sender_xpub'] as String? ?? '';

    if (!(_rateBuckets[senderId] ??= _RateBucket()).check()) return;

    switch (kind) {
      case kPing:
        final pingId = header['ping_id'] as String? ?? '';
        final peer = _onlinePeers[senderId];
        final replyIps =
            peer?.ips ?? (sourceIp.isNotEmpty ? [sourceIp] : <String>[]);
        if (replyIps.isNotEmpty && _pkt != null) {
          try {
            await TcpClient.sendPacket(replyIps, await _pkt!.pong(pingId));
          } catch (_) {}
        }

      case kPong:
        final pingId = header['ping_id'] as String? ?? '';
        final pe = _pendingPings.remove(pingId);
        if (pe != null) {
          final rtt =
              DateTime.now().difference(pe.sentAt).inMicroseconds / 1000.0;
          await DbService.logMetric(senderId, rtt);
          _addSystem('[RTT] $senderName: ${rtt.toStringAsFixed(1)} ms',
              peerId: senderId);
        }

      case kAck:
        final msgId = header['msg_id'] as String? ?? '';
        if (_pendingAcks.remove(msgId) != null) {
          await DbService.markDelivered(msgId);
        }

      case kPeerChallenge:
        final challengeId = header['challenge_id'] as String? ?? '';
        if (challengeId.isEmpty) break;

        // Build reply IPs: existing knowledge OR TCP source address
        var replyIps = _pendingPeers[senderId]?.ips.isNotEmpty == true
            ? _pendingPeers[senderId]!.ips
            : (_onlinePeers[senderId]?.ips ?? <String>[]);
        if (sourceIp.isNotEmpty && !replyIps.contains(sourceIp)) {
          replyIps = [sourceIp, ...replyIps];
        }
        if (replyIps.isEmpty || _pkt == null) break;

        // Respond to their challenge immediately
        try {
          await TcpClient.sendPacket(
              replyIps, await _pkt!.peerChallengeResponse(challengeId));
        } catch (_) {}

        if (_pendingPeers.containsKey(senderId)) {
          // We already staged this peer (from mDNS).
          // Refresh IPs with TCP sourceIp and retry our challenge, because
          // mDNS TXT can carry an unreachable interface address.
          final existing = _pendingPeers[senderId]!;
          var mergedIps = [...existing.ips];
          if (sourceIp.isNotEmpty && !mergedIps.contains(sourceIp)) {
            mergedIps = [sourceIp, ...mergedIps];
          }
          if (mergedIps.isNotEmpty) {
            existing.ips = mergedIps;
            _sendChallenge(senderId, existing.challengeId, mergedIps);
          }
        } else if (!_onlinePeers.containsKey(senderId) && senderXpub.isNotEmpty) {
          // Completely new peer — stage and send our own challenge
          final myChallId = const Uuid().v4().replaceAll('-', '');
          _pendingPeers[senderId] = _PendingPeer(
              ips: replyIps, name: senderName,
              xpub: senderXpub, challengeId: myChallId);
          _sendChallenge(senderId, myChallId, replyIps);
        }

      case kPeerChallengeResp:
        final challengeId = header['challenge_id'] as String? ?? '';
        final pending = _pendingPeers[senderId];
        if (pending != null && pending.challengeId == challengeId) {
          final ips = [...pending.ips];
          if (sourceIp.isNotEmpty && !ips.contains(sourceIp)) {
            ips.insert(0, sourceIp);
          }
          _promotePeer(senderId,
              name: pending.name.isNotEmpty ? pending.name : senderName,
              ips: ips,
              xpub: pending.xpub.isNotEmpty ? pending.xpub : senderXpub);
        }

      case kE2eeText:
        if (senderXpub.isEmpty || _id == null) break;
        try {
          final key = await CryptoUtils.derivePairwiseKey(
              _id!.xKeyPair, senderXpub, utf8.encode('direct-text-v1'));
          final nonce = CryptoUtils.b64d(header['nonce'] as String);
          final ct = CryptoUtils.b64d(header['ciphertext'] as String);
          final plain =
              await CryptoUtils.aesDecrypt(key, nonce, ct, utf8.encode('text'));
          final text = utf8.decode(plain);
          final msgId = header['msg_id'] as String? ?? '';
          _addIncoming(sender: senderName, text: text, peerId: senderId);
          await DbService.saveMessage(
              peerId: senderId, senderName: senderName,
              senderId: senderId, body: text,
              msgId: msgId.isEmpty ? null : msgId);
          if (msgId.isNotEmpty) {
            final replyIps = _onlinePeers[senderId]?.ips ??
                (sourceIp.isNotEmpty ? [sourceIp] : <String>[]);
            if (replyIps.isNotEmpty && _pkt != null) {
              try {
                await TcpClient.sendPacket(replyIps, await _pkt!.ack(msgId));
              } catch (_) {}
            }
          }
        } catch (e) {
          _addSystem('[!] Decrypt error: $e');
        }

      case kFileStart:
        await _fileSvc.handleFileStart(header, senderId, senderName);

      case kFileChunk:
        if (_id == null) break;
        await _fileSvc.handleFileChunk(header, payload, _id!.xKeyPair);

      case kFileComplete:
        if (_id == null || _masterKey == null || _pkt == null) break;
        await _fileSvc.handleFileComplete(
            header, senderId, senderName, _id!.xKeyPair, _masterKey!, _pkt!);

      case kFileResumeRequest:
        if (_pkt != null) await _fileSvc.resumeInterruptedTransfers(senderId, _pkt!);

      // ── Call signal — decrypt, then delegate to CallService ───────────────
      case kCallSignal:
        if (senderXpub.isEmpty || _id == null) break;
        try {
          final key = await CryptoUtils.derivePairwiseKey(
              _id!.xKeyPair, senderXpub, utf8.encode('call-signal-v1'));
          final nonce = CryptoUtils.b64d(header['nonce'] as String);
          final ct = CryptoUtils.b64d(header['ciphertext'] as String);
          final plain =
              await CryptoUtils.aesDecrypt(key, nonce, ct, utf8.encode('call'));
          final signal =
              jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;

          await _routeCallSignal(
              peerId: senderId,
              peerName: senderName,
              peerXpub: senderXpub,
              signal: signal);
        } catch (e) {
          _addLog('[CALL] Signal error: $e', peerId: senderId);
        }
    }
  }

  // ── Route decrypted call signal to CallService ────────────────────────────
  Future<void> _routeCallSignal({
    required String peerId,
    required String peerName,
    required String peerXpub,
    required Map<String, dynamic> signal,
  }) async {
    final svc = _callSvc;
    if (svc == null) return;

    final nested = signal['data'];
    final payload = nested is Map<String, dynamic>
        ? Map<String, dynamic>.from(nested)
        : (nested is Map ? Map<String, dynamic>.from(nested) : signal);
    final type = (signal['type'] as String?) ??
        (payload['type'] as String?) ??
        '';
    if (type == 'offer') {
      svc.handleIncomingOffer(
        peerId: peerId,
        peerName: peerName,
        peerXpub: peerXpub,
        signal: payload,
      );
      _addLog('[CALL] Incoming call from $peerName', peerId: peerId);
    } else if (type == 'answer') {
      final sdp = payload['sdp'] as String? ?? '';
      await svc.handleAnswer(peerId, sdp);
      _addLog('[CALL] $peerName answered', peerId: peerId);
    } else if (type == 'reoffer') {
      final sdp = payload['sdp'] as String? ?? '';
      await svc.handleReoffer(peerId, sdp);
      _addLog('[CALL] Reoffer from $peerName', peerId: peerId);
    } else if (type == 'reanswer') {
      final sdp = payload['sdp'] as String? ?? '';
      await svc.handleReanswer(peerId, sdp);
      _addLog('[CALL] Reanswer from $peerName', peerId: peerId);
    } else if (type == 'ice') {
      await svc.handleIceCandidate(peerId, payload);
    } else if (type == 'reject') {
      await svc.handleReject(peerId);
      _addLog('[CALL] $peerName declined', peerId: peerId);
    } else if (type == 'hangup') {
      await svc.handleHangup(peerId);
      _addLog('[CALL] $peerName hung up', peerId: peerId);
    }
    notifyListeners();
  }

  // ── P2PService stubs ──────────────────────────────────────────────────────
  @override void refreshPeers() => notifyListeners();

  @override
  Future<String?> exportLogsToTxt() async {
    try {
      final baseDir = await _pickWritableBaseDir();
      final dir = Directory(p.join(baseDir.path, 'P2PChat Logs'));
      await dir.create(recursive: true);
      final now = DateTime.now();
      final ts =
          '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
      final file = File(p.join(dir.path, 'logs_$ts.txt'));
      final b = StringBuffer()
        ..writeln('P2P Chat Logs')
        ..writeln('Node: $_myName (${_id?.myId ?? "-"})')
        ..writeln('Generated: ${DateTime.now().toIso8601String()}')
        ..writeln('');
      for (final e in _logs) {
        final peerSuffix = e.peerId.isEmpty ? '' : ' [peer:${_short(e.peerId)}]';
        b.writeln('[${e.hhmmss}]$peerSuffix ${e.text}');
      }
      await file.writeAsString(b.toString(), flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  @override
  void addLocalMessage(ChatMessage msg) {
    _messages.add(msg);
    notifyListeners();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  void _addSystem(String text, {String peerId = ''}) {
    _messages.add(ChatMessage(
        sender: '', text: text, timestamp: DateTime.now(), isSystem: true));
    _addLog(text, peerId: peerId);
    notifyListeners();
  }

  void _addIncoming(
      {required String sender,
      required String text,
      required String peerId}) {
    _messages.add(ChatMessage(
        sender: sender, text: text,
        timestamp: DateTime.now(), isOwn: false, peerId: peerId));
    _addLog('[$sender] $text', peerId: peerId);
    notifyListeners();
  }

  void _addLog(String text, {String peerId = ''}) {
    final entry = P2PLogEntry(ts: DateTime.now(), text: text, peerId: peerId);
    _logs.add(entry);
    if (_logs.length > _kMaxLogs) {
      _logs.removeRange(0, _logs.length - _kMaxLogs);
    }
    if (peerId.isNotEmpty) {
      final list = _logsByPeer.putIfAbsent(peerId, () => <dynamic>[]);
      list.add(entry);
      if (list.length > 2000) {
        list.removeRange(0, list.length - 2000);
      }
    }
    notifyListeners();
  }

  String _groupPeerId(String groupId) => 'group:$groupId';
  String _groupIdFromPeerId(String peerId) =>
      peerId.startsWith('group:') ? peerId.substring(6) : peerId;

  void _ensureGroupFromNetwork(
      String groupId, List<String> members, String originName) {
    if (_groups.containsKey(groupId)) return;
    final cleaned = members.toSet().toList()..sort();
    _groups[groupId] = ChatGroup(
      id: groupId,
      name: originName.isEmpty ? 'Group ${_short(groupId)}' : 'Group $originName',
      memberUids: cleaned,
    );
    unawaited(_saveGroups());
    notifyListeners();
  }

  static String _sanitize(String h) =>
      h.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
  static String _short(String uid) =>
      uid.length > 12 ? '${uid.substring(0, 12)}...' : uid;
  static String _classifyFile(String filename) {
    final ext = p.extension(filename).toLowerCase();
    if ({'.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic'}
        .contains(ext)) return 'photo';
    if ({'.mp4', '.mov', '.avi', '.mkv', '.webm', '.m4v'}.contains(ext)) {
      return 'video';
    }
    if ({'.ogg', '.opus', '.m4a', '.wav', '.mp3', '.aac', '.flac'}
        .contains(ext)) return 'voice';
    return 'file';
  }

  Future<void> _handleIncomingFileComplete({
    required String filename,
    required Uint8List data,
    required String senderId,
    required String senderName,
  }) async {
    final savedPath = await _saveIncomingFile(filename, data);
    final text = savedPath.isEmpty
        ? '[FILE] $filename (${data.length} B)'
        : '[FILE] $filename (${data.length} B)\nSaved: $savedPath';
    _addIncoming(sender: senderName, text: text, peerId: senderId);
    if (_id != null) {
      await DbService.saveMessage(
        peerId: senderId,
        senderName: senderName,
        senderId: senderId,
        body: text,
      );
    }
  }

  Future<String> _saveIncomingFile(String filename, Uint8List data) async {
    try {
      final baseDir = await _pickWritableBaseDir();
      final recvDir = Directory(p.join(baseDir.path, 'P2PChat Received'));
      await recvDir.create(recursive: true);

      final safeName = _safeFileName(filename);
      final targetPath = _uniquePath(recvDir.path, safeName);
      final file = File(targetPath);
      await file.writeAsBytes(data, flush: true);
      return file.path;
    } catch (e) {
      _addSystem('[FILE] Save failed: $e');
      return '';
    }
  }

  String _uniquePath(String dirPath, String filename) {
    final ext = p.extension(filename);
    final base = ext.isEmpty ? filename : filename.substring(0, filename.length - ext.length);
    var candidate = p.join(dirPath, filename);
    var idx = 1;
    while (File(candidate).existsSync()) {
      candidate = p.join(dirPath, '${base}_$idx$ext');
      idx++;
    }
    return candidate;
  }

  Future<Directory> _pickWritableBaseDir() async {
    final candidates = <Directory>[];
    final dl = await getDownloadsDirectory();
    if (dl != null) candidates.add(dl);

    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) {
        candidates.add(Directory(p.join(home, 'Downloads')));
      }
    }

    candidates.add(await getApplicationDocumentsDirectory());
    candidates.add(await getApplicationSupportDirectory());

    for (final d in candidates) {
      try {
        await d.create(recursive: true);
        final probe = File(p.join(d.path, '.p2p_probe'));
        await probe.writeAsString('ok', flush: true);
        if (await probe.exists()) {
          await probe.delete();
        }
        return d;
      } catch (_) {}
    }
    return await getTemporaryDirectory();
  }

  String _safeFileName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'file.bin';
    final sanitized = trimmed.replaceAll(RegExp(r'[\\/:*?"<>|\u0000-\u001F]'), '_');
    return sanitized.isEmpty ? 'file.bin' : sanitized;
  }

  static Future<String?> _fallbackIp() async {
    try {
      final ifaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }

  @override
  void dispose() {
    _ackTimer?.cancel();
    _challengeTimer?.cancel();
    _pingTimer?.cancel();
    _discovery.stop();
    _tcpServer.stop();
    super.dispose();
  }
}
