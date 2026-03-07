// lib/widgets/device_picker_dialog.dart
//
// Device selector dialog: camera, microphone, screen share mode.
// Shows a live camera preview when a video device is selected.
// Call before startCall() to let user choose input devices.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';

import '../p2p/call_service.dart';
import '../theme/app_colors.dart';

// Result returned from the dialog.
class DevicePickerResult {
  final CallMode mode;
  final String? audioDeviceId;
  final String? videoDeviceId;
  DevicePickerResult({
    required this.mode,
    this.audioDeviceId,
    this.videoDeviceId,
  });
}

Future<DevicePickerResult?> showDevicePicker(
    BuildContext context, AppColors colors) {
  return showDialog<DevicePickerResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => DevicePickerDialog(colors: colors),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
class DevicePickerDialog extends StatefulWidget {
  final AppColors colors;
  const DevicePickerDialog({super.key, required this.colors});

  @override
  State<DevicePickerDialog> createState() => _DevicePickerDialogState();
}

class _DevicePickerDialogState extends State<DevicePickerDialog> {
  List<MediaDeviceInfo> _cameras = [];
  List<MediaDeviceInfo> _microphones = [];
  String? _selCameraId;
  String? _selMicId;
  CallMode _mode = CallMode.audioOnly;

  // Live preview
  MediaStream? _previewStream;
  final RTCVideoRenderer _previewRenderer = RTCVideoRenderer();
  bool _previewInit = false;
  bool _loadingDevices = true;

  @override
  void initState() {
    super.initState();
    _initPreview();
    _loadDevices();
  }

  Future<void> _initPreview() async {
    await _previewRenderer.initialize();
    _previewInit = true;
  }

  Future<void> _loadDevices() async {
    try {
      final svc = context.read<CallService>();
      final cams = await svc.getCameras();
      final mics = await svc.getMicrophones();
      if (mounted) {
        setState(() {
          _cameras = cams;
          _microphones = mics;
          _selCameraId = cams.isNotEmpty ? cams.first.deviceId : null;
          _selMicId = mics.isNotEmpty ? mics.first.deviceId : null;
          _loadingDevices = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingDevices = false);
    }
  }

  Future<void> _startPreview() async {
    await _stopPreview();
    if (_mode != CallMode.video || _selCameraId == null) return;
    try {
      _previewStream = await navigator.mediaDevices.getUserMedia({
        'video': {'deviceId': _selCameraId, 'width': 320, 'height': 240},
        'audio': false,
      });
      _previewRenderer.srcObject = _previewStream;
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _stopPreview() async {
    if (_previewStream != null) {
      for (final t in _previewStream!.getTracks()) {
        await t.stop();
      }
      await _previewStream!.dispose();
      _previewStream = null;
    }
    _previewRenderer.srcObject = null;
  }

  @override
  void dispose() {
    _stopPreview().then((_) {
      if (_previewInit) _previewRenderer.dispose();
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;

    return Dialog(
      backgroundColor: c.bgCard,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Title ─────────────────────────────────────────────────
              Row(
                children: [
                  Icon(Icons.settings_voice, color: c.accent, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'CALL SETTINGS',
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
              const SizedBox(height: 16),

              // ── Call mode ─────────────────────────────────────────────
              _SectionLabel(label: 'CALL TYPE', colors: c),
              const SizedBox(height: 8),
              Row(
                children: [
                  _ModeChip(
                    label: 'AUDIO',
                    icon: Icons.mic,
                    selected: _mode == CallMode.audioOnly,
                    colors: c,
                    onTap: () {
                      setState(() => _mode = CallMode.audioOnly);
                      _stopPreview();
                    },
                  ),
                  const SizedBox(width: 8),
                  _ModeChip(
                    label: 'VIDEO',
                    icon: Icons.videocam,
                    selected: _mode == CallMode.video,
                    colors: c,
                    onTap: () {
                      setState(() => _mode = CallMode.video);
                      _startPreview();
                    },
                  ),
                  const SizedBox(width: 8),
                  _ModeChip(
                    label: 'SCREEN',
                    icon: Icons.screen_share,
                    selected: _mode == CallMode.screenShare,
                    colors: c,
                    onTap: () {
                      setState(() => _mode = CallMode.screenShare);
                      _stopPreview();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // ── Microphone ────────────────────────────────────────────
              _SectionLabel(label: 'MICROPHONE', colors: c),
              const SizedBox(height: 8),
              _loadingDevices
                  ? _buildLoading(c)
                  : _microphones.isEmpty
                      ? _buildNoDevice(c, 'No microphone found')
                      : _buildDropdown(
                          colors: c,
                          value: _selMicId,
                          items: _microphones,
                          onChanged: (id) =>
                              setState(() => _selMicId = id),
                        ),
              const SizedBox(height: 16),

              // ── Camera ────────────────────────────────────────────────
              if (_mode == CallMode.video) ...[
                _SectionLabel(label: 'CAMERA', colors: c),
                const SizedBox(height: 8),
                _loadingDevices
                    ? _buildLoading(c)
                    : _cameras.isEmpty
                        ? _buildNoDevice(c, 'No camera found')
                        : _buildDropdown(
                            colors: c,
                            value: _selCameraId,
                            items: _cameras,
                            onChanged: (id) {
                              setState(() => _selCameraId = id);
                              _startPreview();
                            },
                          ),
                const SizedBox(height: 12),

                // Camera preview
                if (_previewStream != null && _previewInit)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      width: double.infinity,
                      height: 160,
                      color: Colors.black,
                      child: RTCVideoView(
                        _previewRenderer,
                        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                        mirror: true,
                      ),
                    ),
                  )
                else
                  _PreviewPlaceholder(colors: c),
                const SizedBox(height: 16),
              ],

              // ── Screen share info ─────────────────────────────────────
              if (_mode == CallMode.screenShare) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: c.accent.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: c.accent.withOpacity(0.2)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: c.accent, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Your OS will ask you to pick a screen or window after you press CALL.',
                          style: TextStyle(
                            color: c.textSecondary,
                            fontFamily: 'monospace',
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // ── Actions ───────────────────────────────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, null),
                    child: Text(
                      'CANCEL',
                      style: TextStyle(
                          color: c.textSecondary, fontFamily: 'monospace'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: () {
                      Navigator.pop(
                        context,
                        DevicePickerResult(
                          mode: _mode,
                          audioDeviceId: _selMicId,
                          videoDeviceId: _selCameraId,
                        ),
                      );
                    },
                    icon: const Icon(Icons.call, size: 16),
                    label: const Text(
                      'CALL',
                      style: TextStyle(
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4CAF50),
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

  Widget _buildDropdown({
    required AppColors colors,
    required String? value,
    required List<MediaDeviceInfo> items,
    required ValueChanged<String?> onChanged,
  }) {
    final c = colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: c.bgMain,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.borderSoft),
      ),
      child: DropdownButton<String>(
        value: value,
        isExpanded: true,
        dropdownColor: c.bgCard,
        underline: const SizedBox(),
        style: TextStyle(
            color: c.textPrimary, fontFamily: 'monospace', fontSize: 12),
        icon: Icon(Icons.arrow_drop_down, color: c.textSecondary),
        items: items
            .map((d) => DropdownMenuItem(
                  value: d.deviceId,
                  child: Text(
                    d.label.isNotEmpty ? d.label : d.deviceId ?? 'Device',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: c.textPrimary,
                        fontFamily: 'monospace',
                        fontSize: 12),
                  ),
                ))
            .toList(),
        onChanged: onChanged,
      ),
    );
  }

  Widget _buildLoading(AppColors c) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            SizedBox(
                width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: c.accent)),
            const SizedBox(width: 8),
            Text('Loading devices...',
                style: TextStyle(
                    color: c.textSecondary, fontFamily: 'monospace', fontSize: 11)),
          ],
        ),
      );

  Widget _buildNoDevice(AppColors c, String msg) =>
      Text(msg, style: TextStyle(
          color: c.textSecondary, fontFamily: 'monospace', fontSize: 11));
}

// ── Section label ─────────────────────────────────────────────────────────
class _SectionLabel extends StatelessWidget {
  final String label;
  final AppColors colors;
  const _SectionLabel({required this.label, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        color: colors.textSecondary,
        fontFamily: 'monospace',
        fontSize: 10,
        letterSpacing: 1.5,
      ),
    );
  }
}

// ── Mode chip ─────────────────────────────────────────────────────────────
class _ModeChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final AppColors colors;
  final VoidCallback onTap;
  const _ModeChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? c.accent.withOpacity(0.15) : c.bgMain,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? c.accent : c.borderSoft,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: selected ? c.accent : c.textSecondary),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: selected ? c.accent : c.textSecondary,
                fontFamily: 'monospace',
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Camera preview placeholder ────────────────────────────────────────────
class _PreviewPlaceholder extends StatelessWidget {
  final AppColors colors;
  const _PreviewPlaceholder({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: 140,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.borderSoft),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.videocam_off, color: colors.textSecondary, size: 32),
          const SizedBox(height: 8),
          Text(
            'Select a camera to preview',
            style: TextStyle(
                color: colors.textSecondary,
                fontFamily: 'monospace',
                fontSize: 11),
          ),
        ],
      ),
    );
  }
}