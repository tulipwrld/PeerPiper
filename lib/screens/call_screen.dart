// lib/screens/call_screen.dart
//
// Full-screen call overlay. Features:
//  • Audio-only / Video / Screen-share modes
//  • Group call — responsive video grid (2×2, 3×2, …)
//  • Stats overlay: RTT / jitter / loss per peer (updated every 15s)
//  • Controls: Mute mic, Toggle cam, Screen share ↔ Camera, Hang up
//  • Incoming call banner with Accept/Reject

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';

import '../p2p/call_service.dart';
import '../theme/app_colors.dart';
import '../theme/theme_provider.dart';
import 'device_picker_dialog.dart';

// ── Entry point: push this on top of ChatScreen ───────────────────────────
class CallScreen extends StatelessWidget {
  const CallScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.watch<ThemeProvider>().colors;
    return _CallScreenBody(colors: colors);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
class _CallScreenBody extends StatefulWidget {
  final AppColors colors;
  const _CallScreenBody({required this.colors});

  @override
  State<_CallScreenBody> createState() => _CallScreenBodyState();
}

class _CallScreenBodyState extends State<_CallScreenBody> {
  bool _statsVisible = false;
  Timer? _clockTimer;
  Duration _elapsed = Duration.zero;
  DateTime? _callStart;

  @override
  void initState() {
    super.initState();
    _callStart = DateTime.now();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          _elapsed = DateTime.now().difference(_callStart!);
        });
      }
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    super.dispose();
  }

  String get _elapsedStr {
    final h = _elapsed.inHours;
    final m = _elapsed.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = _elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<CallService>();
    final c = widget.colors;
    final sessions = svc.sessions;
    final isVideoCall = svc.mode == CallMode.video ||
        svc.mode == CallMode.screenShare;
    if (!svc.isInCall) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      });
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── Video grid ──────────────────────────────────────────────────
          if (isVideoCall && sessions.isNotEmpty)
            _VideoGrid(
              sessions: sessions,
              localRenderer: svc.localRenderer,
              mode: svc.mode,
            )
          else
            _AudioCallView(
                sessions: sessions, colors: c, elapsed: _elapsedStr),

          // ── Local preview thumbnail (video mode) ─────────────────────
          if (isVideoCall && !svc.camOff)
            Positioned(
              right: 16,
              bottom: 100,
              child: _LocalPreviewThumbnail(
                renderer: svc.localRenderer,
                mode: svc.mode,
              ),
            ),

          // ── Stats overlay ────────────────────────────────────────────
          if (_statsVisible && sessions.isNotEmpty)
            Positioned(
              top: 16,
              left: 16,
              child: _StatsOverlay(sessions: sessions, colors: c),
            ),

          // ── Top bar: clock + peer count + mode ───────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _TopBar(
              colors: c,
              elapsed: _elapsedStr,
              mode: svc.mode,
              peerCount: sessions.length,
              statsVisible: _statsVisible,
              onToggleStats: () =>
                  setState(() => _statsVisible = !_statsVisible),
            ),
          ),

          // ── Control bar ──────────────────────────────────────────────
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _ControlBar(colors: c),
          ),
        ],
      ),
    );
  }
}

// ── Video grid ─────────────────────────────────────────────────────────────
class _VideoGrid extends StatelessWidget {
  final List<CallSession> sessions;
  final RTCVideoRenderer localRenderer;
  final CallMode mode;

  const _VideoGrid({
    required this.sessions,
    required this.localRenderer,
    required this.mode,
  });

