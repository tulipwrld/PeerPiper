// lib/p2p/tcp_transport.dart
//
// Mirrors Python asyncio TCP server + send_packet().
// Wire format: [ 4B big-endian header_len ] [ JSON header bytes ] [ optional binary payload ]
//
// CHANGED: PacketHandler now receives sourceIp — used by Sybil handler to
// respond to challenge_response even before mDNS resolves the peer's IP.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const kChatPort = 5005;
const _kConnectTimeout = Duration(seconds: 4);
const _kMaxHeaderLen = 65535;

/// Handler now receives (header, binaryPayload, sourceIp).
typedef PacketHandler = Future<void> Function(
    Map<String, dynamic> header, Uint8List payload, String sourceIp);

// ── TCP Server ─────────────────────────────────────────────────────────────
class TcpServer {
  ServerSocket? _server;
  PacketHandler? onPacket;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, kChatPort,
        shared: true);
    _server!.listen(_handleClient, onError: (_) {});
  }

  void _handleClient(Socket socket) {
    final sourceIp = socket.remoteAddress.address;
    final buffer = <int>[];
    socket.listen(
      (data) {
        buffer.addAll(data);
        _process(buffer, socket, sourceIp);
      },
      onDone: () => socket.destroy(),
      onError: (_) => socket.destroy(),
    );
  }

  void _process(List<int> buf, Socket socket, String sourceIp) {
    while (true) {
      if (buf.length < 4) return;
      final headerLen = ByteData.sublistView(
              Uint8List.fromList(buf.sublist(0, 4)))
          .getUint32(0, Endian.big);
      if (headerLen <= 0 || headerLen > _kMaxHeaderLen) {
        buf.clear();
        return;
      }
      if (buf.length < 4 + headerLen) return;

      final headerBytes = buf.sublist(4, 4 + headerLen);
      final Map<String, dynamic> header;
      try {
        header = jsonDecode(utf8.decode(headerBytes)) as Map<String, dynamic>;
      } catch (_) {
        buf.removeRange(0, 4 + headerLen);
        continue;
      }

      final payloadLen = _payloadLen(header);
      if (buf.length < 4 + headerLen + payloadLen) return;

      final payload = Uint8List.fromList(
          buf.sublist(4 + headerLen, 4 + headerLen + payloadLen));
      buf.removeRange(0, 4 + headerLen + payloadLen);

      onPacket?.call(header, payload, sourceIp);
    }
  }

  int _payloadLen(Map<String, dynamic> h) {
    if (h['kind'] == 'file_chunk') {
      return (h['chunk_size_enc'] as num?)?.toInt() ?? 0;
    }
    return 0;
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }
}

// ── TCP Client ─────────────────────────────────────────────────────────────
class TcpClient {
  static Future<String> sendPacket(
    List<String> ips,
    Map<String, dynamic> header, [
    List<int>? payload,
  ]) async {
    final hBytes = utf8.encode(jsonEncode(header));
    if (hBytes.length > _kMaxHeaderLen) {
      throw ArgumentError('Header too large');
    }
    final lenBytes = Uint8List(4)
      ..buffer.asByteData().setUint32(0, hBytes.length, Endian.big);

    Object? lastError;
    for (final ip in ips) {
      try {
        final socket =
            await Socket.connect(ip, kChatPort, timeout: _kConnectTimeout);
        socket.add(lenBytes);
        socket.add(hBytes);
        if (payload != null && payload.isNotEmpty) {
          socket.add(payload);
        }
        await socket.flush();
        await socket.close();
        socket.destroy();
        return ip;
      } catch (e) {
        lastError = e;
      }
    }
    throw ConnectionException('Unreachable $ips: $lastError');
  }
}

class ConnectionException implements Exception {
  final String message;
  ConnectionException(this.message);
  @override
  String toString() => message;
}