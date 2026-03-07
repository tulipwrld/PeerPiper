// lib/p2p/file_transfer.dart
//
// Mirrors Python send_file() / _handle_file_* / _resume_interrupted_transfers().
// Chunk size: 64 KB. SHA-256 per chunk + full file. Adaptive throttle.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'crypto_utils.dart';
import 'db_service.dart';
import 'packet.dart';
import 'tcp_transport.dart';

const _kChunkSize = 65536; // 64 KB
const _kMaxFileSize = 200 * 1024 * 1024;

// State for outgoing transfers (in-memory, survives reconnect if raw chunks kept)
class _OutTransfer {
  final String peerId;
  final String fileHash;
  final int total;
  final SecretKey fileKey;
  final String wrapNonce;
  final String wrapCt;
  final List<Uint8List> rawChunks;
  int lastSentIdx = -1;
  bool interrupted = false;

  _OutTransfer({
    required this.peerId,
    required this.fileHash,
    required this.total,
    required this.fileKey,
    required this.wrapNonce,
    required this.wrapCt,
    required this.rawChunks,
  });
}

// State for incoming transfers
class _InTransfer {
  final String senderId;
  final String senderName;
  final String senderXpub;
  final String filename;
  final int totalChunks;
  final String fileHash;
  final String category;
  final int sizePlain;
  final String wrapNonce;
  final String wrapCt;

  _InTransfer({
    required this.senderId,
    required this.senderName,
    required this.senderXpub,
    required this.filename,
    required this.totalChunks,
    required this.fileHash,
    required this.category,
    required this.sizePlain,
    required this.wrapNonce,
    required this.wrapCt,
  });
}

typedef ActiveCallCheck = bool Function();
typedef PeerLookup = Map<String, dynamic>? Function(String uid);

class FileTransferService {
  final Map<String, _OutTransfer> _outTransfers = {};
  final Map<String, _InTransfer> _inTransfers = {};
  final Set<String> _unknownTransferLogged = {};

  /// True when a call is active — reduces throughput to protect call channel.
  ActiveCallCheck hasActiveCall = () => false;
  PeerLookup lookupPeer = (_) => null;

  void Function(String transferId, String filename, int received, int total)?
      onProgress;
  void Function(String transferId, String filename, Uint8List data,
      String hash, String senderId, String senderName)? onComplete;
  void Function(String message)? onLog;

