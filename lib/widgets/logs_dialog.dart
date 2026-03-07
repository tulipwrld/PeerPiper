import 'package:flutter/material.dart';

import '../p2p/p2p_service.dart';
import '../theme/app_colors.dart';

class LogsDialog extends StatefulWidget {
  final AppColors colors;
  final P2PService service;

  const LogsDialog({
    super.key,
    required this.colors,
    required this.service,
  });

  @override
  State<LogsDialog> createState() => _LogsDialogState();
}

class _LogsDialogState extends State<LogsDialog> {
  String _selectedPeerId = '';
  final ScrollController _scroll = ScrollController();
  int _lastCount = 0;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _maybeScrollToBottom(int len) {
    if (len == _lastCount) return;
    _lastCount = len;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final svc = widget.service;
    final c = widget.colors;

    return Dialog(
      backgroundColor: c.bgCard,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: 860,
        height: 560,
        child: AnimatedBuilder(
          animation: svc,
          builder: (context, _) {
            try {
              final peerIds = svc.logsByPeer.keys.toList()..sort();
              final safeSelected =
                  (_selectedPeerId.isNotEmpty && !peerIds.contains(_selectedPeerId))
                      ? ''
                      : _selectedPeerId;
              if (safeSelected != _selectedPeerId) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) setState(() => _selectedPeerId = safeSelected);
                });
              }

              final items = <DropdownMenuItem<String>>[
                const DropdownMenuItem(value: '', child: Text('All logs')),
                ...peerIds.map((id) {
                  final max = id.length > 10 ? 10 : id.length;
                  final name = svc.peers[id]?.name ?? id.substring(0, max);
                  return DropdownMenuItem(value: id, child: Text(name));
                }),
              ];

              final base = safeSelected.isEmpty
                  ? svc.logs
                  : (svc.logsByPeer[safeSelected] ?? const <dynamic>[]);
              final filtered = base.whereType<P2PLogEntry>().toList(growable: false);
              final data = (filtered.isEmpty && safeSelected.isNotEmpty)
                  ? svc.logs.whereType<P2PLogEntry>().toList(growable: false)
                  : filtered;
              _maybeScrollToBottom(data.length);

              return Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'LOGS',
                          style: TextStyle(
                            color: c.accent,
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          decoration: BoxDecoration(
                            border: Border.all(color: c.borderSoft),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: safeSelected,
                              items: items,
                              onChanged: (v) =>
                                  setState(() => _selectedPeerId = v ?? ''),
                            ),
                          ),
                        ),
                        const Spacer(),
                        OutlinedButton.icon(
                          onPressed: () async {
                            final path = await svc.exportLogsToTxt();
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  path == null
                                      ? 'Failed to save logs'
                                      : 'Logs saved: $path',
                                ),
                              ),
                            );
                          },
                          icon: const Icon(Icons.save_alt, size: 16),
                          label: const Text('Save .txt'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: Container(
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: c.bgMain,
                          border: Border.all(color: c.borderSoft),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: data.isEmpty
                            ? Center(
                                child: Text(
                                  'No logs',
                                  style: TextStyle(
                                    color: c.textSecondary,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              )
                            : ListView.builder(
                                controller: _scroll,
                                padding: const EdgeInsets.all(10),
                                itemCount: data.length,
                                itemBuilder: (_, i) {
                                  final e = data[i];
                                  return SelectableText(
                                    '[${e.hhmmss}] ${e.text}',
                                    style: TextStyle(
                                      color: c.textPrimary,
                                      fontFamily: 'monospace',
                                      fontSize: 12,
                                      height: 1.35,
                                    ),
                                  );
                                },
                              ),
                      ),
                    ),
                  ],
                ),
              );
            } catch (e) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    'Logs render error: $e',
                    style: TextStyle(
                      color: c.textSecondary,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              );
            }
          },
        ),
      ),
    );
  }
}
