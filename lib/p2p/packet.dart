// lib/p2p/packet.dart
//
// Mirrors Python build_signed_header() / verify_signed_header()
// and all packet kind constants.
//
// Wire format (same as Python):
//   [ 4 bytes big-endian header_length ] [ JSON header bytes ] [ optional binary payload ]

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'crypto_utils.dart';

// ── Packet kind constants ──────────────────────────────────────────────────
const kPing              = 'ping';
const kPong              = 'pong';
const kAck               = 'ack';
const kE2eeText          = 'e2ee_text';
const kE2eeLlm           = 'e2ee_llm';
const kE2eeFile          = 'e2ee_file';  // legacy single-packet (not used)
const kFileStart         = 'file_start';
const kFileChunk         = 'file_chunk';
const kFileComplete      = 'file_complete';
const kFileResumeRequest = 'file_resume_request';
const kCallSignal        = 'e2ee_call_signal';
const kGossipSenderKey   = 'gossip_sender_key';
const kGossipGroupText   = 'gossip_group_text';
const kStoreForward      = 'store_forward';
const kPeerChallenge     = 'peer_challenge';
const kPeerChallengeResp = 'peer_challenge_response';

// ── Packet builder ─────────────────────────────────────────────────────────
class PacketBuilder {
  final SimpleKeyPair _signKp;
  final String _myId;
  final String _myName;
  final String _myXPubHex;
  final SimpleKeyPair _myXKp;

  PacketBuilder({
    required SimpleKeyPair signKeyPair,
    required String myId,
    required String myName,
    required String myXPubHex,
    required SimpleKeyPair myXKeyPair,
  })  : _signKp = signKeyPair,
        _myId = myId,
        _myName = myName,
        _myXPubHex = myXPubHex,
        _myXKp = myXKeyPair;

  // ── Build + sign a header dict ────────────────────────────────────────────
  Future<Map<String, dynamic>> build(
      String kind, Map<String, dynamic> fields) async {
    final h = <String, dynamic>{
      'kind': kind,
      'sender_id': _myId,
      'sender_name': _myName,
      ...fields,
    };
    h['sig'] = await CryptoUtils.signDict(h, _signKp);
    return h;
  }

  // ── Gossip payload builder (origin-signed) ────────────────────────────────
  Future<Map<String, dynamic>> buildGossipPayload(
      Map<String, dynamic> fields) async {
    final p = <String, dynamic>{
      'origin_id': _myId,
      'origin_name': _myName,
      ...fields,
    };
    p['sig'] = await CryptoUtils.signDict(p, _signKp);
    return p;
  }

  // ── Wire serialisation ────────────────────────────────────────────────────
  /// Returns the bytes to write to the TCP socket:
  ///   [ 4B big-endian header_len ] [ JSON header bytes ] [ optional payload ]
  static Uint8List serialise(
      Map<String, dynamic> header, [List<int>? payload]) {
    final hBytes = utf8.encode(jsonEncode(header));
    final lenBytes = Uint8List(4)
      ..buffer.asByteData().setUint32(0, hBytes.length, Endian.big);
    if (payload == null || payload.isEmpty) {
      return Uint8List.fromList([...lenBytes, ...hBytes]);
    }
    return Uint8List.fromList([...lenBytes, ...hBytes, ...payload]);
  }

