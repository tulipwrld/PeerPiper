// lib/widgets/incoming_call_overlay.dart
//
// Persistent banner shown at the bottom of the ChatScreen when a call arrives.
// Shows caller name + call type icons. ACCEPT opens device picker and accepts
// call. ChatScreen opens CallScreen when call state becomes active.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../p2p/call_service.dart';
import '../theme/app_colors.dart';
import '../screens/device_picker_dialog.dart';

class IncomingCallOverlay extends StatefulWidget {
  final AppColors colors;
  const IncomingCallOverlay({super.key, required this.colors});

  @override
  State<IncomingCallOverlay> createState() => _IncomingCallOverlayState();
}

class _IncomingCallOverlayState extends State<IncomingCallOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulse;
  Timer? _autoReject;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 800));
    _pulse.repeat(reverse: true);
    // Auto-reject after 30s if no action
    _autoReject = Timer(const Duration(seconds: 30), () {
      final svc = context.read<CallService>();
      if (svc.hasPendingIncoming) svc.rejectCall();
    });
  }

  @override
  void dispose() {
    _pulse.dispose();
    _autoReject?.cancel();
    super.dispose();
  }

  Future<void> _accept(BuildContext context) async {
    final svc = context.read<CallService>();
    final info = svc.pendingIncoming;
    if (info == null) return;

    // Open device picker
    final result = await showDevicePicker(context, widget.colors);
    if (result == null) return; // user cancelled — keep ringing

    await svc.acceptCall(result.mode);
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<CallService>();
    final info = svc.pendingIncoming;
    if (info == null) return const SizedBox.shrink();

    final c = widget.colors;

    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, child) => Opacity(
        opacity: 0.85 + _pulse.value * 0.15,
        child: child,
      ),
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF1B3A1B),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.greenAccent.withOpacity(0.5), width: 1.5),
          boxShadow: [
            BoxShadow(
              color: Colors.green.withOpacity(0.3),
              blurRadius: 16,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Row(
          children: [
            // Pulsing call icon
            AnimatedBuilder(
              animation: _pulse,
              builder: (_, __) => Icon(
                Icons.call,
                color: Color.lerp(
                    Colors.greenAccent, Colors.white, _pulse.value)!,
                size: 28,
              ),
            ),
            const SizedBox(width: 12),

            // Caller info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'INCOMING CALL',
                    style: TextStyle(
                      color: Colors.greenAccent.withOpacity(0.8),
                      fontFamily: 'monospace',
                      fontSize: 10,
                      letterSpacing: 1.5,
                    ),
                  ),
                  Text(
                    info.peerName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  Row(
                    children: [
                      if (info.hasScreen) ...[
                        const Icon(Icons.screen_share,
                            size: 12, color: Colors.white54),
                        const SizedBox(width: 4),
                        const Text('Screen share',
                            style: TextStyle(
                                color: Colors.white54,
                                fontFamily: 'monospace',
                                fontSize: 10)),
                      ] else if (info.hasVideo) ...[
                        const Icon(Icons.videocam,
                            size: 12, color: Colors.white54),
                        const SizedBox(width: 4),
                        const Text('Video call',
                            style: TextStyle(
                                color: Colors.white54,
                                fontFamily: 'monospace',
                                fontSize: 10)),
                      ] else ...[
                        const Icon(Icons.mic,
                            size: 12, color: Colors.white54),
                        const SizedBox(width: 4),
                        const Text('Audio call',
                            style: TextStyle(
                                color: Colors.white54,
                                fontFamily: 'monospace',
                                fontSize: 10)),
                      ],
                      if (info.groupMembers.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        const Icon(Icons.groups,
                            size: 12, color: Colors.white54),
                        const SizedBox(width: 4),
                        Text(
                          'Group (${info.groupMembers.length + 1})',
                          style: const TextStyle(
                              color: Colors.white54,
                              fontFamily: 'monospace',
                              fontSize: 10),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),

            // Reject button
            GestureDetector(
              onTap: () => svc.rejectCall(),
              child: Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.redAccent.withOpacity(0.2),
                  border: Border.all(color: Colors.redAccent.withOpacity(0.5)),
                ),
                child: const Icon(Icons.call_end,
                    color: Colors.redAccent, size: 20),
              ),
            ),
            const SizedBox(width: 10),

            // Accept button
            GestureDetector(
              onTap: () => _accept(context),
              child: Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.greenAccent.withOpacity(0.2),
                  border:
                      Border.all(color: Colors.greenAccent.withOpacity(0.6)),
                ),
                child: const Icon(Icons.call,
                    color: Colors.greenAccent, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
