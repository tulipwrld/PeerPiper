// lib/p2p/discovery_service.dart
//
// Bonsoir mDNS — bonsoir ^6.0.x compatible.
//
// ROOT FIX: On Windows (and many Android setups) Bonsoir resolves
// host=NULL.  Rather than fighting mDNS hostname resolution we embed
// our own IP address directly in the TXT record (`attributes['ip']`).
// The remote peer reads that field — no DNS lookup required.
//
// Secondary fallback: if 'ip' attribute is absent, we try
// InternetAddress.lookup(rawHost) and then the TCP sourceIp path.

import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';

const _kServiceType = '_p2pchat._tcp';

typedef PeerFoundCallback = void Function(
    String uid, List<String> ips, String name, String xpub, bool aiHost);
typedef PeerLostCallback = void Function(String uid);

class DiscoveryService {
  BonsoirDiscovery? _discovery;
  BonsoirBroadcast? _broadcast;

  PeerFoundCallback? onPeerFound;
  PeerLostCallback? onPeerLost;
  void Function(String)? onLog;

  final Map<String, String> _nameToUid  = {};
  final Map<String, String> _fingerprint = {};

  // ── Advertise — IP is embedded in TXT attributes ──────────────────────────
  Future<void> advertise({
    required String myName,
    required String myId,
    required String myXPubHex,
    required int    port,
    String?         myIp,       // ← injected by RealP2PService
    bool aiHost = false,
  }) async {
    try {
      // If caller didn't supply an IP, discover one ourselves.
      final ip = myIp ?? await _findLocalIp();

      final svc = BonsoirService(
        name: '$myName-${myId.substring(0, 12)}',
        type: _kServiceType,
        port: port,
        attributes: {
          'uid':  myId,
          'name': myName,
          'xpub': myXPubHex,
          'ai': aiHost ? '1' : '0',
          if (ip != null) 'ip': ip,   // ← THE FIX
        },
      );

      _broadcast = BonsoirBroadcast(service: svc);
      await _broadcast!.ready;
      await _broadcast!.start();
      onLog?.call('[DISCOVERY] advertise OK port=$port ip=${ip ?? "?"}');
    } catch (e) {
      onLog?.call('[DISCOVERY] advertise ERROR: $e');
    }
  }

  // ── Browse ────────────────────────────────────────────────────────────────
  Future<void> startBrowsing() async {
    try {
      _discovery = BonsoirDiscovery(type: _kServiceType);
      await _discovery!.ready;
      _discovery!.eventStream!.listen(_onEvent);
      await _discovery!.start();
      onLog?.call('[DISCOVERY] browsing started: $_kServiceType');
    } catch (e) {
      onLog?.call('[DISCOVERY] browse start ERROR: $e');
    }
  }

  // ── Event handler ─────────────────────────────────────────────────────────
  void _onEvent(BonsoirDiscoveryEvent event) {
    final svc = event.service;
    if (svc == null) return;

    if (event.type == BonsoirDiscoveryEventType.discoveryServiceFound) {
      onLog?.call('[DISCOVERY] Found: ${svc.name}');
      try { svc.resolve(_discovery!.serviceResolver); } catch (_) {}

    } else if (event.type == BonsoirDiscoveryEventType.discoveryServiceResolved) {
      onLog?.call('[DISCOVERY] Resolved: ${svc.name}');
      _handleResolved(svc);

    } else if (event.type == BonsoirDiscoveryEventType.discoveryServiceLost) {
      onLog?.call('[DISCOVERY] Lost: ${svc.name}');
      _removeSvc(svc.name);
    }
  }

  // ── Process resolved service ───────────────────────────────────────────────
  Future<void> _handleResolved(BonsoirService svc) async {
    final attrs = svc.attributes ?? {};
    final uid  = attrs['uid']?.toString();
    final name = attrs['name']?.toString();
    final xpub = attrs['xpub']?.toString();
    final aiHost = attrs['ai']?.toString() == '1';
    if (uid == null || uid.isEmpty || xpub == null || xpub.isEmpty) return;

    // ── 1. Read IP embedded in TXT record (our primary method) ──────────────
    List<String> ips = [];
    final txtIp = attrs['ip']?.toString();
    if (txtIp != null && txtIp.isNotEmpty && _isNumericIp(txtIp)) {
      ips = [txtIp];
      onLog?.call('[DISCOVERY] Peer IP from TXT: $txtIp');
    }

    // ── 2. Fallback: try mDNS hostname resolution ────────────────────────────
    if (ips.isEmpty) {
      final rawHost = _rawHostOf(svc);
      if (rawHost != null && rawHost.isNotEmpty &&
          rawHost.toLowerCase() != 'null') {
        if (_isNumericIp(rawHost)) {
          ips = [rawHost];
        } else {
          try {
            final r = await InternetAddress.lookup(rawHost,
                    type: InternetAddressType.IPv4)
                .timeout(const Duration(seconds: 2));
            ips = r.where((a) => !a.isLoopback).map((a) => a.address).toList();
            if (ips.isNotEmpty) {
              onLog?.call('[DISCOVERY] DNS $rawHost → ${ips.first}');
            }
          } catch (_) {}
        }
      }
    }

    // Dedup — don't fire twice with same data
    final fp = '${ips.join(",")}|$name|$xpub|$aiHost';
    if (_fingerprint[svc.name] == fp) return;
    _nameToUid[svc.name] = uid;
    _fingerprint[svc.name] = fp;

    if (ips.isNotEmpty) {
      onLog?.call('[DISCOVERY] Peer ready: $name @ ${ips.first}');
    } else {
      onLog?.call('[DISCOVERY] Peer found (no IP, TCP fallback): $name');
    }

    // Always notify — real_p2p_service handles empty-IP via kPeerChallenge sourceIp
    onPeerFound?.call(uid, ips, name ?? 'Unknown', xpub, aiHost);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  String? _rawHostOf(BonsoirService svc) {
    try {
      // ignore: avoid_dynamic_calls
      final h = (svc as dynamic).host?.toString();
      if (h != null && h.isNotEmpty) return h;
    } catch (_) {}
    try {
      return svc.toJson()['host']?.toString();
    } catch (_) {}
    return null;
  }

  static bool _isNumericIp(String h) =>
      RegExp(r'^[\d.]+$').hasMatch(h) || h.contains(':');

  static Future<String?> _findLocalIp() async {
    try {
      final ifaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          // Prefer RFC-1918 LAN addresses
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.')      ||
              ip.startsWith('172.')) {
            return ip;
          }
        }
      }
      // Accept any non-loopback
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }

  void _removeSvc(String svcKey) {
    final uid = _nameToUid.remove(svcKey);
    _fingerprint.remove(svcKey);
    if (uid != null) onPeerLost?.call(uid);
  }

  // ── Stop ──────────────────────────────────────────────────────────────────
  Future<void> stop() async {
    try { await _discovery?.stop(); } catch (_) {}
    try { await _broadcast?.stop(); } catch (_) {}
    _discovery = null;
    _broadcast = null;
    _nameToUid.clear();
    _fingerprint.clear();
    onLog?.call('[DISCOVERY] stopped');
  }
}
