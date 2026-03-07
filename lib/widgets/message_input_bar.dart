// lib/widgets/message_input_bar.dart
//
// Input bar: text field + SEND (Enter) + BROADCAST (Ctrl+Enter) + FILE button.
// FILE opens a native file-picker dialog (file_picker package).
// Falls back to a path-input dialog on platforms where file_picker may fail.

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/peer.dart';
import '../models/group.dart';
import '../theme/app_colors.dart';

class MessageInputBar extends StatefulWidget {
  final AppColors colors;
  final Peer? selectedPeer;
  final ChatGroup? selectedGroup;
  final bool isAiChat;
  final void Function(String text) onSend;
  final void Function(String text) onBroadcast;
  final Future<void> Function(String path) onSendFilePath;

  const MessageInputBar({
    super.key,
    required this.colors,
    required this.selectedPeer,
    required this.selectedGroup,
    required this.isAiChat,
    required this.onSend,
    required this.onBroadcast,
    required this.onSendFilePath,
  });

  @override
  State<MessageInputBar> createState() => _MessageInputBarState();
}

class _MessageInputBarState extends State<MessageInputBar> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  bool _sending = false;

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send() {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
    _ctrl.clear();
    _focus.requestFocus();
  }

  void _broadcast() {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    widget.onBroadcast(text);
    _ctrl.clear();
    _focus.requestFocus();
  }

  Future<void> _pickFile() async {
    if (widget.selectedPeer == null) {
      if (widget.isAiChat) {
        _showSnack('File send is disabled for AI chat');
        return;
      }
      _showSnack('Select a peer first');
      return;
    }
    if (widget.selectedGroup != null) {
      _showSnack('File send is only for direct peer chats');
      return;
    }
    if (widget.selectedPeer?.isOnline == false) {
      _showSnack('Peer is offline');
      return;
    }

    setState(() => _sending = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        withData: false, // stream large files
        withReadStream: false,
      );

      if (result == null || result.files.isEmpty) {
        setState(() => _sending = false);
        return;
      }

      final picked = result.files.first;
      final path = picked.path;
      if (path == null) {
        _showSnack('Could not read file path');
        setState(() => _sending = false);
        return;
      }

      await widget.onSendFilePath(path);
    } catch (e) {
      _showSnack('File error: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final peer = widget.selectedPeer;
    final group = widget.selectedGroup;
    final canSend = widget.isAiChat || group != null || (peer != null && peer.isOnline);
    final hint = widget.isAiChat
        ? 'Ask AI...'
        : group != null
        ? 'Message group "${group.name}"...'
        : peer == null
            ? 'Select a peer/group to chat'
            : peer.isOnline
            ? 'Message ${peer.name}... (Enter=Send, Ctrl+Enter=Broadcast)'
            : '${peer.name} is offline';

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      decoration: BoxDecoration(
        color: c.bgSidebar,
        border: Border(top: BorderSide(color: c.borderSoft)),
      ),
      child: Row(
        children: [
          // File attach button
          Tooltip(
            message: 'Send file',
            child: _sending
                ? SizedBox(
                    width: 36,
                    height: 36,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: c.accent),
                    ),
                  )
                : _IconBtn(
                    icon: Icons.attach_file,
                    colors: c,
                    enabled: canSend && group == null && !widget.isAiChat,
                    onTap: _pickFile,
                  ),
          ),
          const SizedBox(width: 8),

          // Text field
          Expanded(
            child: KeyboardListener(
              focusNode: FocusNode(),
              onKeyEvent: (event) {
                if (event is KeyDownEvent) {
                  final ctrl = HardwareKeyboard.instance.isControlPressed;
                  if (ctrl &&
                      event.logicalKey == LogicalKeyboardKey.enter) {
                    _broadcast();
                  }
                }
              },
              child: TextField(
                controller: _ctrl,
                focusNode: _focus,
                enabled: canSend,
                minLines: 1,
                maxLines: 4,
                style: TextStyle(
                    color: c.textPrimary,
                    fontFamily: 'monospace',
                    fontSize: 13),
                decoration: InputDecoration(
                  hintText: hint,
                  hintStyle: TextStyle(
                      color: c.textSecondary, fontFamily: 'monospace'),
                  filled: true,
                  fillColor: c.bgMain,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: c.borderSoft),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: c.borderSoft),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: c.accent),
                  ),
                  disabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(
                        color: c.borderSoft.withOpacity(0.4)),
                  ),
                ),
                onSubmitted: canSend ? (_) => _send() : null,
              ),
            ),
          ),
          const SizedBox(width: 8),

          // Broadcast button (all peers)
          Tooltip(
            message: 'Broadcast (Ctrl+Enter)',
            child: _IconBtn(
              icon: Icons.campaign,
              colors: c,
              enabled: canSend && group == null && !widget.isAiChat,
              onTap: _broadcast,
            ),
          ),
          const SizedBox(width: 6),

          // Send button
          _SendBtn(
            colors: c,
            enabled: canSend,
            onTap: _send,
          ),
        ],
      ),
    );
  }
}

// ── Icon button ───────────────────────────────────────────────────────────
class _IconBtn extends StatefulWidget {
  final IconData icon;
  final AppColors colors;
  final bool enabled;
  final VoidCallback onTap;

  const _IconBtn({
    required this.icon,
    required this.colors,
    required this.enabled,
    required this.onTap,
  });

  @override
  State<_IconBtn> createState() => _IconBtnState();
}

class _IconBtnState extends State<_IconBtn> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: widget.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: widget.enabled ? widget.onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: _hovered && widget.enabled ? c.bgHover : c.bgCard,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.borderSoft),
          ),
          child: Icon(
            widget.icon,
            size: 18,
            color: widget.enabled ? c.accent : c.textSecondary,
          ),
        ),
      ),
    );
  }
}

// ── Send button ───────────────────────────────────────────────────────────
class _SendBtn extends StatefulWidget {
  final AppColors colors;
  final bool enabled;
  final VoidCallback onTap;

  const _SendBtn(
      {required this.colors, required this.enabled, required this.onTap});

  @override
  State<_SendBtn> createState() => _SendBtnState();
}

class _SendBtnState extends State<_SendBtn> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: widget.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: widget.enabled ? widget.onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          decoration: BoxDecoration(
            color: widget.enabled
                ? (_hovered
                    ? c.accent.withOpacity(0.85)
                    : c.accent)
                : c.bgCard,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.send,
                  size: 14,
                  color: widget.enabled
                      ? Colors.white
                      : c.textSecondary),
              const SizedBox(width: 6),
              Text(
                'SEND',
                style: TextStyle(
                  color: widget.enabled ? Colors.white : c.textSecondary,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
