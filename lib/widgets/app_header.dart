// lib/widgets/app_header.dart
//
// Header bar: logo, USER/IP, ONLINE indicator, NAME/THEME/SEARCH/EXIT buttons.
// When a call is active, shows a pulsing amber banner under the header.

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';
import 'dart:io' as io;

import '../p2p/call_service.dart';
import '../p2p/p2p_service.dart';
import '../theme/app_colors.dart';
import '../theme/theme_provider.dart';
import 'logs_dialog.dart';
import 'search_dialog.dart';

class AppHeader extends StatelessWidget {
  final AppColors colors;
  final bool isDark;
  final ValueChanged<SearchTarget>? onSearchTarget;

  const AppHeader({
    super.key,
    required this.colors,
    required this.isDark,
    this.onSearchTarget,
  });

  @override
  Widget build(BuildContext context) {
    final service = context.watch<P2PService>();
    final isInCall = context.watch<CallService>().isInCall;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── Main header row ───────────────────────────────────────────
        Container(
          height: 64,
          decoration: BoxDecoration(
            color: colors.bgSidebar,
            border: Border(bottom: BorderSide(color: colors.borderSoft)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              // Logo
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SvgPicture.asset(
                  'assets/icons/icon.svg',
                  width: 38,
                  height: 38,
                ),
              ),
              const SizedBox(width: 12),

              // User info
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'USER: ${service.myName}',
                    style: TextStyle(
                      color: colors.accent,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  Text(
                    'MY IP: ${service.myIp}',
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
              const Spacer(),

              // Online/offline dot + label
              _OnlineIndicator(colors: colors, isOnline: service.isOnline),
              const SizedBox(width: 14),

              // Call indicator (only when active)
              if (isInCall) ...[
                _CallBadge(colors: colors),
                const SizedBox(width: 10),
              ],

              // Buttons
              _HeaderButton(
                colors: colors,
                label: 'NAME',
                onTap: () => _showRenameDialog(context, service),
              ),
              const SizedBox(width: 8),
              _HeaderButton(
                colors: colors,
                label: isDark ? 'LIGHT' : 'DARK',
                onTap: () => context.read<ThemeProvider>().toggle(),
              ),
              const SizedBox(width: 8),
              _HeaderButton(
                colors: colors,
                label: 'SEARCH',
                onTap: () async {
                  final target = await showDialog<SearchTarget>(
                    context: context,
                    builder: (_) => SearchDialog(colors: colors),
                  );
                  if (target != null) {
                    onSearchTarget?.call(target);
                  }
                },
              ),
              const SizedBox(width: 8),
              _HeaderButton(
                colors: colors,
                label: 'LOGS',
                onTap: () => showDialog(
                  context: context,
                  builder: (_) =>
                      LogsDialog(colors: colors, service: service),
                ),
              ),
              const SizedBox(width: 8),
              _HeaderButton(
                colors: colors,
                label: 'EXIT',
                isDestructive: true,
                onTap: () => _showExitDialog(context),
              ),
            ],
          ),
        ),

        // ── Call active banner ────────────────────────────────────────
        if (isInCall) _CallBanner(colors: colors),
      ],
    );
  }

  void _showRenameDialog(BuildContext context, P2PService service) {
    final c = TextEditingController(text: service.myName);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.bgCard,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(
          'Change display name',
          style: TextStyle(
              color: colors.textPrimary,
              fontFamily: 'monospace',
              fontWeight: FontWeight.bold),
        ),
        content: TextField(
          controller: c,
          autofocus: true,
          style: TextStyle(
              color: colors.textPrimary, fontFamily: 'monospace'),
          decoration: const InputDecoration(hintText: 'New name'),
          onSubmitted: (_) async {
            await service.setMyName(c.text);
            if (ctx.mounted) Navigator.pop(ctx);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel',
                style: TextStyle(
                    color: colors.textSecondary,
                    fontFamily: 'monospace')),
          ),
          ElevatedButton(
            onPressed: () async {
              await service.setMyName(c.text);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showExitDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.bgCard,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('Exit',
            style: TextStyle(
                color: colors.textPrimary,
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold)),
        content: Text(
          'Are you sure you want to exit P2P NODE?',
          style: TextStyle(
              color: colors.textSecondary,
              fontFamily: 'monospace',
              fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel',
                style: TextStyle(
                    color: colors.textSecondary,
                    fontFamily: 'monospace')),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: colors.accent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              await _performExit();
            },
            child: const Text('Exit',
                style: TextStyle(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _performExit() async {
    try {
      if (kIsWeb) {
        await SystemNavigator.pop();
        return;
      }
      if (io.Platform.isWindows || io.Platform.isLinux || io.Platform.isMacOS) {
        io.exit(0);
      }
      await SystemNavigator.pop();
    } catch (_) {
      await SystemNavigator.pop();
    }
  }
}

// ── Online/offline indicator ──────────────────────────────────────────────
class _OnlineIndicator extends StatelessWidget {
  final AppColors colors;
  final bool isOnline;

  const _OnlineIndicator({required this.colors, required this.isOnline});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(Icons.circle,
            size: 9,
            color: isOnline ? colors.accent2 : colors.textSecondary),
        const SizedBox(width: 5),
        Text(
          isOnline ? 'ONLINE' : 'OFFLINE',
          style: TextStyle(
            color: isOnline ? colors.accent2 : colors.textSecondary,
            fontFamily: 'monospace',
            fontSize: 13,
          ),
        ),
      ],
    );
  }
}

// ── Call badge (compact, in header row) ──────────────────────────────────
class _CallBadge extends StatefulWidget {
  final AppColors colors;
  const _CallBadge({required this.colors});

  @override
  State<_CallBadge> createState() => _CallBadgeState();
}

class _CallBadgeState extends State<_CallBadge>
    with SingleTickerProviderStateMixin {
  late AnimationController _ac;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ac = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900));
    _anim = Tween(begin: 0.4, end: 1.0).animate(
        CurvedAnimation(parent: _ac, curve: Curves.easeInOut));
    _ac.repeat(reverse: true);
  }

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.amber.withOpacity(0.15),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.amber.withOpacity(0.5)),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.call, size: 12, color: Colors.amber),
            SizedBox(width: 5),
            Text(
              'IN CALL',
              style: TextStyle(
                color: Colors.amber,
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Call active banner below header ──────────────────────────────────────
class _CallBanner extends StatelessWidget {
  final AppColors colors;
  const _CallBanner({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 5),
      color: Colors.amber.withOpacity(0.12),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.phone_in_talk, size: 13, color: Colors.amber),
          SizedBox(width: 8),
          Text(
            'CALL IN PROGRESS — file transfers throttled to protect voice quality',
            style: TextStyle(
              color: Colors.amber,
              fontFamily: 'monospace',
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Header button ──────────────────────────────────────────────────────────
class _HeaderButton extends StatefulWidget {
  final AppColors colors;
  final String label;
  final VoidCallback onTap;
  final bool isDestructive;

  const _HeaderButton({
    required this.colors,
    required this.label,
    required this.onTap,
    this.isDestructive = false,
  });

  @override
  State<_HeaderButton> createState() => _HeaderButtonState();
}

class _HeaderButtonState extends State<_HeaderButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final bg = _hovered ? c.bgHover : c.bgCard;
    final fg = widget.isDestructive ? c.accent3 : c.textPrimary;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
              color: bg, borderRadius: BorderRadius.circular(8)),
          child: Text(
            widget.label,
            style: TextStyle(
              color: fg,
              fontFamily: 'monospace',
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }
}
