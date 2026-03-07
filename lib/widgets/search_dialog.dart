import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/message.dart';
import '../p2p/p2p_service.dart';
import '../theme/app_colors.dart';

class SearchTarget {
  final String kind; // peer | group
  final String id;
  const SearchTarget({required this.kind, required this.id});
}

class _SearchHit {
  final SearchTarget? target;
  final String title;
  final String subtitle;
  const _SearchHit({
    required this.target,
    required this.title,
    required this.subtitle,
  });
}

ChatMessage _systemMsg(String text) => ChatMessage(
      sender: '',
      text: text,
      timestamp: DateTime.now(),
      isSystem: true,
    );

class SearchDialog extends StatefulWidget {
  final AppColors colors;

  const SearchDialog({super.key, required this.colors});

  @override
  State<SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<SearchDialog> {
  final TextEditingController _ctrl = TextEditingController();
  List<_SearchHit> _results = const [];

  AppColors get c => widget.colors;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _doSearch() {
    final query = _ctrl.text.trim();
    if (query.isEmpty) return;

    final service = context.read<P2PService>();
    service.refreshPeers();
    final q = query.toLowerCase();

    final peerHits = service.peers.values.where((p) {
      return p.name.toLowerCase().contains(q) ||
          p.uid.toLowerCase().contains(q) ||
          (p.ip ?? '').toLowerCase().contains(q);
    }).toList();

    final groupHits = service.groups.values.where((g) {
      return g.name.toLowerCase().contains(q) || g.id.toLowerCase().contains(q);
    }).toList();

    final msgHits = service.messages.where((m) {
      return !m.isSystem &&
          (m.text.toLowerCase().contains(q) || m.sender.toLowerCase().contains(q));
    }).take(20).toList();

    final out = <_SearchHit>[];
    for (final p in peerHits) {
      final ip = (p.ip == null || p.ip!.isEmpty) ? 'offline' : p.ip!;
      out.add(_SearchHit(
        target: SearchTarget(kind: 'peer', id: p.uid),
        title: p.name,
        subtitle: 'Peer • $ip',
      ));
    }
    for (final g in groupHits) {
      out.add(_SearchHit(
        target: SearchTarget(kind: 'group', id: g.id),
        title: g.name,
        subtitle: 'Group • ${g.memberUids.length} members',
      ));
    }
    for (final m in msgHits) {
      final t = m.text.replaceAll('\n', ' ');
      final preview = t.length > 80 ? '${t.substring(0, 80)}...' : t;
      out.add(_SearchHit(
        target: m.peerId.isEmpty
            ? null
            : SearchTarget(
                kind: m.peerId.startsWith('group:') ? 'group' : 'peer',
                id: m.peerId.startsWith('group:') ? m.peerId.substring(6) : m.peerId,
              ),
        title: m.sender,
        subtitle: 'Message • $preview',
      ));
    }

    service.addLocalMessage(_systemMsg('Search "$query": ${out.length} results'));
    setState(() {
      _results = out.isEmpty
          ? const [
              _SearchHit(
                target: null,
                title: 'No results',
                subtitle: 'Try another query',
              )
            ]
          : out;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: c.bgMain,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Search',
                style: TextStyle(
                  color: c.accent,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _ctrl,
                autofocus: true,
                style: TextStyle(
                  color: c.textPrimary,
                  fontFamily: 'monospace',
                  fontSize: 13,
                ),
                cursorColor: c.accent,
                onSubmitted: (_) => _doSearch(),
                decoration: InputDecoration(
                  hintText: 'Enter query...',
                  hintStyle: TextStyle(
                    color: c.textSecondary,
                    fontFamily: 'monospace',
                  ),
                  filled: true,
                  fillColor: c.bgCard,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: c.borderSoft),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: c.accent),
                  ),
                ),
              ),
              if (_results.isNotEmpty) ...[
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 240),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: c.bgCard,
                    border: Border.all(color: c.borderSoft),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _results.length,
                    itemBuilder: (_, i) {
                      final hit = _results[i];
                      final clickable = hit.target != null;
                      return ListTile(
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                        title: Text(
                          hit.title,
                          style: TextStyle(
                            color: c.textPrimary,
                            fontFamily: 'monospace',
                            fontSize: 12,
                            fontWeight: clickable ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text(
                          hit.subtitle,
                          style: TextStyle(
                            color: c.textSecondary,
                            fontFamily: 'monospace',
                            fontSize: 11,
                          ),
                        ),
                        trailing: clickable
                            ? Icon(Icons.arrow_forward_ios, size: 12, color: c.textSecondary)
                            : null,
                        onTap: clickable ? () => Navigator.pop(context, hit.target) : null,
                      );
                    },
                  ),
                ),
              ],
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      'Cancel',
                      style: TextStyle(
                        color: c.textSecondary,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: c.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onPressed: _doSearch,
                    child: const Text(
                      'Find',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                      ),
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
