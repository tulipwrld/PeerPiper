// lib/p2p/call_service.dart
//
// Full WebRTC call engine using flutter_webrtc.
// Supports: audio call, video call, screen share, group call (mesh topology).
// Stats: getStats() every 15s → RTT / jitter / loss per peer.
// Signaling: all SDP / ICE delivered via RealP2PService.sendCallSignalRaw().

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

@visibleForTesting
dynamic choosePreferredDesktopSource(List<dynamic> sources) {
  if (sources.isEmpty) return null;
  for (final s in sources) {
    final t = (s as dynamic).type;
    if ('$t'.toLowerCase().contains('screen')) return s;
  }
  return sources.first;
}

// ── Call mode ──────────────────────────────────────────────────────────────
enum CallMode { audioOnly, video, screenShare }

// ── Per-peer session ───────────────────────────────────────────────────────
class CallSession {
  final String peerId;
  final String peerName;
  final String peerXpub;
  RTCPeerConnection? pc;
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  bool isInitiator;

  // ICE candidates queued before remote description is set
  final List<RTCIceCandidate> _iceCandidateQueue = [];
  bool _remoteDescSet = false;

  // Stats (updated every 15s)
  double rttMs = 0;
  double jitterMs = 0;
  double lossPct = 0;
  int _prevPacketsSent = 0;
  int _prevPacketsLost = 0;
  Timer? _statsTimer;

  // Call state for this peer
  bool accepted = false;   // we accepted / they accepted

  CallSession({
    required this.peerId,
    required this.peerName,
    required this.peerXpub,
    required this.isInitiator,
  });

  Future<void> initRenderer() async {
    await remoteRenderer.initialize();
  }

  Future<void> dispose() async {
    _statsTimer?.cancel();
    await remoteRenderer.dispose();
    await pc?.close();
    pc = null;
  }
}

// ── Incoming call descriptor ───────────────────────────────────────────────
class IncomingCallInfo {
  final String peerId;
  final String peerName;
  final String peerXpub;
  final String sdp;
  final bool hasVideo;
  final bool hasScreen;
  final List<String> groupMembers; // empty for 1:1

  IncomingCallInfo({
    required this.peerId,
    required this.peerName,
    required this.peerXpub,
    required this.sdp,
    this.hasVideo = false,
    this.hasScreen = false,
    this.groupMembers = const [],
  });
}

// ── Main service ───────────────────────────────────────────────────────────
class CallService extends ChangeNotifier {
  // ── Local media ──────────────────────────────────────────────────────────
  MediaStream? _localStream;
  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  bool _localRendererInit = false;

  // Selected devices
  String? selectedAudioDeviceId;
  String? selectedVideoDeviceId;
  CallMode _mode = CallMode.audioOnly;

  // ── Sessions ──────────────────────────────────────────────────────────────
  final Map<String, CallSession> _sessions = {};
  IncomingCallInfo? pendingIncoming;

  // ── UI state ─────────────────────────────────────────────────────────────
  bool _micMuted = false;
  bool _camOff = false;
  bool _isInCall = false;
  bool _screenShareSwitching = false;

  // ── Injected callbacks (set by RealP2PService) ────────────────────────────
  /// Send a call signal (SDP/ICE) to a peer — injected from RealP2PService.
  Future<void> Function(String peerId, Map<String, dynamic> signal)?
      sendSignal;

  /// Look up peer xpub by uid — injected.
  String? Function(String peerId)? lookupXpub;
  void Function(String message)? onLog;

  // ── Getters ───────────────────────────────────────────────────────────────
  bool get isInCall => _isInCall;
  bool get hasPendingIncoming => pendingIncoming != null;
  bool get micMuted => _micMuted;
  bool get camOff => _camOff;
  CallMode get mode => _mode;
  List<CallSession> get sessions =>
      List.unmodifiable(_sessions.values.toList());
  int get peerCount => _sessions.length;

