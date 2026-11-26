import 'package:flutter/material.dart';

/// FL-like dark palette (drawn by code, no Image-Line assets).
abstract final class C {
  static const bg = Color(0xFF262D31);
  static const panel = Color(0xFF353E44);
  static const panelHi = Color(0xFF444E55);
  static const bar = Color(0xFF1E2427);
  static const text = Color(0xFFD7DEE2);
  static const textDim = Color(0xFF8C979E);
  static const accent = Color(0xFFF59E3D); // FL orange
  static const green = Color(0xFF8BD14A);
  static const red = Color(0xFFE5534B);
  static const stepOffA = Color(0xFF59636A);
  static const stepOffB = Color(0xFF6E4D53); // alternate group of 4, like FL
  static const stepOn = Color(0xFFE8ECEF);
  static const playhead = Color(0xFF9BE15D);
}

ThemeData buildTheme() => ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: C.bg,
      colorScheme: const ColorScheme.dark(
        primary: C.accent,
        secondary: C.accent,
        secondaryContainer: C.accent,
        onSecondaryContainer: Colors.black,
        surface: C.panel,
      ),
      fontFamily: null,
      useMaterial3: true,
    );
