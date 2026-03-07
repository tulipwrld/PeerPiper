// lib/widgets/group_chat_dialog.dart
//
// Dialog to select peers and send a group message.
// Uses sendGroupMessage() which employs Signal Sender Key scheme under the hood.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/message.dart';
import '../models/peer.dart';
import '../p2p/p2p_service.dart';
import '../theme/app_colors.dart';

class GroupChatDialog extends StatefulWidget {
  final AppColors colors;
  final List<Peer> peers;

  const GroupChatDialog({
    super.key,
    required this.colors,
    required this.peers,
  });

  @override
  State<GroupChatDialog> createState() => _GroupChatDialogState();
}

class _GroupChatDialogState extends State<GroupChatDialog> {
  final Set<String> _selectedUids = {};
  final _textCtrl = TextEditingController();
  bool _sending = false;

  List<Peer> get _onlinePeers =>
      widget.peers.where((p) => p.isOnline).toList();

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_selectedUids.isEmpty || _textCtrl.text.trim().isEmpty) return;
    setState(() => _sending = true);

    final svc = context.read<P2PService>();
    final text = _textCtrl.text.trim();
    final memberUids = _selectedUids.toList();

    try {
      await svc.sendGroupMessage(memberUids, text);
      svc.addLocalMessage(ChatMessage(
        sender: 'ME → GROUP (${memberUids.length})',
        text: text,
        timestamp: DateTime.now(),
        isOwn: true,
        isBroadcast: true,
      ));
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;

    return Dialog(
      backgroundColor: c.bgCard,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 380,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title
              Row(
                children: [
                  Icon(Icons.groups_2, color: c.accent, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'GROUP MESSAGE',
                    style: TextStyle(
                      color: c.accent,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Select recipients and type your message.',
                style: TextStyle(
                  color: c.textSecondary,
                  fontFamily: 'monospace',
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 16),

              // Peer selection
              Text(
                'RECIPIENTS',
                style: TextStyle(
                  color: c.textSecondary,
                  fontFamily: 'monospace',
                  fontSize: 10,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              ..._onlinePeers.map((peer) => _PeerCheckTile(
                    peer: peer,
                    colors: c,
                    selected: _selectedUids.contains(peer.uid),
                    onToggle: (v) => setState(() {
                      if (v) {
                        _selectedUids.add(peer.uid);
                      } else {
                        _selectedUids.remove(peer.uid);
                      }
                    }),
                  )),

              if (_onlinePeers.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'No online peers available.',
                    style: TextStyle(
                        color: c.textSecondary,
                        fontFamily: 'monospace',
                        fontSize: 11),
                  ),
                ),

              const SizedBox(height: 16),

              // Message input
              Text(
                'MESSAGE',
                style: TextStyle(
                  color: c.textSecondary,
                  fontFamily: 'monospace',
                  fontSize: 10,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _textCtrl,
                autofocus: true,
                minLines: 2,
                maxLines: 4,
                style: TextStyle(
                    color: c.textPrimary,
                    fontFamily: 'monospace',
                    fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Type your message...',
                  hintStyle: TextStyle(
                      color: c.textSecondary, fontFamily: 'monospace'),
                  filled: true,
                  fillColor: c.bgMain,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: c.borderSoft),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: c.borderSoft),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: c.accent),
                  ),
                ),
                onSubmitted: (_) => _send(),
              ),
              const SizedBox(height: 16),

              // Actions
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      'CANCEL',
                      style: TextStyle(
                          color: c.textSecondary, fontFamily: 'monospace'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: (_selectedUids.isEmpty || _sending) ? null : _send,
                    icon: _sending
                        ? SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.send, size: 14),
                    label: Text(
                      _sending ? 'SENDING...' : 'SEND TO ${_selectedUids.length}',
                      style: const TextStyle(
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.bold,
                          fontSize: 12),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: c.accent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Peer checkbox tile ────────────────────────────────────────────────────
class _PeerCheckTile extends StatelessWidget {
  final Peer peer;
  final AppColors colors;
  final bool selected;
  final ValueChanged<bool> onToggle;

  const _PeerCheckTile({
    required this.peer,
    required this.colors,
    required this.selected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return GestureDetector(
      onTap: () => onToggle(!selected),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? c.accent.withOpacity(0.1) : c.bgMain,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? c.accent.withOpacity(0.4) : c.borderSoft,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.check_box : Icons.check_box_outline_blank,
              color: selected ? c.accent : c.textSecondary,
              size: 18,
            ),
            const SizedBox(width: 10),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c.accent2),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                peer.name,
                style: TextStyle(
                  color: c.textPrimary,
                  fontFamily: 'monospace',
                  fontSize: 12,
                  fontWeight:
                      selected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
            Text(
              peer.ip ?? '',
              style: TextStyle(
                  color: c.textSecondary,
                  fontFamily: 'monospace',
                  fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}