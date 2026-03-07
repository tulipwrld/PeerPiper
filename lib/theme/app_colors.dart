import 'package:flutter/material.dart';

/// Mirrors Python's LIGHT_THEME / DARK_THEME dicts.
/// Use [AppColors.light] or [AppColors.dark] depending on the active theme.
class AppColors {
  final Color bgMain;
  final Color bgSidebar;
  final Color bgCard;
  final Color bgHover;
  final Color accent;
  final Color accent2;
  final Color accent3;
  final Color textPrimary;
  final Color textSecondary;
  final Color borderSoft;

  const AppColors({
    required this.bgMain,
    required this.bgSidebar,
    required this.bgCard,
    required this.bgHover,
    required this.accent,
    required this.accent2,
    required this.accent3,
    required this.textPrimary,
    required this.textSecondary,
    required this.borderSoft,
  });

  static const light = AppColors(
    bgMain:        Color(0xFFF9FBF4),
    bgSidebar:     Color(0xFFEBF0E3),
    bgCard:        Color(0xFFF1F2E8),
    bgHover:       Color(0xFF8BBE91),
    accent:        Color(0xFF67956A),
    accent2:       Color(0xFF8BBE91),
    accent3:       Color(0xFF67956A),
    textPrimary:   Color(0xFF2C3E4F),
    textSecondary: Color(0xFF5D6D7E),
    borderSoft:    Color(0xFFE8E8E8),
  );

  static const dark = AppColors(
    bgMain:        Color(0xFF06110B),
    bgSidebar:     Color(0xFF091911),
    bgCard:        Color(0xFF0A1E14),
    bgHover:       Color(0xFF006400),
    accent:        Color(0xFF50C878),
    accent2:       Color(0xFF008000),
    accent3:       Color(0xFF006400),
    textPrimary:   Color(0xFFE6EDF3),
    textSecondary: Color(0xFF9CA3AF),
    borderSoft:    Color(0xFF1C1C1C),
  );
}