  // ── E2EE text ─────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> e2eeText(
      String peerXPubHex, String text, String msgId) async {
    final key = await CryptoUtils.derivePairwiseKey(
        _myXKp, peerXPubHex, utf8.encode('direct-text-v1'));
    final (nonce, ct) =
        await CryptoUtils.aesEncrypt(key, utf8.encode(text), utf8.encode('text'));
    return build(kE2eeText, {
      'sender_xpub': _myXPubHex,
      'nonce': CryptoUtils.b64e(nonce),
      'ciphertext': CryptoUtils.b64e(ct),
      'msg_id': msgId,
    });
  }

  // ── E2EE LLM ─────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> e2eeLlm(
      String peerXPubHex, Map<String, dynamic> body) async {
    final key = await CryptoUtils.derivePairwiseKey(
        _myXKp, peerXPubHex, utf8.encode('llm-text-v1'));
    final payload = utf8.encode(jsonEncode(body));
    final (nonce, ct) =
        await CryptoUtils.aesEncrypt(key, payload, utf8.encode('llm'));
    return build(kE2eeLlm, {
      'sender_xpub': _myXPubHex,
      'nonce': CryptoUtils.b64e(nonce),
      'ciphertext': CryptoUtils.b64e(ct),
    });
  }

  // ── ACK ───────────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> ack(String msgId) async {
    return build(kAck, {'msg_id': msgId});
  }

  // ── Ping / Pong ───────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> ping(String pingId) async {
    return build(kPing, {'ping_id': pingId});
  }

  Future<Map<String, dynamic>> pong(String pingId) async {
    return build(kPong, {'ping_id': pingId});
  }

  // ── Peer challenge ────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> peerChallenge(String challengeId) async {
    return build(kPeerChallenge, {
      'sender_xpub': _myXPubHex,
      'challenge_id': challengeId,
    });
  }

  Future<Map<String, dynamic>> peerChallengeResponse(
      String challengeId) async {
    return build(kPeerChallengeResp, {
      'sender_xpub': _myXPubHex,
      'challenge_id': challengeId,
    });
  }

  // ── File transfer headers ─────────────────────────────────────────────────
  Future<Map<String, dynamic>> fileStart({
    required String peerXPubHex,
    required String transferId,
    required String filename,
    required String category,
    required int totalChunks,
    required String fileHash,
    required int sizePlain,
    required String wrapNonce,
    required String wrapCt,
  }) async {
    return build(kFileStart, {
      'sender_xpub': _myXPubHex,
      'transfer_id': transferId,
      'filename': filename,
      'category': category,
      'total_chunks': totalChunks,
      'chunk_size': 65536,
      'file_hash': fileHash,
      'size_plain': sizePlain,
      'wrap_nonce': wrapNonce,
      'wrap_ct': wrapCt,
    });
  }

  Future<Map<String, dynamic>> fileChunk({
    required String transferId,
    required int chunkIdx,
    required int totalChunks,
    required String chunkHash,
    required int chunkSizeEnc,
    required String chunkNonce,
  }) async {
    return build(kFileChunk, {
      'sender_xpub': _myXPubHex,
      'transfer_id': transferId,
      'chunk_idx': chunkIdx,
      'total_chunks': totalChunks,
      'chunk_hash': chunkHash,
      'chunk_size_enc': chunkSizeEnc,
      'chunk_nonce': chunkNonce,
    });
  }

  Future<Map<String, dynamic>> fileComplete({
    required String transferId,
    required String fileHash,
    required int totalChunks,
  }) async {
    return build(kFileComplete, {
      'sender_xpub': _myXPubHex,
      'transfer_id': transferId,
      'file_hash': fileHash,
      'total_chunks': totalChunks,
    });
  }

  Future<Map<String, dynamic>> fileResumeRequest({
    required String transferId,
    required List<int> missingChunks,
  }) async {
    return build(kFileResumeRequest, {
      'sender_xpub': _myXPubHex,
      'transfer_id': transferId,
      'missing_chunks': missingChunks,
    });
  }

  // ── Call signal ───────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> callSignal(
      String peerXPubHex, String signalType, Map<String, dynamic> data) async {
    final key = await CryptoUtils.derivePairwiseKey(
        _myXKp, peerXPubHex, utf8.encode('call-signal-v1'));
    final payload = utf8.encode(jsonEncode({'type': signalType, 'data': data}));
    final (nonce, ct) =
        await CryptoUtils.aesEncrypt(key, payload, utf8.encode('call'));
    return build(kCallSignal, {
      'sender_xpub': _myXPubHex,
      'nonce': CryptoUtils.b64e(nonce),
      'ciphertext': CryptoUtils.b64e(ct),
    });
  }
}

// ── Packet verifier ────────────────────────────────────────────────────────
class PacketVerifier {
  /// Verify header signature (sender_id is the Ed25519 pubkey).
  static Future<bool> verifyHeader(Map<String, dynamic> header) async {
    final sig = header['sig'] as String?;
    final senderId = header['sender_id'] as String?;
    if (sig == null || senderId == null || senderId.isEmpty) return false;
    final payload = Map<String, dynamic>.from(header)..remove('sig');
    return CryptoUtils.verifyDictSig(payload, sig, senderId);
  }

  /// Verify gossip payload signature (origin_id is the Ed25519 pubkey).
  static Future<bool> verifyGossipPayload(Map<String, dynamic> p) async {
    final sig = p['sig'] as String?;
    final originId = p['origin_id'] as String?;
    if (sig == null || originId == null || originId.isEmpty) return false;
    final payload = Map<String, dynamic>.from(p)..remove('sig');
    return CryptoUtils.verifyDictSig(payload, sig, originId);
  }
}
