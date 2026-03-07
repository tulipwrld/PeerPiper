// lib/widgets/peers_panel.dart
//
// Sidebar: peer list with ONLINE/OFFLINE indicator and per-peer call button.
// Call button opens DevicePickerDialog, then starts call and pushes CallScreen.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'dart:collection';

import '../models/group.dart';
import '../models/peer.dart';
import '../p2p/call_service.dart';
import '../p2p/p2p_service.dart';
import '../screens/device_picker_dialog.dart';
import '../theme/app_colors.dart';
import 'group_manage_dialog.dart';

class _AiTarget {
  final String uid;
  final String title;
  final String subtitle;
  const _AiTarget({
    required this.uid,
    required this.title,
    required this.subtitle,
  });
}

class PeersPanel extends StatelessWidget {
  final AppColors colors;
  final Peer? selectedPeer;
  final ChatGroup? selectedGroup;
  final String? selectedAiPeerUid;
  final ValueChanged<Peer?> onPeerSelected;
  final ValueChanged<ChatGroup?> onGroupSelected;
  final ValueChanged<String> onAiSelected;

  const PeersPanel({
    super.key,
    required this.colors,
    required this.selectedPeer,
    required this.selectedGroup,
    required this.selectedAiPeerUid,
    required this.onPeerSelected,
    required this.onGroupSelected,
    required this.onAiSelected,
  });

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<P2PService>();
    final peerList = svc.peers.values.toList()
      ..sort((a, b) {
        if (a.isOnline != b.isOnline) return b.isOnline ? 1 : -1;
        return a.name.compareTo(b.name);
      });

    final onlineCount = peerList.where((p) => p.isOnline).length;
    final onlineByUid = HashMap<String, Peer>.fromEntries(
      peerList.where((p) => p.isOnline).map((p) => MapEntry(p.uid, p)),
    );
    final groups = svc.groups.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final aiTargets = <_AiTarget>[];
    final localUid = svc.myUid;
    if (svc.hasLocalAiHost && localUid != null && localUid.isNotEmpty) {
      aiTargets.add(
        _AiTarget(
          uid: localUid,
          title: 'Local AI',
          subtitle: 'this device',
        ),
      );
    }
    final remoteAi = svc.aiPeerIds
        .where((uid) => uid != localUid)
        .map((uid) => svc.peers[uid])
        .whereType<Peer>()
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    aiTargets.addAll(
      remoteAi.map(
        (p) => _AiTarget(
          uid: p.uid,
          title: '${p.name} AI',
          subtitle: p.isOnline ? 'online' : 'offline',
        ),
      ),
    );

