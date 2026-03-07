// lib/screens/chat_screen.dart
//
// Root screen. Wraps the main layout in a Stack so IncomingCallOverlay
// can float above everything when a call arrives.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/message.dart';
import '../models/group.dart';
import '../models/peer.dart';
import '../p2p/call_service.dart';
import '../p2p/p2p_service.dart';
import '../screens/call_screen.dart';
import '../theme/theme_provider.dart';
import '../widgets/app_header.dart';
import '../widgets/chat_area.dart';
import '../widgets/incoming_call_overlay.dart';
import '../widgets/message_input_bar.dart';
import '../widgets/peers_panel.dart';
import '../widgets/search_dialog.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  Peer? _selectedPeer;
  ChatGroup? _selectedGroup;
  String? _selectedAiPeerUid;
  Timer? _pollTimer;
  bool _isOpeningCallScreen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<P2PService>().init();
      _startPolling();
    });
  }

  void _startPolling() {
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) context.read<P2PService>().refreshPeers();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  // ── Send text ──────────────────────────────────────────────────────────
  void _handleSend(String text) {
    if (text.isEmpty) return;
    final svc = context.read<P2PService>();
    if (_selectedAiPeerUid != null) {
      svc.sendAiMessage(_selectedAiPeerUid!, text);
      return;
    }
    if (_selectedGroup != null) {
      svc.sendGroupMessageToGroup(_selectedGroup!.id, text);
      return;
    }
    if (_selectedPeer == null) return;
    svc.sendMessage(_selectedPeer!.uid, text);
    svc.addLocalMessage(ChatMessage(
      sender: 'YOU',
      text: text,
      timestamp: DateTime.now(),
      isOwn: true,
      peerId: _selectedPeer!.uid,
    ));
  }

  // ── Broadcast ──────────────────────────────────────────────────────────
  void _handleBroadcast(String text) {
    if (text.isEmpty) return;
    final svc = context.read<P2PService>();
    svc.broadcastMessage(text);
    svc.addLocalMessage(ChatMessage(
      sender: 'YOU → ALL',
      text: text,
      timestamp: DateTime.now(),
      isOwn: true,
      isBroadcast: true,
    ));
  }

  // ── File send ──────────────────────────────────────────────────────────
  Future<void> _handleSendFilePath(String path) async {
    if (_selectedPeer == null || _selectedGroup != null) return;
    try {
      final f = File(path);
      if (!await f.exists()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('File not found')));
        return;
      }
      final bytes = await f.readAsBytes();
      final name = f.uri.pathSegments.isNotEmpty
          ? f.uri.pathSegments.last
          : 'file.bin';
      _doSendFile(name, bytes, sourcePath: f.path);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('File error: $e')));
    }
  }

  void _doSendFile(String name, Uint8List bytes, {String? sourcePath}) {
    if (_selectedPeer == null) return;
    final svc = context.read<P2PService>();
    svc.sendFile(_selectedPeer!.uid, name, bytes);
    final savedLine = (sourcePath != null && sourcePath.isNotEmpty)
        ? '\nSaved: $sourcePath'
        : '';
    svc.addLocalMessage(ChatMessage(
      sender: 'YOU',
      text: '[FILE] $name (${bytes.length} B)$savedLine',
      timestamp: DateTime.now(),
      isOwn: true,
      peerId: _selectedPeer!.uid,
    ));
  }

  void _maybeOpenCallScreen(CallService callSvc) {
    if (!mounted || _isOpeningCallScreen || !callSvc.isInCall) return;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    _isOpeningCallScreen = true;
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const CallScreen()))
        .whenComplete(() => _isOpeningCallScreen = false);
  }

  void _handleSearchTarget(SearchTarget target, P2PService svc) {
    if (target.kind == 'peer') {
      final p = svc.peers[target.id];
      if (p != null) {
        setState(() {
          _selectedAiPeerUid = null;
          _selectedGroup = null;
          _selectedPeer = p;
        });
      }
      return;
    }
    if (target.kind == 'ai') {
      if (svc.peers.containsKey(target.id)) {
        setState(() {
          _selectedPeer = null;
          _selectedGroup = null;
          _selectedAiPeerUid = target.id;
        });
      }
      return;
    }
    if (target.kind == 'group') {
      final g = svc.groups[target.id];
      if (g != null) {
        setState(() {
          _selectedAiPeerUid = null;
          _selectedPeer = null;
          _selectedGroup = g;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tp = context.watch<ThemeProvider>();
    final colors = tp.colors;
    final callSvc = context.watch<CallService>();
    final svc = context.watch<P2PService>();
    final activeGroup = _selectedGroup == null
        ? null
        : (svc.groups[_selectedGroup!.id] ?? _selectedGroup);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeOpenCallScreen(callSvc);
    });

    return Scaffold(
      backgroundColor: colors.bgMain,
      body: Stack(
        children: [
          // ── Main layout ──────────────────────────────────────────────
          Column(
            children: [
              AppHeader(
                colors: colors,
                isDark: tp.isDark,
                onSearchTarget: (t) => _handleSearchTarget(t, svc),
              ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    PeersPanel(
                      colors: colors,
                      selectedPeer: _selectedPeer,
                      selectedGroup: activeGroup,
                      selectedAiPeerUid: _selectedAiPeerUid,
                      onPeerSelected: (p) => setState(() {
                        _selectedAiPeerUid = null;
                        _selectedPeer = p;
                      }),
                      onGroupSelected: (g) => setState(() {
                        _selectedAiPeerUid = null;
                        _selectedGroup = g;
                      }),
                      onAiSelected: (uid) => setState(() {
                        _selectedPeer = null;
                        _selectedGroup = null;
                        _selectedAiPeerUid = uid;
                      }),
                    ),
                    Expanded(
                      child: ChatArea(
                          colors: colors,
                          selectedPeer: _selectedPeer,
                          selectedGroup: activeGroup,
                          selectedAiPeerUid: _selectedAiPeerUid),
                    ),
                  ],
                ),
              ),
              MessageInputBar(
                colors: colors,
                selectedPeer: _selectedPeer,
                selectedGroup: activeGroup,
                isAiChat: _selectedAiPeerUid != null,
                onSend: _handleSend,
                onBroadcast: _handleBroadcast,
                onSendFilePath: _handleSendFilePath,
              ),
            ],
          ),

          // ── Incoming call overlay (floats above everything) ──────────
          if (callSvc.hasPendingIncoming)
            Positioned(
              left: 0,
              right: 0,
              bottom: 80,
              child: IncomingCallOverlay(colors: colors),
            ),
        ],
      ),
    );
  }
}
