import 'package:flutter/material.dart';
import 'app_colors.dart';

/// Mirrors Python's toggle_theme() + _is_dark flag.
/// Wrap the app in a [ChangeNotifierProvider<ThemeProvider>] then
/// call [context.watch<ThemeProvider>().colors] anywhere in the tree.
class ThemeProvider extends ChangeNotifier {
  bool _isDark = false;

  bool get isDark => _isDark;

  AppColors get colors => _isDark ? AppColors.dark : AppColors.light;

  void toggle() {
    _isDark = !_isDark;
    notifyListeners();
  }
}
