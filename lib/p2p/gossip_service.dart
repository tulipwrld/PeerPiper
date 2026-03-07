// lib/p2p/gossip_service.dart
//
// Mirrors Python:
//   gossip_spread(), mark_gossip_seen(), SEEN_GOSSIP_IDS
//   _store_and_forward(), _forward_stored_messages()
//   Group Sender Key scheme (ensure_own_sender_key, distribute_sender_key)
//   send_group_message()

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';

import 'crypto_utils.dart';
import 'db_service.dart';
import 'packet.dart';
import 'tcp_transport.dart';

const _kGossipFanout = 3;
const _kGossipTtl = 5;
const _kMaxSeenGossip = 20000;
const _kSenderKeyWrapInfo = 'sender-key-wrap-v1';

typedef PeerLookup = Map<String, dynamic>? Function(String uid);
typedef LogCallback = void Function(String msg);

class GossipService {
  final Set<String> _seenIds = {};
  final Queue<String> _seenOrder = Queue();

  // group_id → {key, version, members}
  final Map<String, Map<String, dynamic>> _ownSenderKeys = {};
  // group_id → {origin_id → {version, key}}
  final Map<String, Map<String, Map<String, dynamic>>> _remoteSenderKeys = {};

  LogCallback? onLog;
  // Called when a group text message is decrypted
  void Function(String originId, String originName, String text,
      String groupId, List<String> groupMembers)? onGroupMessage;
  // Called when a store_forward packet arrives for us
  void Function(Map<String, dynamic> innerHeader, Uint8List innerPayload)?
      onStoredMessageReceived;

  // ── Gossip dedup ──────────────────────────────────────────────────────────
  bool markSeen(String gossipId) {
    if (_seenIds.contains(gossipId)) return false;
    _seenIds.add(gossipId);
    _seenOrder.add(gossipId);
    if (_seenOrder.length > _kMaxSeenGossip) {
      _seenIds.remove(_seenOrder.removeFirst());
    }
    return true;
  }

  // ── Gossip spread ─────────────────────────────────────────────────────────
  /// [peersMap]: uid → {ips, name, xpub}
  Future<(int, int)> spread(
    Map<String, Map<String, dynamic>> peersMap,
    Map<String, dynamic> envelope,
    String myId, {
    Set<String>? excludeIds,
    List<String>? includeIds,
  }) async {
    final exclude = excludeIds ?? {};
    final include =
        (includeIds ?? []).where((u) => peersMap.containsKey(u) && !exclude.contains(u)).toList();
    final pool = peersMap.entries
        .where((e) => !exclude.contains(e.key) && !include.contains(e.key))
        .toList();

    pool.shuffle();
    final extra = pool.take(_kGossipFanout - include.length).map((e) => e.key).toList();
    final selected = [...include, ...extra];

    int sent = 0, failed = 0;
    for (final uid in selected) {
      final peer = peersMap[uid];
      if (peer == null) continue;
      final out = Map<String, dynamic>.from(envelope)..['relay_id'] = myId;
      try {
        await TcpClient.sendPacket(
            List<String>.from(peer['ips'] as List), out);
        sent++;
      } catch (_) {
        failed++;
      }
    }
    return (sent, failed);
  }

  // ── DTN store-and-forward ─────────────────────────────────────────────────
  Future<void> storeAndForward({
    required String targetId,
    required Map<String, dynamic> innerHeader,
    Uint8List? innerPayload,
    required String myId,
    required Map<String, Map<String, dynamic>> peers,
  }) async {
    final gossipId = const Uuid().v4().replaceAll('-', '');
    final payloadB64 =
        (innerPayload != null && innerPayload.isNotEmpty)
            ? CryptoUtils.b64e(innerPayload)
            : '';
    final envelope = {
      'kind': kStoreForward,
      'gossip_id': gossipId,
      'recipient_id': targetId,
      'expire_at':
          DateTime.now().millisecondsSinceEpoch ~/ 1000 + 7 * 24 * 3600,
      'inner_header': innerHeader,
      if (payloadB64.isNotEmpty) 'inner_payload_b64': payloadB64,
      'relay_id': myId,
      'ttl': _kGossipTtl,
    };

    await DbService.storeForward(
      gossipId: gossipId,
      recipientId: targetId,
      envelopeJson: jsonEncode(envelope),
    );
    markSeen(gossipId);

    await spread(peers, envelope, myId, excludeIds: {myId});
    onLog?.call(
        '[DTN] Сообщение сохранено в mesh → ${targetId.substring(0, 12)}');
  }

