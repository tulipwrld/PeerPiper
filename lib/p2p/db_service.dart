// lib/p2p/db_service.dart
//
// Mirrors Python SQLite layer: messages, pending_forward (DTN),
// file_transfers, file_chunks, peer_metrics_log.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class DbService {
  static Database? _db;

  static Future<Database> get db async {
    if (_db != null) return _db!;
    _db = await _open();
    return _db!;
  }

  static Future<Database> _open() async {
    // Use sqflite_ffi on desktop platforms
    if (!kIsWeb && (Platform.isLinux || Platform.isWindows)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, 'p2pchat.db');

    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE messages (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            msg_id      TEXT UNIQUE,
            peer_id     TEXT NOT NULL,
            sender_name TEXT,
            sender_id   TEXT,
            body        TEXT,
            timestamp   TEXT,
            delivered   INTEGER DEFAULT 0
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_msg_peer ON messages(peer_id)');

        await db.execute('''
          CREATE TABLE pending_forward (
            gossip_id    TEXT PRIMARY KEY,
            recipient_id TEXT NOT NULL,
            envelope_json TEXT NOT NULL,
            created_at   INTEGER NOT NULL,
            expire_at    INTEGER NOT NULL,
            attempts     INTEGER DEFAULT 0
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_pf_recipient ON pending_forward(recipient_id)');

        await db.execute('''
          CREATE TABLE file_transfers (
            transfer_id  TEXT PRIMARY KEY,
            peer_id      TEXT,
            filename     TEXT,
            total_chunks INTEGER,
            file_hash    TEXT,
            direction    TEXT,
            created_at   INTEGER,
            completed    INTEGER DEFAULT 0
          )
        ''');

        await db.execute('''
          CREATE TABLE file_chunks (
            transfer_id TEXT,
            chunk_idx   INTEGER,
            data        BLOB,
            chunk_hash  TEXT,
            PRIMARY KEY (transfer_id, chunk_idx)
          )
        ''');

        await db.execute('''
          CREATE TABLE peer_metrics_log (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            peer_id    TEXT,
            rtt_ms     REAL,
            jitter_ms  REAL,
            loss_pct   REAL,
            ts         INTEGER
          )
        ''');
      },
    );
  }

  // â”€â”€ Messages â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  static Future<String> saveMessage({
    required String peerId,
    required String senderName,
    required String senderId,
    required String body,
    String? msgId,
    int delivered = 1,
  }) async {
    final id = msgId ?? _uuid();
    final ts = _nowTs();
    try {
      await (await db).insert(
        'messages',
        {
          'msg_id': id,
          'peer_id': peerId,
          'sender_name': senderName,
          'sender_id': senderId,
          'body': body,
          'timestamp': ts,
          'delivered': delivered,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    } catch (_) {}
    return id;
  }

  static Future<void> markDelivered(String msgId) async {
    await (await db).update(
      'messages',
      {'delivered': 1},
      where: 'msg_id = ?',
      whereArgs: [msgId],
    );
  }

  static Future<void> markFailed(String msgId) async {
    await (await db).update(
      'messages',
      {'delivered': -1},
      where: 'msg_id = ?',
      whereArgs: [msgId],
    );
  }

  
  static Future<List<Map<String, dynamic>>> getRecentMessages({int limit = 200}) async {
    return (await db).query(
      'messages',
      orderBy: 'id DESC',
      limit: limit,
    );
  }

  // â”€â”€ DTN pending_forward â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  static Future<void> storeForward({
    required String gossipId,
    required String recipientId,
    required String envelopeJson,
  }) async {
    final now = _epoch();
    try {
      await (await db).insert(
        'pending_forward',
        {
          'gossip_id': gossipId,
          'recipient_id': recipientId,
          'envelope_json': envelopeJson,
          'created_at': now,
          'expire_at': now + 7 * 24 * 3600,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    } catch (_) {}
  }

  static Future<List<Map<String, dynamic>>> getPendingForward(
      String recipientId) async {
    return (await db).query(
      'pending_forward',
      where: 'recipient_id = ? AND expire_at > ?',
      whereArgs: [recipientId, _epoch()],
      orderBy: 'created_at ASC',
    );
  }

  static Future<void> deletePendingForward(String gossipId) async {
    await (await db).delete(
      'pending_forward',
      where: 'gossip_id = ?',
      whereArgs: [gossipId],
    );
  }

  static Future<void> cleanupExpiredForward() async {
    await (await db).delete(
      'pending_forward',
      where: 'expire_at < ?',
      whereArgs: [_epoch()],
    );
  }

  // â”€â”€ File transfers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  static Future<void> createTransfer({
    required String transferId,
    required String peerId,
    required String filename,
    required int totalChunks,
    required String fileHash,
    required String direction,
  }) async {
    try {
      await (await db).insert(
        'file_transfers',
        {
          'transfer_id': transferId,
          'peer_id': peerId,
          'filename': filename,
          'total_chunks': totalChunks,
          'file_hash': fileHash,
          'direction': direction,
          'created_at': _epoch(),
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    } catch (_) {}
  }

  static Future<void> storeChunk(
      String transferId, int chunkIdx, Uint8List data, String hash) async {
    await (await db).insert(
      'file_chunks',
      {
        'transfer_id': transferId,
        'chunk_idx': chunkIdx,
        'data': data,
        'chunk_hash': hash,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<Set<int>> getReceivedChunkIndices(String transferId) async {
    final rows = await (await db).query(
      'file_chunks',
      columns: ['chunk_idx'],
      where: 'transfer_id = ?',
      whereArgs: [transferId],
    );
    return rows.map((r) => r['chunk_idx'] as int).toSet();
  }

  static Future<Map<int, List<int>>> getAllChunks(String transferId) async {
    final rows = await (await db).query(
      'file_chunks',
      where: 'transfer_id = ?',
      whereArgs: [transferId],
      orderBy: 'chunk_idx ASC',
    );
    return {
      for (final r in rows)
        (r['chunk_idx'] as int): _blobToList(r['data'])
    };
  }

  static List<int> _blobToList(Object? v) {
    if (v is Uint8List) return v;
    if (v is List<int>) return v;
    if (v is List) return List<int>.from(v);
    return const <int>[];
  }

  static Future<void> completeTransfer(String transferId) async {
    await (await db).update(
      'file_transfers',
      {'completed': 1},
      where: 'transfer_id = ?',
      whereArgs: [transferId],
    );
  }

  static Future<Map<String, dynamic>?> getTransfer(String transferId) async {
    final rows = await (await db).query(
      'file_transfers',
      where: 'transfer_id = ?',
      whereArgs: [transferId],
    );
    return rows.isEmpty ? null : rows.first;
  }

  // â”€â”€ Metrics â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  static Future<void> logMetric(
      String peerId, double rttMs,
      {double jitterMs = 0, double lossPct = 0}) async {
    await (await db).insert('peer_metrics_log', {
      'peer_id': peerId,
      'rtt_ms': rttMs,
      'jitter_ms': jitterMs,
      'loss_pct': lossPct,
      'ts': _epoch(),
    });
  }

  static Future<List<Map<String, dynamic>>> getAggregatedMetrics() async {
    return (await db).rawQuery('''
      SELECT peer_id,
             AVG(rtt_ms)    AS avg_rtt,
             AVG(jitter_ms) AS avg_jitter,
             AVG(loss_pct)  AS avg_loss,
             COUNT(*)       AS n
      FROM peer_metrics_log
      GROUP BY peer_id
    ''');
  }

  // â”€â”€ Helpers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  static int _epoch() =>
      DateTime.now().millisecondsSinceEpoch ~/ 1000;

  static String _nowTs() {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
  }

  static int _uuidCounter = 0;
  static String _uuid() {
    _uuidCounter++;
    return DateTime.now().microsecondsSinceEpoch.toRadixString(16) +
        _uuidCounter.toRadixString(16).padLeft(8, '0');
  }
}
