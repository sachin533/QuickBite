import 'package:flutter/material.dart';

/// QuickBite brand palette + Material 3 theme.
///
/// The reference layouts call for a warm off-white page with vivid orange
/// highlights and soft rounded surfaces; everything in the UI pulls its
/// colours from here so the three screens stay visually consistent.
abstract final class Brand {
  /// Primary action orange — buttons, links, prices, active chips.
  static const Color orange = Color(0xFFEA580C);

  /// Deeper orange for gradients and hover/pressed emphasis.
  static const Color orangeDeep = Color(0xFFC2410C);

  /// Tint used for chips, badges and soft panels.
  static const Color orangeSoft = Color(0xFFFFEDD5);

  /// Warm off-white page background.
  static const Color warmBg = Color(0xFFFFF7F0);

  /// Warm card surface (slightly warmer than pure white).
  static const Color warmSurface = Color(0xFFFFFDF9);

  /// Body ink (never pure black, to keep the warm palette).
  static const Color ink = Color(0xFF2B1A0E);

  /// Secondary text.
  static const Color inkSoft = Color(0xFF7C6353);

  /// Rating stars.
  static const Color gold = Color(0xFFF59E0B);

  /// "Open now" / positive state.
  static const Color leaf = Color(0xFF16A34A);

  static const BorderRadius cardRadius =
      BorderRadius.all(Radius.circular(20));

  static const BorderRadius controlRadius =
      BorderRadius.all(Radius.circular(12));

  /// Vertical gradient used behind hero imagery.
  static const Gradient heroGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFF97316), Color(0xFFEA580C), Color(0xFFC2410C)],
  );
}

ThemeData quickbiteTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;

  final scheme = isDark
      ? ColorScheme.fromSeed(
          seedColor: Brand.orangeDeep,
          brightness: Brightness.dark,
        ).copyWith(
          primary: const Color(0xFFFB923C),
          onPrimary: const Color(0xFF431A00),
          secondary: const Color(0xFFFDBA74),
          surface: const Color(0xFF1C1512),
          onSurface: const Color(0xFFF6E8DD),
          outline: const Color(0xFF8A7566),
          outlineVariant: const Color(0xFF3B2E27),
        )
      : ColorScheme.fromSeed(
          seedColor: Brand.orangeDeep,
          brightness: Brightness.light,
        ).copyWith(
          primary: Brand.orange,
          onPrimary: Colors.white,
          primaryContainer: Brand.orangeSoft,
          onPrimaryContainer: const Color(0xFF7C2D12),
          secondary: const Color(0xFFFB923C),
          onSecondary: const Color(0xFF431A00),
          secondaryContainer: const Color(0xFFFFE8D6),
          onSecondaryContainer: const Color(0xFF7C2D12),
          surface: Colors.white,
          onSurface: Brand.ink,
          surfaceContainerLowest: Colors.white,
          surfaceContainerLow: Brand.warmSurface,
          surfaceContainer: const Color(0xFFFFF1E6),
          outline: const Color(0xFFC9B3A1),
          outlineVariant: const Color(0xFFF0E2D4),
          error: const Color(0xFFDC2626),
          onError: Colors.white,
        );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor:
        isDark ? const Color(0xFF15100D) : Brand.warmBg,
    splashFactory: InkRipple.splashFactory,
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: isDark ? const Color(0xFF241B16) : Colors.white,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: Brand.controlRadius,
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: Brand.controlRadius,
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: Brand.controlRadius,
        borderSide: BorderSide(color: scheme.primary, width: 1.6),
      ),
      labelStyle: TextStyle(color: scheme.onSurfaceVariant),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
  );
}