    return Container(
      width: 230,
      decoration: BoxDecoration(
        color: colors.bgSidebar,
        border: Border(right: BorderSide(color: colors.borderSoft)),
      ),
      child: Column(
        children: [
          // ── Header ──────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
                border:
                    Border(bottom: BorderSide(color: colors.borderSoft))),
            child: Row(
              children: [
                Text(
                  'PEERS',
                  style: TextStyle(
                    color: colors.accent,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    letterSpacing: 1.2,
                  ),
                ),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: onlineCount > 0
                        ? colors.accent2.withOpacity(0.15)
                        : colors.bgCard,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: onlineCount > 0
                          ? colors.accent2.withOpacity(0.4)
                          : colors.borderSoft,
                    ),
                  ),
                  child: Text(
                    '$onlineCount online',
                    style: TextStyle(
                      color: onlineCount > 0
                          ? colors.accent2
                          : colors.textSecondary,
                      fontFamily: 'monospace',
                      fontSize: 10,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Peer list ────────────────────────────────────────────────
          Expanded(
            child: peerList.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.wifi_find,
                            color: colors.textSecondary, size: 32),
                        const SizedBox(height: 8),
                        Text('Scanning...',
                            style: TextStyle(
                                color: colors.textSecondary,
                                fontFamily: 'monospace',
                                fontSize: 11)),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: peerList.length,
                    itemBuilder: (ctx, i) => _PeerTile(
                          peer: peerList[i],
                          isSelected: selectedPeer?.uid == peerList[i].uid,
                          colors: colors,
                          onTap: () {
                            onGroupSelected(null);
                            onPeerSelected(peerList[i]);
                          },
                          onCall: peerList[i].isOnline
                              ? () => _startCall(ctx, [peerList[i]])
                              : null,
                        ),
                  ),
          ),

          Container(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
            decoration: BoxDecoration(
                border: Border(top: BorderSide(color: colors.borderSoft))),
            child: Row(
              children: [
                Text(
                  'AI',
                  style: TextStyle(
                    color: colors.accent,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 84,
            child: aiTargets.isEmpty
                ? Center(
                    child: Text(
                      'No AI hosts',
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontFamily: 'monospace',
                        fontSize: 10,
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: aiTargets.length,
                    itemBuilder: (_, i) {
                      final t = aiTargets[i];
                      final selected = selectedAiPeerUid == t.uid;
                      return ListTile(
                        dense: true,
                        selected: selected,
                        onTap: () {
                          onPeerSelected(null);
                          onGroupSelected(null);
                          onAiSelected(t.uid);
                        },
                        title: Text(
                          t.title,
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 12),
                        ),
                        subtitle: Text(
                          t.subtitle,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            color: colors.textSecondary,
                            fontSize: 10,
                          ),
                        ),
                      );
                    },
                  ),
          ),

          Container(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
            decoration: BoxDecoration(
                border: Border(top: BorderSide(color: colors.borderSoft))),
            child: Row(
              children: [
                Text(
                  'GROUPS',
                  style: TextStyle(
                    color: colors.accent2,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => showDialog(
                    context: context,
                    builder: (_) => GroupManageDialog(
                      colors: colors,
                      group: null,
                      peers: peerList,
                    ),
                  ),
                  child: Icon(Icons.add, size: 16, color: colors.accent2),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 130,
            child: groups.isEmpty
                ? Center(
                    child: Text(
                      'No groups',
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontFamily: 'monospace',
                        fontSize: 10,
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: groups.length,
                    itemBuilder: (_, i) {
                      final g = groups[i];
                      final selected = selectedGroup?.id == g.id;
                      return ListTile(
                        dense: true,
                        selected: selected,
                        onTap: () {
                          onPeerSelected(null);
                          onGroupSelected(g);
                        },
                        title: Text(
                          g.name,
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 12),
                        ),
                        subtitle: Text(
                          '${g.memberUids.length} members',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            color: colors.textSecondary,
                            fontSize: 10,
                          ),
                        ),
                        trailing: GestureDetector(
                          onTap: () => showDialog(
                            context: context,
                            builder: (_) => GroupManageDialog(
                              colors: colors,
                              group: g,
                              peers: peerList,
                            ),
                          ),
                          child:
                              Icon(Icons.settings, size: 14, color: colors.textSecondary),
                        ),
                      );
                    },
                  ),
          ),

          // ── Bottom actions ───────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                border: Border(top: BorderSide(color: colors.borderSoft))),
            child: Column(
              children: [
                // Group call button
                if (selectedGroup != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => _startSelectedGroupAudioCall(
                          context,
                          selectedGroup!,
                          onlineByUid,
                        ),
                        icon: Icon(Icons.call, size: 14, color: colors.accent2),
                        label: Text(
                          'GROUP AUDIO',
                          style: TextStyle(
                            color: colors.accent2,
                            fontFamily: 'monospace',
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: colors.accent2.withOpacity(0.4)),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (onlineCount >= 2)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => _startGroupCall(
                            context,
                            peerList.where((p) => p.isOnline).toList()),
                        icon: Icon(Icons.video_call,
                            size: 14, color: colors.accent2),
                        label: Text(
                          'GROUP CALL',
                          style: TextStyle(
                            color: colors.accent2,
                            fontFamily: 'monospace',
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(
                              color: colors.accent2.withOpacity(0.4)),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 6),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ),
                  ),
                if (onlineCount >= 2)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => _startGroupCallWithMode(
                          context,
                          peerList.where((p) => p.isOnline).toList(),
                          CallMode.audioOnly,
                        ),
                        icon: Icon(Icons.call, size: 14, color: colors.accent2),
                        label: Text(
                          'GROUP AUDIO ALL',
                          style: TextStyle(
                            color: colors.accent2,
                            fontFamily: 'monospace',
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: colors.accent2.withOpacity(0.4)),
                          padding:
                              const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ),
                  ),
                const SizedBox.shrink(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _startSelectedGroupAudioCall(
    BuildContext context,
    ChatGroup group,
    Map<String, Peer> onlineByUid,
  ) async {
    final callSvc = context.read<CallService>();
    if (callSvc.isInCall) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Already in a call')),
      );
      return;
    }
    final peers = group.memberUids
        .map((uid) => onlineByUid[uid])
        .whereType<Peer>()
        .toList();
    if (peers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No online group members')),
      );
      return;
    }
    await callSvc.startCall(
      peers: peers
          .map((p) => {'uid': p.uid, 'name': p.name, 'xpub': p.xpub})
          .toList(),
      mode: CallMode.audioOnly,
    );
  }

  // ── Start 1:1 call ────────────────────────────────────────────────────
  Future<void> _startCall(BuildContext context, List<Peer> peers) async {
    final callSvc = context.read<CallService>();
    if (callSvc.isInCall) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Already in a call')),
      );
      return;
    }

    final result = await showDevicePicker(context, colors);
    if (result == null || !context.mounted) return;

    callSvc.selectedAudioDeviceId = result.audioDeviceId;
    callSvc.selectedVideoDeviceId = result.videoDeviceId;

    await callSvc.startCall(
      peers: peers
          .map((p) => {'uid': p.uid, 'name': p.name, 'xpub': p.xpub})
          .toList(),
      mode: result.mode,
    );

    // CallScreen is opened by ChatScreen when callSvc.isInCall becomes true.
  }

  // ── Start group call ──────────────────────────────────────────────────
  Future<void> _startGroupCall(
      BuildContext context, List<Peer> peers) async {
    final callSvc = context.read<CallService>();
    if (callSvc.isInCall) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Already in a call')),
      );
      return;
    }

    final result = await showDevicePicker(context, colors);
    if (result == null || !context.mounted) return;

    callSvc.selectedAudioDeviceId = result.audioDeviceId;
    callSvc.selectedVideoDeviceId = result.videoDeviceId;

    await callSvc.startCall(
      peers: peers
          .map((p) => {'uid': p.uid, 'name': p.name, 'xpub': p.xpub})
          .toList(),
      mode: result.mode,
    );

    // CallScreen is opened by ChatScreen when callSvc.isInCall becomes true.
  }

  Future<void> _startGroupCallWithMode(
    BuildContext context,
    List<Peer> peers,
    CallMode mode,
  ) async {
    final callSvc = context.read<CallService>();
    if (callSvc.isInCall) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Already in a call')),
      );
      return;
    }
    await callSvc.startCall(
      peers: peers
          .map((p) => {'uid': p.uid, 'name': p.name, 'xpub': p.xpub})
          .toList(),
      mode: mode,
    );
  }
}

// ── Individual peer tile ───────────────────────────────────────────────────
class _PeerTile extends StatefulWidget {
  final Peer peer;
  final bool isSelected;
  final AppColors colors;
  final VoidCallback onTap;
  final VoidCallback? onCall;

  const _PeerTile({
    required this.peer,
    required this.isSelected,
    required this.colors,
    required this.onTap,
    required this.onCall,
  });

  @override
  State<_PeerTile> createState() => _PeerTileState();
}

class _PeerTileState extends State<_PeerTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.peer;
    final c = widget.colors;
    final bg = widget.isSelected
        ? c.accent.withOpacity(0.15)
        : _hovered
            ? c.bgHover
            : Colors.transparent;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
            border: widget.isSelected
                ? Border.all(color: c.accent.withOpacity(0.3))
                : null,
          ),
          child: Row(
            children: [
              // Avatar with online dot
              Stack(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: p.isOnline
                          ? c.accent.withOpacity(0.18)
                          : c.bgCard,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: p.isOnline
                            ? c.accent.withOpacity(0.35)
                            : c.borderSoft,
                      ),
                    ),
                    child: Center(
                      child: Text(
                        p.name.isNotEmpty ? p.name[0].toUpperCase() : '?',
                        style: TextStyle(
                          color:
                              p.isOnline ? c.accent : c.textSecondary,
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: p.isOnline
                            ? c.accent2
                            : c.textSecondary.withOpacity(0.5),
                        border:
                            Border.all(color: c.bgSidebar, width: 1.5),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 8),

              // Name + status
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color:
                            p.isOnline ? c.textPrimary : c.textSecondary,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      p.isOnline ? (p.ip ?? 'online') : 'offline',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: p.isOnline
                            ? c.accent2.withOpacity(0.8)
                            : c.textSecondary.withOpacity(0.5),
                        fontFamily: 'monospace',
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),

              // Call button (only when online, only when hovered or selected)
              if (widget.onCall != null && (widget.isSelected || _hovered))
                GestureDetector(
                  onTap: widget.onCall,
                  child: Tooltip(
                    message: 'Call ${p.name}',
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: c.accent2.withOpacity(0.15),
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: c.accent2.withOpacity(0.4)),
                      ),
                      child: Icon(Icons.call,
                          size: 13, color: c.accent2),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