  // ─── RTC config (works on LAN without STUN) ───────────────────────────────
  static const _rtcConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ],
    'sdpSemantics': 'unified-plan',
  };

  static const _offerConstraints = {
    'mandatory': {
      'OfferToReceiveAudio': true,
      'OfferToReceiveVideo': true,
    },
  };

  // ── Init ──────────────────────────────────────────────────────────────────
  Future<void> init() async {
    await localRenderer.initialize();
    _localRendererInit = true;
  }

  // ── Device enumeration ────────────────────────────────────────────────────
  Future<List<MediaDeviceInfo>> getCameras() async {
    final devices = await navigator.mediaDevices.enumerateDevices();
    return devices.where((d) => d.kind == 'videoinput').toList();
  }

  Future<List<MediaDeviceInfo>> getMicrophones() async {
    final devices = await navigator.mediaDevices.enumerateDevices();
    return devices.where((d) => d.kind == 'audioinput').toList();
  }

  // ── Local media ──────────────────────────────────────────────────────────
  Future<void> _startLocalMedia(CallMode mode) async {
    _mode = mode;
    await _stopLocalMedia();

    if (!_localRendererInit) {
      await localRenderer.initialize();
      _localRendererInit = true;
    }

    if (mode == CallMode.screenShare) {
      try {
        _localStream = await _openDisplayStream();
        // Also get mic audio as a separate stream and merge
        try {
          final micStream = await navigator.mediaDevices.getUserMedia({
            'audio': selectedAudioDeviceId != null
                ? {'deviceId': selectedAudioDeviceId}
                : true,
            'video': false,
          });
          for (final t in micStream.getAudioTracks()) {
            await _localStream!.addTrack(t);
          }
        } catch (_) {}
      } catch (e) {
        debugPrint('[CALL] getDisplayMedia failed: $e');
        onLog?.call('[CALL] Screen share unavailable on this OS/session: $e');
        // Fallback to audio only
        _localStream = await navigator.mediaDevices.getUserMedia({
          'audio': true,
          'video': false,
        });
        _mode = CallMode.audioOnly;
      }
    } else {
      final constraints = <String, dynamic>{
        'audio': selectedAudioDeviceId != null
            ? {'deviceId': selectedAudioDeviceId, 'echoCancellation': true, 'noiseSuppression': true}
            : {'echoCancellation': true, 'noiseSuppression': true},
      };
      if (mode == CallMode.video) {
        constraints['video'] = selectedVideoDeviceId != null
            ? {
                'deviceId': selectedVideoDeviceId,
                'width': {'ideal': 960},
                'height': {'ideal': 540},
                'frameRate': {'ideal': 20, 'max': 24},
              }
            : {
                'width': {'ideal': 960},
                'height': {'ideal': 540},
                'frameRate': {'ideal': 20, 'max': 24},
              };
      } else {
        constraints['video'] = false;
      }
      _localStream = await navigator.mediaDevices.getUserMedia(constraints);
    }

    localRenderer.srcObject = _localStream;
    notifyListeners();
  }

  Future<void> _stopLocalMedia() async {
    if (_localStream != null) {
      final tracks = _localStream!.getTracks().toList(growable: false);
      for (final track in tracks) {
        await track.stop();
      }
      await _localStream!.dispose();
      _localStream = null;
    }
    localRenderer.srcObject = null;
  }

  // ── Call initiation ───────────────────────────────────────────────────────
  /// Start a 1:1 or group call.
  /// [peerIds] — list of uid strings (1 for 1:1, multiple for group).
  Future<void> startCall({
    required List<Map<String, dynamic>> peers, // [{uid, name, xpub}]
    required CallMode mode,
  }) async {
    if (_isInCall) {
      // Adding participant to existing call
      for (final peer in peers) {
        if (!_sessions.containsKey(peer['uid'])) {
          await _initiateWithPeer(
              uid: peer['uid'] as String,
              name: peer['name'] as String,
              xpub: peer['xpub'] as String);
        }
      }
      return;
    }

    _isInCall = true;
    _micMuted = false;
    _camOff = false;

    await _startLocalMedia(mode);

    for (final peer in peers) {
      await _initiateWithPeer(
          uid: peer['uid'] as String,
          name: peer['name'] as String,
          xpub: peer['xpub'] as String);
    }
    notifyListeners();
  }

  Future<void> _initiateWithPeer({
    required String uid,
    required String name,
    required String xpub,
  }) async {
    final session = CallSession(
        peerId: uid, peerName: name, peerXpub: xpub, isInitiator: true);
    await session.initRenderer();
    _sessions[uid] = session;

    final pc = await _createPc(session);
    session.pc = pc;

    // Add local tracks
    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        await pc.addTrack(track, _localStream!);
      }
    }

    // Create offer
    final offer = await pc.createOffer(_offerConstraints);
    await pc.setLocalDescription(offer);

    // Send offer signal
    await sendSignal?.call(uid, {
      'type': 'offer',
      'sdp': offer.sdp,
      'has_video': _mode == CallMode.video || _mode == CallMode.screenShare,
      'has_screen': _mode == CallMode.screenShare,
      'group_members': _sessions.keys.toList(),
    });
  }

  // ── Handle incoming call ──────────────────────────────────────────────────
  void handleIncomingOffer({
    required String peerId,
    required String peerName,
    required String peerXpub,
    required Map<String, dynamic> signal,
  }) {
    final sdp = signal['sdp'] as String? ?? '';
    if (sdp.isEmpty) return;

    pendingIncoming = IncomingCallInfo(
      peerId: peerId,
      peerName: peerName,
      peerXpub: peerXpub,
      sdp: sdp,
      hasVideo: signal['has_video'] as bool? ?? false,
      hasScreen: signal['has_screen'] as bool? ?? false,
      groupMembers: List<String>.from(signal['group_members'] as List? ?? []),
    );
    notifyListeners();
  }

  /// Accept the pending incoming call.
  Future<void> acceptCall(CallMode mode) async {
    final info = pendingIncoming;
    if (info == null) return;
    pendingIncoming = null;

    _isInCall = true;
    _mode = mode;
    _micMuted = false;
    _camOff = false;

    await _startLocalMedia(mode);

    final session = CallSession(
        peerId: info.peerId,
        peerName: info.peerName,
        peerXpub: info.peerXpub,
        isInitiator: false);
    await session.initRenderer();
    _sessions[info.peerId] = session;

    final pc = await _createPc(session);
    session.pc = pc;

    // Add local tracks
    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        await pc.addTrack(track, _localStream!);
      }
    }

    // Set remote offer
    await pc.setRemoteDescription(
        RTCSessionDescription(info.sdp, 'offer'));
    session._remoteDescSet = true;
    await _drainIceCandidates(session);

    // Create answer
    final answer = await pc.createAnswer(_offerConstraints);
    await pc.setLocalDescription(answer);

    // Send answer
    await sendSignal?.call(info.peerId, {
      'type': 'answer',
      'sdp': answer.sdp,
    });

    // If group call — connect to other members too
    for (final memberId in info.groupMembers) {
      if (memberId == info.peerId || _sessions.containsKey(memberId)) continue;
      final xpub = lookupXpub?.call(memberId);
      if (xpub != null && xpub.isNotEmpty) {
        await _initiateWithPeer(
            uid: memberId,
            name: memberId.substring(0, 8),
            xpub: xpub);
      }
    }

    notifyListeners();
  }

  /// Reject the pending incoming call.
  Future<void> rejectCall() async {
    final info = pendingIncoming;
    if (info == null) return;
    pendingIncoming = null;
    await sendSignal?.call(info.peerId, {'type': 'reject'});
    notifyListeners();
  }

  // ── Incoming answer ───────────────────────────────────────────────────────
  Future<void> handleAnswer(String peerId, String sdp) async {
    final session = _sessions[peerId];
    if (session == null || session.pc == null) return;

    await session.pc!
        .setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
    session._remoteDescSet = true;
    await _drainIceCandidates(session);
    session.accepted = true;
    notifyListeners();
  }

  Future<void> handleReoffer(String peerId, String sdp) async {
    final session = _sessions[peerId];
    if (session == null || session.pc == null || sdp.isEmpty) return;
    await session.pc!.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    session._remoteDescSet = true;
    await _drainIceCandidates(session);
    final answer = await session.pc!.createAnswer(_offerConstraints);
    await session.pc!.setLocalDescription(answer);
    await sendSignal?.call(peerId, {
      'type': 'reanswer',
      'sdp': answer.sdp,
    });
    notifyListeners();
  }

  Future<void> handleReanswer(String peerId, String sdp) async {
    final session = _sessions[peerId];
    if (session == null || session.pc == null || sdp.isEmpty) return;
    await session.pc!.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
    session._remoteDescSet = true;
    await _drainIceCandidates(session);
    notifyListeners();
  }

  // ── ICE candidates ────────────────────────────────────────────────────────
  Future<void> handleIceCandidate(
      String peerId, Map<String, dynamic> data) async {
    final candidate = RTCIceCandidate(
      data['candidate'] as String? ?? '',
      data['sdp_mid'] as String? ?? '',
      data['sdp_mline_index'] as int? ?? 0,
    );

    final session = _sessions[peerId];
    if (session == null) return;

    if (session._remoteDescSet) {
      await session.pc?.addCandidate(candidate);
    } else {
      session._iceCandidateQueue.add(candidate);
    }
  }

  Future<void> _drainIceCandidates(CallSession session) async {
    for (final c in session._iceCandidateQueue) {
      await session.pc?.addCandidate(c);
    }
    session._iceCandidateQueue.clear();
  }

  // ── Handle reject/hangup ──────────────────────────────────────────────────
  Future<void> handleReject(String peerId) async {
    if (pendingIncoming?.peerId == peerId) {
      pendingIncoming = null;
    }
    await _removeSession(peerId);
    if (_sessions.isEmpty) await _endCall();
    notifyListeners();
  }

  Future<void> handleHangup(String peerId) async {
    if (pendingIncoming?.peerId == peerId) {
      pendingIncoming = null;
    }
    await _removeSession(peerId);
    if (_sessions.isEmpty) await _endCall();
    notifyListeners();
  }

  // ── Hang up (our side) ────────────────────────────────────────────────────
  Future<void> hangup() async {
    for (final uid in _sessions.keys.toList()) {
      await sendSignal?.call(uid, {'type': 'hangup'});
    }
    await _endCall();
  }

  // ── Controls ──────────────────────────────────────────────────────────────
  void toggleMic() {
    _micMuted = !_micMuted;
    _localStream?.getAudioTracks().forEach((t) {
      t.enabled = !_micMuted;
    });
    notifyListeners();
  }

  void toggleCamera() {
    _camOff = !_camOff;
    _localStream?.getVideoTracks().forEach((t) {
      t.enabled = !_camOff;
    });
    notifyListeners();
  }

  /// Switch to screen share mid-call.
  Future<void> switchToScreenShare() async {
    if (_mode == CallMode.screenShare || _screenShareSwitching) return;
    _screenShareSwitching = true;
    try {
      final screenStream = await _openDisplayStream();
      final tracks = screenStream.getVideoTracks();
      if (tracks.isEmpty) {
        onLog?.call('[CALL] Screen share returned no video track');
        return;
      }
      await _replaceVideoTrack(tracks.first);
      // Try to keep mic in screen-share mode when available.
      if (_localStream != null && _localStream!.getAudioTracks().isEmpty) {
        try {
          final micStream = await navigator.mediaDevices.getUserMedia({
            'audio': selectedAudioDeviceId != null
                ? {'deviceId': selectedAudioDeviceId}
                : true,
            'video': false,
          });
          for (final t in micStream.getAudioTracks()) {
            await _localStream!.addTrack(t);
            for (final session in _sessions.values) {
              await session.pc?.addTrack(t, _localStream!);
            }
          }
        } catch (_) {}
      }
      _mode = CallMode.screenShare;
      notifyListeners();
    } catch (e) {
      debugPrint('[CALL] Screen share error: $e');
      onLog?.call('[CALL] Screen share error (OS/permission): $e');
    } finally {
      _screenShareSwitching = false;
    }
  }

  /// Switch back to camera.
  Future<void> switchToCamera() async {
    if (_mode != CallMode.screenShare) return;
    try {
      final camStream = await navigator.mediaDevices.getUserMedia({
        'video': selectedVideoDeviceId != null
            ? {'deviceId': selectedVideoDeviceId}
            : true,
        'audio': false,
      });
      await _replaceVideoTrack(camStream.getVideoTracks().first);
      _mode = CallMode.video;
      notifyListeners();
    } catch (e) {
      debugPrint('[CALL] Camera restore error: $e');
      onLog?.call('[CALL] Camera restore error: $e');
    }
  }

  Future<void> _replaceVideoTrack(MediaStreamTrack newTrack) async {
    // Replace in local stream
    final oldTracks =
        (_localStream?.getVideoTracks() ?? const <MediaStreamTrack>[])
            .toList(growable: false);
    for (final old in oldTracks) {
      await _localStream?.removeTrack(old);
      await old.stop();
    }
    await _localStream?.addTrack(newTrack);
    localRenderer.srcObject = _localStream;

    // Replace/add in all peer connections.
    for (final session in _sessions.values) {
      final senders = await session.pc?.getSenders() ?? [];
      var replaced = false;
      for (final sender in senders) {
        if (sender.track?.kind == 'video') {
          await sender.replaceTrack(newTrack);
          replaced = true;
        }
      }
      // If call started as audio-only there may be no video sender yet.
      if (!replaced && session.pc != null && _localStream != null) {
        await session.pc!.addTrack(newTrack, _localStream!);
      }
      await _sendReoffer(session);
    }
  }

  Future<void> _sendReoffer(CallSession session) async {
    if (session.pc == null) return;
    try {
      final offer = await session.pc!.createOffer(_offerConstraints);
      await session.pc!.setLocalDescription(offer);
      await sendSignal?.call(session.peerId, {
        'type': 'reoffer',
        'sdp': offer.sdp,
        'has_video': _mode == CallMode.video || _mode == CallMode.screenShare,
        'has_screen': _mode == CallMode.screenShare,
      });
    } catch (e) {
      onLog?.call('[CALL] Reoffer failed: $e');
    }
  }

  // ── RTCPeerConnection factory ──────────────────────────────────────────────
  Future<RTCPeerConnection> _createPc(CallSession session) async {
    final pc = await createPeerConnection(_rtcConfig);

    // ICE candidate ready → send to peer
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate != null && candidate.candidate!.isNotEmpty) {
        sendSignal?.call(session.peerId, {
          'type': 'ice',
          'candidate': candidate.candidate,
          'sdp_mid': candidate.sdpMid ?? '',
          'sdp_mline_index': candidate.sdpMLineIndex ?? 0,
        });
      }
    };

    // Connection state changes
    pc.onConnectionState = (state) {
      debugPrint('[CALL] ${session.peerName}: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _removeSession(session.peerId);
        if (_sessions.isEmpty) _endCall();
        notifyListeners();
      }
    };

    // Remote track arrived
    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        session.remoteRenderer.srcObject = event.streams.first;
        notifyListeners();
      }
    };

    // ICE connection
    pc.onIceConnectionState = (state) {
      debugPrint('[ICE] ${session.peerName}: $state');
    };

    // Start stats collection after connection
    pc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _startStats(session);
        notifyListeners();
      }
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        session._statsTimer?.cancel();
        _removeSession(session.peerId);
        if (_sessions.isEmpty) _endCall();
        notifyListeners();
      }
    };

    return pc;
  }

  // ── Stats collection ──────────────────────────────────────────────────────
  void _startStats(CallSession session) {
    session._statsTimer?.cancel();
    session._statsTimer =
        Timer.periodic(const Duration(seconds: 15), (_) async {
      await _collectStats(session);
    });
  }

  Future<void> _collectStats(CallSession session) async {
    if (session.pc == null) return;
    try {
      final stats = await session.pc!.getStats();
      for (final report in stats) {
        // Remote inbound RTP (from our perspective, sender-side stats)
        if (report.type == 'remote-inbound-rtp') {
          final rtt =
              (report.values['roundTripTime'] as num?)?.toDouble() ?? 0;
          final jitter =
              (report.values['jitter'] as num?)?.toDouble() ?? 0;
          final lost =
              (report.values['packetsLost'] as num?)?.toInt() ?? 0;
          final sent =
              (report.values['packetsSent'] as num?)?.toInt() ?? 0;

          final deltaSent = sent - session._prevPacketsSent;
          final deltaLost = lost - session._prevPacketsLost;
          session._prevPacketsSent = sent;
          session._prevPacketsLost = lost;

          session.rttMs = rtt * 1000;
          session.jitterMs = jitter * 1000;
          session.lossPct = deltaSent > 0
              ? (deltaLost / deltaSent * 100).clamp(0, 100)
              : 0;
        }
      }
      notifyListeners();
    } catch (_) {}
  }

  // ── Internal cleanup ──────────────────────────────────────────────────────
  Future<void> _removeSession(String peerId) async {
    final s = _sessions.remove(peerId);
    await s?.dispose();
  }

  Future<void> _endCall() async {
    for (final s in _sessions.values) {
      await s.dispose();
    }
    _sessions.clear();
    _isInCall = false;
    _micMuted = false;
    _camOff = false;
    pendingIncoming = null;
    await _stopLocalMedia();
    notifyListeners();
  }

  Future<MediaStream> _openDisplayStream() async {
    if (WebRTC.platformIsDesktop) {
      try {
        final sources = await desktopCapturer.getSources(
          types: [SourceType.Screen, SourceType.Window],
        );
        final preferred = choosePreferredDesktopSource(sources);
        if (preferred != null) {
          final preferredId = (preferred as dynamic).id?.toString();
          if (preferredId == null || preferredId.isEmpty) {
            throw Exception('Desktop source id is empty');
          }
          final stream = await navigator.mediaDevices.getDisplayMedia({
            'video': {
              'deviceId': {'exact': preferredId},
              'mandatory': {'frameRate': 12.0}
            },
            'audio': false,
          });
          if (stream.getVideoTracks().isNotEmpty) return stream;
          await stream.dispose();
        }
      } catch (e) {
        onLog?.call('[CALL] Desktop source pick failed, fallback: $e');
      }
    }

    final attempts = <Map<String, dynamic>>[
      {'video': true, 'audio': false},
      {
        'video': {
          'cursor': 'always',
          'frameRate': 12,
        },
        'audio': false,
      },
      {
        'video': {
          'cursor': 'always',
          'displaySurface': 'monitor',
          'frameRate': 12,
        },
        'audio': false,
      },
      {
        // Desktop-specific fallback used by many WebRTC builds.
        'video': {
          'mandatory': {
            'chromeMediaSource': 'desktop',
            'maxFrameRate': 10,
          },
        },
        'audio': false,
      },
    ];
    Object? lastErr;
    for (final constraints in attempts) {
      try {
        final stream = await navigator.mediaDevices.getDisplayMedia(constraints);
        if (stream.getVideoTracks().isNotEmpty) return stream;
        await stream.dispose();
      } catch (e) {
        lastErr = e;
      }
    }
    throw Exception(lastErr?.toString() ?? 'getDisplayMedia failed');
  }

  @override
  Future<void> dispose() async {
    await _endCall();
    if (_localRendererInit) {
      await localRenderer.dispose();
    }
    super.dispose();
  }
}