  /// Called when a peer comes online — forward any stored messages.
  Future<void> forwardStoredMessages({
    required String peerId,
    required Map<String, Map<String, dynamic>> peers,
  }) async {
    await Future.delayed(const Duration(milliseconds: 1500));
    final peer = peers[peerId];
    if (peer == null) return;

    final rows = await DbService.getPendingForward(peerId);
    if (rows.isEmpty) return;
    onLog?.call(
        '[DTN] Форвардим ${rows.length} сообщений → ${peerId.substring(0, 12)}');

    for (final row in rows) {
      try {
        final env = jsonDecode(row['envelope_json'] as String)
            as Map<String, dynamic>;
        final inner = env['inner_header'] as Map<String, dynamic>?;
        final payloadB64 = env['inner_payload_b64'] as String? ?? '';
        final payload =
            payloadB64.isEmpty ? null : Uint8List.fromList(CryptoUtils.b64d(payloadB64));
        if (inner != null) {
          await TcpClient.sendPacket(
              List<String>.from(peer['ips'] as List), inner, payload);
          await DbService.deletePendingForward(row['gossip_id'] as String);
        }
      } catch (e) {
        onLog?.call('[DTN] Ошибка форварда: $e');
      }
    }
  }

  // ── Handle incoming store_forward packet ──────────────────────────────────
  Future<void> handleStoreForward(
    Map<String, dynamic> envelope,
    String myId,
    Map<String, Map<String, dynamic>> peers,
  ) async {
    final gossipId = envelope['gossip_id'] as String? ?? '';
    final recipientId = envelope['recipient_id'] as String? ?? '';
    final ttl = (envelope['ttl'] as num?)?.toInt() ?? 0;
    final relayId = envelope['relay_id'] as String? ?? '';

    if (gossipId.isEmpty || !markSeen(gossipId)) return;

    // Store locally
    await DbService.storeForward(
      gossipId: gossipId,
      recipientId: recipientId,
      envelopeJson: jsonEncode(envelope),
    );

    if (recipientId == myId) {
      final inner = envelope['inner_header'] as Map<String, dynamic>?;
      final payloadB64 = envelope['inner_payload_b64'] as String? ?? '';
      final payload =
          payloadB64.isEmpty ? Uint8List(0) : Uint8List.fromList(CryptoUtils.b64d(payloadB64));
      if (inner != null) {
        onStoredMessageReceived?.call(inner, payload);
      }
      await DbService.deletePendingForward(gossipId);
      return;
    }

    if (peers.containsKey(recipientId)) {
      // Target is online — deliver immediately
      await forwardStoredMessages(peerId: recipientId, peers: peers);
    } else if (ttl > 1) {
      final fwd = Map<String, dynamic>.from(envelope)
        ..['ttl'] = ttl - 1;
      await spread(peers, fwd, myId, excludeIds: {myId, relayId});
    }
  }

  // ── Group sender key management ───────────────────────────────────────────
  String groupIdForMembers(List<String> memberIds) {
    final sorted = [...memberIds]..sort();
    return CryptoUtils.sha256Hex(
        Uint8List.fromList(utf8.encode(sorted.join('|'))));
  }

  /// Returns (key, version, rotated).
  (List<int>, int, bool) ensureOwnSenderKey(
      String groupId, List<String> memberIds) {
    final norm = ([...memberIds]..sort()).join('|');
    final state = _ownSenderKeys[groupId];
    if (state != null && state['members'] == norm) {
      return (state['key'] as List<int>, state['version'] as int, false);
    }
    final newVersion =
        state == null ? 1 : (state['version'] as int) + 1;
    final newKey = CryptoUtils.randomBytes(32).toList();
    _ownSenderKeys[groupId] = {
      'key': newKey,
      'version': newVersion,
      'members': norm,
    };
    return (newKey, newVersion, true);
  }

  void rememberRemoteSenderKey(
      String groupId, String originId, int version, List<int> key) {
    final groupMap = _remoteSenderKeys.putIfAbsent(groupId, () => {});
    final prev = groupMap[originId];
    if (prev == null || version >= (prev['version'] as int)) {
      groupMap[originId] = {'version': version, 'key': key};
    }
  }

  List<int>? fetchRemoteSenderKey(
      String groupId, String originId, int version) {
    final entry = _remoteSenderKeys[groupId]?[originId];
    if (entry == null || (entry['version'] as int) != version) return null;
    return entry['key'] as List<int>;
  }

  // ── Distribute sender key to all group members ────────────────────────────
  Future<void> distributeSenderKey({
    required Map<String, Map<String, dynamic>> peers,
    required List<String> groupIds,
    required String groupId,
    required List<int> senderKey,
    required int keyVersion,
    required String myId,
    required String myName,
    required String myXPubHex,
    required SimpleKeyPair myXKp,
    required PacketBuilder pktBuilder,
  }) async {
    for (final targetId in groupIds) {
      if (targetId == myId) continue;
      final peer = peers[targetId];
      if (peer == null) continue;
      try {
        final pairKey = await CryptoUtils.derivePairwiseKey(
            myXKp,
            peer['xpub'] as String,
            utf8.encode(_kSenderKeyWrapInfo));
        // Single encryption — aesEncrypt generates a fresh random nonce each call
        final (n, wct) = await CryptoUtils.aesEncrypt(
            pairKey, senderKey, utf8.encode(groupId));

        final gossipId = const Uuid().v4().replaceAll('-', '');
        final payload = await pktBuilder.buildGossipPayload({
          'gossip_id': gossipId,
          'ptype': 'sender_key',
          'origin_xpub': myXPubHex,
          'group_id': groupId,
          'group_ids': groupIds,
          'key_version': keyVersion,
          'target_id': targetId,
          'wrap_nonce': CryptoUtils.b64e(n),
          'wrap_ct': CryptoUtils.b64e(wct),
        });
        markSeen(gossipId);
        final envelope = {
          'kind': kGossipSenderKey,
          'ttl': _kGossipTtl,
          'relay_id': myId,
          'payload': payload,
        };
        await spread(peers, envelope, myId, includeIds: [targetId]);
      } catch (e) {
        onLog?.call(
            '[Группа] Ошибка sender key для ${targetId.substring(0, 12)}: $e');
      }
    }
  }