  // ── Send file ──────────────────────────────────────────────────────────────
  Future<void> sendFile({
    required Map<String, dynamic> peer,
    required String peerId,
    required String filename,
    required Uint8List data,
    required String myId,
    required String myName,
    required String myXPubHex,
    required SimpleKeyPair myXKp,
    required SecretKey masterKey,
    required PacketBuilder pktBuilder,
  }) async {
    if (data.length > _kMaxFileSize) {
      throw Exception(
          'Файл слишком большой (${data.length} bytes, лимит $_kMaxFileSize)');
    }

    final peerXpub = peer['xpub'] as String;
    final fileHash = CryptoUtils.sha256Hex(data);
    final transferId = const Uuid().v4().replaceAll('-', '');
    final category = _classifyFile(filename);

    // Ephemeral file key
    final fileKey = SecretKey(CryptoUtils.randomBytes(32).toList());
    final pairKey = await CryptoUtils.derivePairwiseKey(
        myXKp, peerXpub, utf8.encode('direct-file-wrap-v1'));
    final (wrapNonce, wrapCt) = await CryptoUtils.aesEncrypt(
        pairKey, await fileKey.extractBytes(), utf8.encode('wrap'));

    // Chunk the file
    final rawChunks = <Uint8List>[];
    for (var i = 0; i < data.length; i += _kChunkSize) {
      rawChunks.add(data.sublist(i,
          (i + _kChunkSize > data.length) ? data.length : i + _kChunkSize));
    }
    final total = rawChunks.length;

    onLog?.call(
        '[FILE] $filename → ${peer['name']} | ${data.length} bytes | $total чанков');

    // Send file_start
    final startHeader = await pktBuilder.fileStart(
      peerXPubHex: peerXpub,
      transferId: transferId,
      filename: p.basename(filename),
      category: category,
      totalChunks: total,
      fileHash: fileHash,
      sizePlain: data.length,
      wrapNonce: CryptoUtils.b64e(wrapNonce),
      wrapCt: CryptoUtils.b64e(wrapCt),
    );
    await TcpClient.sendPacket(List<String>.from(peer['ips'] as List), startHeader);

    // Register transfer
    final outState = _OutTransfer(
      peerId: peerId,
      fileHash: fileHash,
      total: total,
      fileKey: fileKey,
      wrapNonce: CryptoUtils.b64e(wrapNonce),
      wrapCt: CryptoUtils.b64e(wrapCt),
      rawChunks: rawChunks,
    );
    _outTransfers[transferId] = outState;
    await DbService.createTransfer(
      transferId: transferId,
      peerId: peerId,
      filename: filename,
      totalChunks: total,
      fileHash: fileHash,
      direction: 'out',
    );

    // Send chunks
    final interrupted = await _sendChunks(
        outState, transferId, total, rawChunks,
        peer: peer, pktBuilder: pktBuilder, fileKey: fileKey);

    if (interrupted) {
      onLog?.call(
          '[FILE] Передача прервана на чанке ${outState.lastSentIdx + 1}/$total. Возобновится при переподключении.');
      return;
    }

    // Send file_complete
    final completeHeader = await pktBuilder.fileComplete(
        transferId: transferId, fileHash: fileHash, totalChunks: total);
    await TcpClient.sendPacket(
        List<String>.from(peer['ips'] as List), completeHeader);

    // Cache in CAS
    await _saveToCas(masterKey, data, fileHash);

    await DbService.completeTransfer(transferId);
    onLog?.call('[FILE] ✓ $filename отправлен (${data.length} bytes)');
  }

  Future<bool> _sendChunks(
    _OutTransfer state,
    String transferId,
    int total,
    List<Uint8List> rawChunks, {
    int startIdx = 0,
    required Map<String, dynamic> peer,
    required PacketBuilder pktBuilder,
    required SecretKey fileKey,
  }) async {
    for (var localIdx = 0; localIdx < rawChunks.length; localIdx++) {
      final idx = startIdx + localIdx;
      final chunk = rawChunks[localIdx];
      // Encrypt once — nonce is generated inside aesEncrypt and returned
      final (nonce, enc) = await CryptoUtils.aesEncrypt(
          fileKey, chunk, utf8.encode('$transferId:$idx'));
      final realHeader = await pktBuilder.fileChunk(
        transferId: transferId,
        chunkIdx: idx,
        totalChunks: total,
        chunkHash: CryptoUtils.sha256Hex(chunk),
        chunkSizeEnc: enc.length,
        chunkNonce: CryptoUtils.b64e(nonce),
      );

      var sentOk = false;
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          await TcpClient.sendPacket(
              List<String>.from(peer['ips'] as List), realHeader, enc);
          sentOk = true;
          break;
        } catch (_) {
          await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
        }
      }
      if (!sentOk) {
        state.interrupted = true;
        state.lastSentIdx = idx - 1;
        return true;
      }
      state.lastSentIdx = idx;

      if (total >= 20 && (idx + 1) % (total ~/ 10).clamp(1, total) == 0) {
        onProgress?.call(transferId, '', idx + 1, total);
      }