  @override
  Widget build(BuildContext context) {
    final count = sessions.length;
    final cols = count <= 1 ? 1 : count <= 4 ? 2 : 3;
    final fit = mode == CallMode.screenShare
        ? RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
        : RTCVideoViewObjectFit.RTCVideoViewObjectFitCover;
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
      ),
      itemCount: count,
      itemBuilder: (_, i) {
        final s = sessions[i];
        return Stack(
          fit: StackFit.expand,
          children: [
            RTCVideoView(
              s.remoteRenderer,
              objectFit: fit,
            ),
            // Name tag
            Positioned(
              bottom: 8,
              left: 8,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  s.peerName,
                  style: const TextStyle(
                      color: Colors.white,
                      fontFamily: 'monospace',
                      fontSize: 11),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ── Audio call view ─────────────────────────────────────────────────────────
class _AudioCallView extends StatelessWidget {
  final List<CallSession> sessions;
  final AppColors colors;
  final String elapsed;

  const _AudioCallView(
      {required this.sessions,
      required this.colors,
      required this.elapsed});

  @override
  Widget build(BuildContext context) {
    final names =
        sessions.map((s) => s.peerName).join(', ');
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Avatar(s)
          if (sessions.length == 1)
            _BigAvatar(name: sessions.first.peerName, colors: colors)
          else
            _GroupAvatars(sessions: sessions, colors: colors),
          const SizedBox(height: 24),
          Text(
            sessions.isEmpty ? 'Connecting...' : names,
            style: const TextStyle(
              color: Colors.white,
              fontFamily: 'monospace',
              fontWeight: FontWeight.bold,
              fontSize: 20,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            elapsed,
            style: const TextStyle(
              color: Colors.white54,
              fontFamily: 'monospace',
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}

class _BigAvatar extends StatelessWidget {
  final String name;
  final AppColors colors;
  const _BigAvatar({required this.name, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 100,
      height: 100,
      decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: colors.accent.withOpacity(0.2),
          border: Border.all(color: colors.accent, width: 2)),
      child: Center(
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : '?',
          style: TextStyle(
              color: colors.accent,
              fontFamily: 'monospace',
              fontWeight: FontWeight.bold,
              fontSize: 40),
        ),
      ),
    );
  }
}

class _GroupAvatars extends StatelessWidget {
  final List<CallSession> sessions;
  final AppColors colors;
  const _GroupAvatars({required this.sessions, required this.colors});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 80,
      child: Stack(
        children: [
          for (var i = 0; i < sessions.length.clamp(0, 4); i++)
            Positioned(
              left: i * 50.0,
              child: Container(
                width: 70,
                height: 70,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colors.accent.withOpacity(0.2),
                    border:
                        Border.all(color: Colors.black, width: 2)),
                child: Center(
                  child: Text(
                    sessions[i].peerName.isNotEmpty
                        ? sessions[i].peerName[0].toUpperCase()
                        : '?',
                    style: TextStyle(
                        color: colors.accent,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                        fontSize: 22),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Local preview thumbnail ─────────────────────────────────────────────────
class _LocalPreviewThumbnail extends StatelessWidget {
  final RTCVideoRenderer renderer;
  final CallMode mode;
  const _LocalPreviewThumbnail({required this.renderer, required this.mode});

  @override
  Widget build(BuildContext context) {
    final fit = mode == CallMode.screenShare
        ? RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
        : RTCVideoViewObjectFit.RTCVideoViewObjectFitCover;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 120,
        height: 90,
        child: RTCVideoView(
          renderer,
          mirror: true,
          objectFit: fit,
        ),
      ),
    );
  }
}

// ── Stats overlay ───────────────────────────────────────────────────────────
class _StatsOverlay extends StatelessWidget {
  final List<CallSession> sessions;
  final AppColors colors;
  const _StatsOverlay({required this.sessions, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.75),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('NETWORK STATS',
              style: TextStyle(
                  color: Colors.white54,
                  fontFamily: 'monospace',
                  fontSize: 10,
                  letterSpacing: 1.2)),
          const SizedBox(height: 6),
          for (final s in sessions) ...[
            Text(
              s.peerName,
              style: const TextStyle(
                  color: Colors.white,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  fontSize: 11),
            ),
            Text(
              'RTT: ${s.rttMs.toStringAsFixed(1)} ms  '
              'Jitter: ${s.jitterMs.toStringAsFixed(1)} ms  '
              'Loss: ${s.lossPct.toStringAsFixed(1)}%',
              style: TextStyle(
                color: s.lossPct > 5
                    ? Colors.redAccent
                    : s.rttMs > 150
                        ? Colors.amber
                        : Colors.greenAccent,
                fontFamily: 'monospace',
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 4),
          ],
        ],
      ),
    );
  }
}

// ── Top bar ─────────────────────────────────────────────────────────────────
class _TopBar extends StatelessWidget {
  final AppColors colors;
  final String elapsed;
  final CallMode mode;
  final int peerCount;
  final bool statsVisible;
  final VoidCallback onToggleStats;

  const _TopBar({
    required this.colors,
    required this.elapsed,
    required this.mode,
    required this.peerCount,
    required this.statsVisible,
    required this.onToggleStats,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      color: Colors.black54,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          // Mode icon
          Icon(
            mode == CallMode.screenShare
                ? Icons.screen_share
                : mode == CallMode.video
                    ? Icons.videocam
                    : Icons.call,
            color: Colors.white70,
            size: 18,
          ),
          const SizedBox(width: 8),
          // Mode label
          Text(
            mode == CallMode.screenShare
                ? 'SCREEN SHARE'
                : mode == CallMode.video
                    ? 'VIDEO CALL'
                    : 'AUDIO CALL',
            style: const TextStyle(
                color: Colors.white70,
                fontFamily: 'monospace',
                fontSize: 12),
          ),
          if (peerCount > 1) ...[
            const SizedBox(width: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: colors.accent.withOpacity(0.25),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$peerCount peers',
                style: TextStyle(
                    color: colors.accent,
                    fontFamily: 'monospace',
                    fontSize: 10),
              ),
            ),
          ],
          const Spacer(),
          // Elapsed
          Text(elapsed,
              style: const TextStyle(
                  color: Colors.white,
                  fontFamily: 'monospace',
                  fontSize: 14,
                  fontWeight: FontWeight.bold)),
          const SizedBox(width: 12),
          // Stats toggle
          _TopBtn(
            icon: statsVisible ? Icons.analytics : Icons.analytics_outlined,
            label: 'STATS',
            color: statsVisible ? Colors.greenAccent : Colors.white54,
            onTap: onToggleStats,
          ),
        ],
      ),
    );
  }
}

class _TopBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _TopBtn(
      {required this.icon,
      required this.label,
      required this.color,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    color: color, fontFamily: 'monospace', fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

// ── Control bar ─────────────────────────────────────────────────────────────
class _ControlBar extends StatelessWidget {
  final AppColors colors;
  const _ControlBar({required this.colors});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<CallService>();
    final isVideo =
        svc.mode == CallMode.video || svc.mode == CallMode.screenShare;

    return Container(
      height: 88,
      color: Colors.black.withOpacity(0.7),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Mic toggle
          _CallControl(
            icon: svc.micMuted ? Icons.mic_off : Icons.mic,
            label: svc.micMuted ? 'UNMUTE' : 'MUTE',
            color: svc.micMuted ? Colors.redAccent : Colors.white,
            bgColor: svc.micMuted
                ? Colors.redAccent.withOpacity(0.2)
                : Colors.white12,
            onTap: () => svc.toggleMic(),
          ),
          const SizedBox(width: 16),

          // Camera toggle (only in video mode)
          if (isVideo) ...[
            _CallControl(
              icon: svc.camOff ? Icons.videocam_off : Icons.videocam,
              label: svc.camOff ? 'CAM ON' : 'CAM OFF',
              color: svc.camOff ? Colors.redAccent : Colors.white,
              bgColor: svc.camOff
                  ? Colors.redAccent.withOpacity(0.2)
                  : Colors.white12,
              onTap: () => svc.toggleCamera(),
            ),
            const SizedBox(width: 16),
          ],

          // Screen share ↔ Camera switch (available in any call mode)
          _CallControl(
            icon: svc.mode == CallMode.screenShare
                ? Icons.videocam
                : Icons.screen_share,
            label: svc.mode == CallMode.screenShare ? 'CAMERA' : 'SCREEN',
            color: Colors.white,
            bgColor: Colors.white12,
            onTap: () async {
              if (svc.mode == CallMode.screenShare) {
                await svc.switchToCamera();
              } else {
                await svc.switchToScreenShare();
              }
            },
          ),
          const SizedBox(width: 16),

          // Hang up
          _CallControl(
            icon: Icons.call_end,
            label: 'END',
            color: Colors.white,
            bgColor: Colors.redAccent,
            size: 56,
            onTap: () async {
              await svc.hangup();
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }
}

class _CallControl extends StatefulWidget {
  final IconData icon;
  final String label;
  final Color color;
  final Color bgColor;
  final double size;
  final VoidCallback onTap;

  const _CallControl({
    required this.icon,
    required this.label,
    required this.color,
    required this.bgColor,
    required this.onTap,
    this.size = 48,
  });

  @override
  State<_CallControl> createState() => _CallControlState();
}

class _CallControlState extends State<_CallControl> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.9 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.bgColor,
              ),
              child: Icon(widget.icon, color: widget.color, size: widget.size * 0.45),
            ),
            const SizedBox(height: 5),
            Text(
              widget.label,
              style: const TextStyle(
                color: Colors.white70,
                fontFamily: 'monospace',
                fontSize: 9,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