  // ── Handle incoming gossip_sender_key ─────────────────────────────────────
  Future<void> handleGossipSenderKey({
    required Map<String, dynamic> envelope,
    required String myId,
    required String myXPubHex,
    required SimpleKeyPair myXKp,
    required Map<String, Map<String, dynamic>> peers,
  }) async {
    final ttl = (envelope['ttl'] as num?)?.toInt() ?? 0;
    final relayId = envelope['relay_id'] as String? ?? '';
    final payload = envelope['payload'] as Map<String, dynamic>? ?? {};
    final gossipId = payload['gossip_id'] as String? ?? '';

    if (gossipId.isEmpty) return;
    if (!await PacketVerifier.verifyGossipPayload(payload)) return;
    if (!markSeen(gossipId)) return;

    final ptype = payload['ptype'] as String?;
    final originId = payload['origin_id'] as String? ?? '';
    final groupId = payload['group_id'] as String? ?? '';

    if (ptype == 'sender_key' && payload['target_id'] == myId) {
      try {
        final originXpub = payload['origin_xpub'] as String;
        final pairKey = await CryptoUtils.derivePairwiseKey(
            myXKp, originXpub, utf8.encode(_kSenderKeyWrapInfo));
        final wrapNonce = CryptoUtils.b64d(payload['wrap_nonce'] as String);
        final wrapCt = CryptoUtils.b64d(payload['wrap_ct'] as String);
        final senderKey = await CryptoUtils.aesDecrypt(
            pairKey, wrapNonce, wrapCt, utf8.encode(groupId));
        rememberRemoteSenderKey(
            groupId,
            originId,
            (payload['key_version'] as num).toInt(),
            senderKey.toList());
        onLog?.call(
            '[Группа] Получен sender key v${payload['key_version']} от ${payload['origin_name']}');
      } catch (e) {
        onLog?.call('[Группа] Ошибка обработки sender key: $e');
      }
    }

    if (ttl > 1) {
      final fwd = Map<String, dynamic>.from(envelope)..['ttl'] = ttl - 1;
      await spread(peers, fwd, myId, excludeIds: {myId, relayId});
    }
  }

  // ── Handle incoming gossip_group_text ─────────────────────────────────────
  Future<void> handleGossipGroupText({
    required Map<String, dynamic> envelope,
    required String myId,
    required Map<String, Map<String, dynamic>> peers,
  }) async {
    final ttl = (envelope['ttl'] as num?)?.toInt() ?? 0;
    final relayId = envelope['relay_id'] as String? ?? '';
    final payload = envelope['payload'] as Map<String, dynamic>? ?? {};
    final gossipId = payload['gossip_id'] as String? ?? '';

    if (gossipId.isEmpty) return;
    if (!await PacketVerifier.verifyGossipPayload(payload)) return;
    if (!markSeen(gossipId)) return;

    final ptype = payload['ptype'] as String?;
    final originId = payload['origin_id'] as String? ?? '';
    final originName = payload['origin_name'] as String? ?? 'Unknown';

    if (ptype == 'group_text') {
      final groupIds = List<String>.from(payload['group_ids'] as List? ?? []);
      if (groupIds.contains(myId) && originId != myId) {
        final kv = (payload['key_version'] as num?)?.toInt() ?? 0;
        final groupId = payload['group_id'] as String? ?? '';
        final sk = fetchRemoteSenderKey(groupId, originId, kv);
        if (sk != null) {
          try {
            final skKey = SecretKey(sk);
            final aad = utf8.encode('$groupId:$kv');
            final nonce = CryptoUtils.b64d(payload['nonce'] as String);
            final ct = CryptoUtils.b64d(payload['ciphertext'] as String);
            final plain =
                await CryptoUtils.aesDecrypt(skKey, nonce, ct, aad);
            final text = utf8.decode(plain);
            onGroupMessage?.call(
                originId, originName, text, groupId, groupIds);
          } catch (_) {
            onLog?.call(
                '[GROUP] Не удалось расшифровать сообщение от $originName');
          }
        } else {
          onLog?.call('[GROUP] Нет sender key v$kv от $originName');
        }
      }
    }

    if (ttl > 1) {
      final fwd = Map<String, dynamic>.from(envelope)..['ttl'] = ttl - 1;
      await spread(peers, fwd, myId, excludeIds: {myId, relayId});
    }
  }
}
