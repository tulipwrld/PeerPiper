// lib/main.dart

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'theme/app_colors.dart';
import 'theme/theme_provider.dart';
import 'p2p/p2p_service.dart';
import 'p2p/real_p2p_service.dart';
import 'p2p/call_service.dart';
import 'screens/chat_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const P2PNodeApp());
}

class P2PNodeApp extends StatelessWidget {
  const P2PNodeApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Build service instances manually so we can cross-wire them.
    final callService = CallService();
    final p2pService = RealP2PService()..wireCallService(callService);

    return MultiProvider(
      providers: [
        ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
        ChangeNotifierProvider<CallService>.value(value: callService),
        // P2PService is the abstract interface; RealP2PService is the impl.
        ChangeNotifierProvider<P2PService>.value(value: p2pService),
      ],
      child: Consumer<ThemeProvider>(
        builder: (_, tp, __) => MaterialApp(
          title: 'P2P NODE',
          debugShowCheckedModeBanner: false,
          themeMode: tp.isDark ? ThemeMode.dark : ThemeMode.light,
          theme: _buildTheme(AppColors.light, Brightness.light),
          darkTheme: _buildTheme(AppColors.dark, Brightness.dark),
          home: const ChatScreen(),
        ),
      ),
    );
  }

  ThemeData _buildTheme(AppColors c, Brightness brightness) {
    return ThemeData(
      brightness: brightness,
      useMaterial3: true,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: c.accent,
        onPrimary: Colors.white,
        secondary: c.accent2,
        onSecondary: Colors.white,
        error: Colors.redAccent,
        onError: Colors.white,
        surface: c.bgCard,
        onSurface: c.textPrimary,
        // ignore: deprecated_member_use
        background: c.bgMain,
        // ignore: deprecated_member_use
        onBackground: c.textPrimary,
      ),
      scaffoldBackgroundColor: c.bgMain,
      fontFamily: 'monospace',
      dialogBackgroundColor: c.bgCard,
      snackBarTheme: SnackBarThemeData(
        backgroundColor: c.bgCard,
        contentTextStyle: TextStyle(
            color: c.textPrimary, fontFamily: 'monospace'),
      ),
    );
  }
}