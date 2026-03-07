// lib/widgets/chat_area.dart

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:io';

import '../models/group.dart';
import '../models/message.dart';
import '../models/peer.dart';
import '../p2p/p2p_service.dart';
import '../theme/app_colors.dart';

class ChatArea extends StatefulWidget {
  final AppColors colors;
  final Peer? selectedPeer;
  final ChatGroup? selectedGroup;
  final String? selectedAiPeerUid;

  const ChatArea({
    super.key,
    required this.colors,
    required this.selectedPeer,
    required this.selectedGroup,
    required this.selectedAiPeerUid,
  });

  @override
  State<ChatArea> createState() => _ChatAreaState();
}

class _ChatAreaState extends State<ChatArea> {
  final _scrollCtrl = ScrollController();
  int _lastCount = 0;

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _maybeScroll(int count) {
    if (count != _lastCount) {
      _lastCount = count;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollCtrl.hasClients) {
          _scrollCtrl.animateTo(
            _scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  List<ChatMessage> _filter(
    List<ChatMessage> all,
    Peer? peer,
    ChatGroup? group,
    String? aiPeerUid,
  ) {
    if (peer == null && group == null && aiPeerUid == null) {
      return const <ChatMessage>[];
    }
    final groupKey = group == null ? '' : 'group:${group.id}';
    final aiKey = aiPeerUid == null ? '' : 'ai:$aiPeerUid';
    return all.where((m) {
      if (m.isSystem) return false;
      if (m.isBroadcast) return true;
      if (aiPeerUid != null) return m.peerId == aiKey;
      if (group != null) return m.peerId == groupKey;
      if (peer != null && m.peerId == peer.uid) return true;
      if (m.isOwn && m.peerId.isEmpty) return true;
      return false;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<P2PService>();
    final messages = _filter(
      svc.messages,
      widget.selectedPeer,
      widget.selectedGroup,
      widget.selectedAiPeerUid,
    );
    final c = widget.colors;
    _maybeScroll(messages.length);

    if (widget.selectedPeer == null &&
        widget.selectedGroup == null &&
        widget.selectedAiPeerUid == null) {
      return _EmptyState(colors: c);
    }

    final aiPeer = widget.selectedAiPeerUid == null
        ? null
        : svc.peers[widget.selectedAiPeerUid!];
    final isLocalAi = widget.selectedAiPeerUid != null &&
        widget.selectedAiPeerUid == svc.myUid;

    return Container(
      color: c.bgMain,
      child: Column(
        children: [
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: c.bgSidebar,
              border: Border(bottom: BorderSide(color: c.borderSoft)),
            ),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.selectedGroup != null
                        ? c.accent
                        : widget.selectedAiPeerUid != null
                            ? c.accent2
                            : widget.selectedPeer!.isOnline
                                ? c.accent2
                                : c.textSecondary.withOpacity(0.4),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  widget.selectedGroup?.name ??
                      (widget.selectedAiPeerUid != null
                          ? (isLocalAi
                              ? 'Local AI'
                              : 'AI ${aiPeer?.name ?? widget.selectedAiPeerUid}')
                          : widget.selectedPeer!.name),
                  style: TextStyle(
                    color: c.textPrimary,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  widget.selectedGroup != null
                      ? '${widget.selectedGroup!.memberUids.length} members'
                      : widget.selectedAiPeerUid != null
                          ? (isLocalAi
                              ? 'this device'
                              : (aiPeer?.isOnline == true
                              ? 'AI online'
                              : 'AI offline'))
                          : (widget.selectedPeer!.isOnline
                              ? (widget.selectedPeer!.ip ?? 'online')
                              : 'offline'),
                  style: TextStyle(
                    color: c.textSecondary,
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Text(
                      'No messages yet',
                      style: TextStyle(
                        color: c.textSecondary,
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    itemCount: messages.length,
                    itemBuilder: (_, i) =>
                        _MessageBubble(msg: messages[i], colors: c),
                  ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final AppColors colors;
  const _EmptyState({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: colors.bgMain,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline,
                size: 48, color: colors.textSecondary.withOpacity(0.3)),
            const SizedBox(height: 12),
            Text(
              'Select a peer to start chatting',
              style: TextStyle(
                color: colors.textSecondary,
                fontFamily: 'monospace',
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final ChatMessage msg;
  final AppColors colors;

  const _MessageBubble({required this.msg, required this.colors});

  @override
  Widget build(BuildContext context) {
    final c = colors;

    if (msg.isSystem) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(
          msg.text,
          style: TextStyle(
            color: c.textSecondary.withOpacity(0.65),
            fontFamily: 'monospace',
            fontSize: 10,
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }

    final isOwn = msg.isOwn;
    final isBroadcast = msg.isBroadcast;
    final savedPath = _extractSavedPath(msg.text);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment:
            isOwn ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 3, left: 4, right: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!isOwn) ...[
                  Text(
                    msg.sender,
                    style: TextStyle(
                      color: c.accent,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold,
                      fontSize: 10,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                if (isBroadcast)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child:
                        Icon(Icons.campaign, size: 12, color: c.textSecondary),
                  ),
                Text(
                  msg.formattedTime,
                  style: TextStyle(
                    color: c.textSecondary,
                    fontFamily: 'monospace',
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.60,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: isOwn
                  ? c.accent.withOpacity(0.18)
                  : isBroadcast
                      ? c.accent2.withOpacity(0.12)
                      : c.bgCard,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(12),
                topRight: const Radius.circular(12),
                bottomLeft: Radius.circular(isOwn ? 12 : 2),
                bottomRight: Radius.circular(isOwn ? 2 : 12),
              ),
              border: Border.all(
                color: isOwn ? c.accent.withOpacity(0.25) : c.borderSoft,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  msg.text,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontFamily: 'monospace',
                    fontSize: 13,
                  ),
                ),
                if (savedPath.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => _openSavedFile(context, savedPath),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: c.accent2.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(8),
                          border:
                              Border.all(color: c.accent2.withOpacity(0.35)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.folder_open, size: 14, color: c.accent2),
                            const SizedBox(width: 6),
                            Text(
                              'Open file',
                              style: TextStyle(
                                color: c.accent2,
                                fontFamily: 'monospace',
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _extractSavedPath(String text) {
    const marker = '\nSaved: ';
    final idx = text.indexOf(marker);
    if (idx < 0) return '';
    return text.substring(idx + marker.length).trim();
  }

  Future<void> _openSavedFile(BuildContext context, String path) async {
    try {
      if (!File(path).existsSync()) {
        throw Exception('File not found');
      }
      if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', path], runInShell: true);
      } else if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [path]);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Open file error: $e')),
        );
      }
    }
  }
}