      // Adaptive throttle: yield to call traffic
      await Future.delayed(
          Duration(milliseconds: hasActiveCall() ? 100 : 16));
    }
    return false;
  }

  // ── Resume interrupted outgoing transfers ─────────────────────────────────
  Future<void> resumeInterruptedTransfers(
      String peerId, PacketBuilder pktBuilder) async {
    await Future.delayed(const Duration(seconds: 2));
    final peer = lookupPeer(peerId);
    if (peer == null) return;

    for (final entry in _outTransfers.entries) {
      final tid = entry.key;
      final state = entry.value;
      if (state.peerId != peerId || !state.interrupted) continue;

      onLog?.call(
          '[FILE RESUME] ${tid.substring(0, 12)} с чанка ${state.lastSentIdx + 1}/${state.total}');

      final remainingChunks =
          state.rawChunks.sublist(state.lastSentIdx + 1);
      final interruptedAgain = await _sendChunks(
        state,
        tid,
        state.total,
        remainingChunks,
        startIdx: state.lastSentIdx + 1,
        peer: peer,
        pktBuilder: pktBuilder,
        fileKey: state.fileKey,
      );

      if (interruptedAgain) continue;

      // Send file_complete
      final transfer = await DbService.getTransfer(tid);
      if (transfer == null) continue;
      final completeHeader = await pktBuilder.fileComplete(
        transferId: tid,
        fileHash: state.fileHash,
        totalChunks: state.total,
      );
      try {
        await TcpClient.sendPacket(
            List<String>.from(peer['ips'] as List), completeHeader);
        state.interrupted = false;
        await DbService.completeTransfer(tid);
        onLog?.call(
            '[FILE RESUME] ✓ ${transfer['filename']} завершён после resume');
      } catch (e) {
        onLog?.call('[FILE RESUME] Ошибка file_complete: $e');
      }
    }
  }

  // ── Handle incoming file_start ─────────────────────────────────────────────
  Future<void> handleFileStart(
      Map<String, dynamic> header, String senderId, String senderName) async {
    final tid = header['transfer_id'] as String;
    _inTransfers[tid] = _InTransfer(
      senderId: senderId,
      senderName: senderName,
      senderXpub: header['sender_xpub'] as String,
      filename: p.basename(header['filename'] as String? ?? 'file.bin'),
      totalChunks: (header['total_chunks'] as num).toInt(),
      fileHash: header['file_hash'] as String,
      category: header['category'] as String? ?? 'file',
      sizePlain: (header['size_plain'] as num?)?.toInt() ?? 0,
      wrapNonce: header['wrap_nonce'] as String,
      wrapCt: header['wrap_ct'] as String,
    );
    await DbService.createTransfer(
      transferId: tid,
      peerId: senderId,
      filename: _inTransfers[tid]!.filename,
      totalChunks: _inTransfers[tid]!.totalChunks,
      fileHash: _inTransfers[tid]!.fileHash,
      direction: 'in',
    );
    onLog?.call(
        '[FILE] Входящий $tid от $senderName: ${_inTransfers[tid]!.filename} (${_inTransfers[tid]!.totalChunks} чанков)');
  }

  // ── Handle incoming file_chunk ─────────────────────────────────────────────
  Future<void> handleFileChunk(
      Map<String, dynamic> header, Uint8List payload, SimpleKeyPair myXKp) async {
    final tid = header['transfer_id'] as String;
    final idx = (header['chunk_idx'] as num).toInt();
    final state = _inTransfers[tid];
    if (state == null) {
      if (_unknownTransferLogged.add(tid)) {
        onLog?.call('[FILE] Неизвестный transfer_id ${tid.substring(0, 12)}');
      }
      return;
    }

    try {
      final pairKey = await CryptoUtils.derivePairwiseKey(
          myXKp, state.senderXpub, utf8.encode('direct-file-wrap-v1'));
      final wrapNonce = CryptoUtils.b64d(state.wrapNonce);
      final wrapCt = CryptoUtils.b64d(state.wrapCt);
      final fileKeyBytes =
          await CryptoUtils.aesDecrypt(pairKey, wrapNonce, wrapCt, utf8.encode('wrap'));
      final fileKey = SecretKey(fileKeyBytes);

      final chunkNonce = CryptoUtils.b64d(header['chunk_nonce'] as String);
      final chunkData = await CryptoUtils.aesDecrypt(
          fileKey, chunkNonce, payload, utf8.encode('$tid:$idx'));

      final expectedHash = header['chunk_hash'] as String?;
      if (expectedHash != null &&
          CryptoUtils.sha256Hex(chunkData) != expectedHash) {
        onLog?.call('[FILE] Чанк $idx: hash mismatch');
        return;
      }

      await DbService.storeChunk(
          tid, idx, chunkData, CryptoUtils.sha256Hex(chunkData));

      final received = (await DbService.getReceivedChunkIndices(tid)).length;
      onProgress?.call(tid, state.filename, received, state.totalChunks);
    } catch (e) {
      onLog?.call('[FILE] Ошибка расшифровки чанка $idx: ${_safeErr(e)}');
    }
  }

  // ── Handle incoming file_complete ──────────────────────────────────────────
  Future<void> handleFileComplete(
    Map<String, dynamic> header,
    String senderId,
    String senderName,
    SimpleKeyPair myXKp,
    SecretKey masterKey,
    PacketBuilder pktBuilder,
  ) async {
    final tid = header['transfer_id'] as String;
    final expectedHash = header['file_hash'] as String;
    final total = (header['total_chunks'] as num).toInt();
    final state = _inTransfers[tid];
    if (state == null) return;

    final receivedIndices = await DbService.getReceivedChunkIndices(tid);
    final missing = List<int>.generate(total, (i) => i)
        .where((i) => !receivedIndices.contains(i))
        .toList();

    if (missing.isNotEmpty) {
      onLog?.call(
          '[FILE] Не хватает ${missing.length} чанков: ${missing.take(5)}…');
      final peer = lookupPeer(senderId);
      if (peer != null) {
        final req = await pktBuilder.fileResumeRequest(
            transferId: tid, missingChunks: missing);
        try {
          await TcpClient.sendPacket(
              List<String>.from(peer['ips'] as List), req);
        } catch (_) {}
      }
      return;
    }

    // Reassemble
    final chunksMap = await DbService.getAllChunks(tid);
    final plainBytes = <int>[];
    for (var i = 0; i < total; i++) {
      plainBytes.addAll(chunksMap[i] ?? []);
    }
    final plain = Uint8List.fromList(plainBytes);
    final actualHash = CryptoUtils.sha256Hex(plain);

    if (actualHash != expectedHash) {
      onLog?.call('[FILE] ОШИБКА: контрольная сумма не совпала!');
      return;
    }

    await DbService.completeTransfer(tid);
    _inTransfers.remove(tid);

    // Save to CAS
    await _saveToCas(masterKey, plain, actualHash);

    onLog?.call(
        '[FILE] ✓ ${state.filename} от $senderName (${plain.length} bytes) | sha256=${actualHash.substring(0, 16)}…');
    onComplete?.call(tid, state.filename, plain, actualHash, senderId, senderName);
  }

  // ── CAS storage ───────────────────────────────────────────────────────────
  Future<void> _saveToCas(
      SecretKey masterKey, Uint8List plain, String hash) async {
    final dir = await _casDir();
    final file = File(p.join(dir.path, hash));
    if (!file.existsSync()) {
      final encrypted = await CryptoUtils.encryptForDisk(masterKey, plain);
      await file.writeAsBytes(encrypted);
    }
  }

  Future<Uint8List?> getFromCas(SecretKey masterKey, String hash) async {
    final dir = await _casDir();
    final file = File(p.join(dir.path, hash));
    if (!file.existsSync()) return null;
    return CryptoUtils.decryptFromDisk(masterKey, await file.readAsBytes());
  }

  static Future<Directory> _casDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'media_cas'));
    await dir.create(recursive: true);
    return dir;
  }

  // ── File classification ───────────────────────────────────────────────────
  static String _classifyFile(String filename) {
    final ext = p.extension(filename).toLowerCase();
    if ({'.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic'}
        .contains(ext)) return 'photo';
    if ({'.mp4', '.mov', '.avi', '.mkv', '.webm', '.m4v'}.contains(ext))
      return 'video';
    if ({'.ogg', '.opus', '.m4a', '.wav', '.mp3', '.aac', '.flac'}
        .contains(ext)) return 'voice';
    return 'file';
  }

  static String _safeErr(Object e) {
    final msg = e.toString();
    if (msg.length > 180) {
      return '${e.runtimeType}: ${msg.substring(0, 180)}...';
    }
    return '${e.runtimeType}: $msg';
  }
}
