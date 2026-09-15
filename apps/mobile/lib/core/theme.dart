import 'package:flutter/material.dart';

const lime = Color(0xFFAAFA46);
const muted = Color(0xFFAFBDC4);
const panel = Color(0xFF182126);
ThemeData futbeatTheme() => ThemeData(
  fontFamily: 'FutBeatRoboto',
  brightness: Brightness.dark,
  useMaterial3: true,
  chipTheme: ChipThemeData(
    selectedColor: lime,
    checkmarkColor: const Color(0xFF0B1114),
    labelStyle: const TextStyle(fontFamily: 'FutBeatRoboto', fontSize: 13),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
  ),
  scaffoldBackgroundColor: const Color(0xFF0B1114),
  colorScheme: ColorScheme.fromSeed(
    seedColor: lime,
    brightness: Brightness.dark,
    primary: lime,
    surface: panel,
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: Color(0xFF0B1114),
    surfaceTintColor: Colors.transparent,
  ),
  cardTheme: CardThemeData(
    color: panel,
    elevation: 0,
    margin: const EdgeInsets.only(bottom: 12),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: const BorderSide(color: Color(0xFF2B373D)),
    ),
  ),
  navigationBarTheme: NavigationBarThemeData(
    backgroundColor: const Color(0xFF10181C),
    indicatorColor: lime.withValues(alpha: .16),
    labelTextStyle: WidgetStateProperty.resolveWith(
      (states) => TextStyle(
        fontSize: 11,
        color: states.contains(WidgetState.selected) ? lime : muted,
      ),
    ),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: panel,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide.none,
    ),
  ),
);
