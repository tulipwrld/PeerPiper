import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/group.dart';
import '../models/peer.dart';
import '../p2p/p2p_service.dart';
import '../theme/app_colors.dart';

class GroupManageDialog extends StatefulWidget {
  final AppColors colors;
  final ChatGroup? group;
  final List<Peer> peers;

  const GroupManageDialog({
    super.key,
    required this.colors,
    required this.group,
    required this.peers,
  });

  @override
  State<GroupManageDialog> createState() => _GroupManageDialogState();
}

class _GroupManageDialogState extends State<GroupManageDialog> {
  final _nameCtrl = TextEditingController();
  final Set<String> _selected = {};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.group != null) {
      _nameCtrl.text = widget.group!.name;
      _selected.addAll(widget.group!.memberUids);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_selected.isEmpty) return;
    final svc = context.read<P2PService>();
    setState(() => _saving = true);
    try {
      if (widget.group == null) {
        await svc.createGroup(_nameCtrl.text.trim(), _selected.toList());
      } else {
        await svc.updateGroupMembers(widget.group!.id, _selected.toList());
      }
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final allPeers = widget.peers.toList()
      ..sort((a, b) {
        if (a.isOnline != b.isOnline) return a.isOnline ? -1 : 1;
        return a.name.compareTo(b.name);
      });
    final isCreate = widget.group == null;

    return Dialog(
      backgroundColor: c.bgCard,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: 420,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isCreate ? 'Create Group' : 'Manage Group',
                style: TextStyle(
                  color: c.textPrimary,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 10),
              if (isCreate) ...[
                TextField(
                  controller: _nameCtrl,
                  decoration: const InputDecoration(hintText: 'Group name'),
                ),
                const SizedBox(height: 10),
              ],
              Text(
                'Participants',
                style: TextStyle(
                  color: c.textSecondary,
                  fontFamily: 'monospace',
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final p in allPeers)
                      CheckboxListTile(
                        dense: true,
                        value: _selected.contains(p.uid),
                        onChanged: (v) {
                          setState(() {
                            if (v == true) {
                              _selected.add(p.uid);
                            } else {
                              _selected.remove(p.uid);
                            }
                          });
                        },
                        title: Text(
                          p.name,
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                        subtitle: Text(
                          p.isOnline
                              ? ((p.ip == null || p.ip!.isEmpty)
                                  ? 'online'
                                  : p.ip!)
                              : 'offline',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            color: c.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? 'Saving...' : 'Save'),
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
