/// The design system.
///
/// Structure is adapted from the MIT-licensed Flutter Dashboard Template
/// (© 2023 Hany Sameh) — the sidebar-rail shell, card grid, tinted icon tiles
/// and generous radii. See THIRD_PARTY_NOTICES.md.
///
/// Two deliberate departures from that template:
///
/// * **Light, not dark.** A school administrator uses this next to paper, in a
///   bright office, often on a projector. White reads as professional and
///   prints legibly.
/// * **Brand colour is blue, not coral.** This dashboard's whole job is to say
///   what needs attention, so red must mean "problem" and nothing else. A red
///   brand would spend the one colour the Action Board depends on.
///
/// Sizes here are fixed, never a fraction of the screen. The template sizes
/// everything as `context.width * 0.06`, which collapses at unusual aspect
/// ratios and is what makes labels wrap mid-word.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AppColors {
  const AppColors._();

  // --- surfaces ---------------------------------------------------------
  /// Page background. Very slightly grey so white cards separate from it
  /// without needing heavy shadows.
  static const canvas = Color(0xFFF7F8FA);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceMuted = Color(0xFFF2F4F7);
  static const border = Color(0xFFE4E7EC);
  static const borderStrong = Color(0xFFD0D5DD);

  // --- text -------------------------------------------------------------
  static const textPrimary = Color(0xFF101828);
  static const textSecondary = Color(0xFF667085);
  static const textTertiary = Color(0xFF98A2B3);

  // --- brand ------------------------------------------------------------
  static const brand = Color(0xFF2563EB);
  static const brandDark = Color(0xFF1D4ED8);
  static const brandTint = Color(0xFFEFF4FF);

  // --- status -----------------------------------------------------------
  // Reserved strictly for meaning. Nothing decorative uses these.
  static const danger = Color(0xFFD92D20);
  static const dangerTint = Color(0xFFFEF3F2);
  static const warning = Color(0xFFB54708);
  static const warningTint = Color(0xFFFFFAEB);
  static const success = Color(0xFF067647);
  static const successTint = Color(0xFFECFDF3);

  // --- subject / category accents ---------------------------------------
  // For timetable cells and chart series, where colour is an identifier
  // rather than a judgement.
  static const accents = <Color>[
    Color(0xFF2563EB), // blue
    Color(0xFF7A5AF8), // violet
    Color(0xFF0E9384), // teal
    Color(0xFFDD2590), // pink
    Color(0xFFCA8504), // ochre
    Color(0xFF4E5BA6), // indigo grey
    Color(0xFF15803D), // green
  ];
}

class AppRadius {
  const AppRadius._();
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
}

class AppSpace {
  const AppSpace._();
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

/// A soft lift, not a drop shadow. Cards should read as slightly raised paper.
const kCardShadow = <BoxShadow>[
  BoxShadow(color: Color(0x0D101828), blurRadius: 2, offset: Offset(0, 1)),
  BoxShadow(color: Color(0x14101828), blurRadius: 3, offset: Offset(0, 1)),
];

ThemeData buildAppTheme() {
  const scheme = ColorScheme.light(
    primary: AppColors.brand,
    onPrimary: Colors.white,
    primaryContainer: AppColors.brandTint,
    onPrimaryContainer: AppColors.brandDark,
    secondary: AppColors.brand,
    onSecondary: Colors.white,
    secondaryContainer: AppColors.brandTint,
    onSecondaryContainer: AppColors.brandDark,
    error: AppColors.danger,
    onError: Colors.white,
    errorContainer: AppColors.dangerTint,
    onErrorContainer: AppColors.danger,
    surface: AppColors.surface,
    onSurface: AppColors.textPrimary,
    onSurfaceVariant: AppColors.textSecondary,
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: Colors.white,
    surfaceContainer: AppColors.surfaceMuted,
    surfaceContainerHigh: AppColors.surfaceMuted,
    surfaceContainerHighest: AppColors.surfaceMuted,
    outline: AppColors.borderStrong,
    outlineVariant: AppColors.border,
  );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.canvas,
    // Inter-like metrics without shipping a font file: keeps the bundle small
    // and avoids a licence to track.
    fontFamily: 'Segoe UI',
  );

  return base.copyWith(
    textTheme: base.textTheme
        .apply(
          bodyColor: AppColors.textPrimary,
          displayColor: AppColors.textPrimary,
        )
        .copyWith(
          headlineSmall: const TextStyle(
              fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -0.3),
          titleLarge: const TextStyle(
              fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.2),
          titleMedium: const TextStyle(
              fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: -0.1),
          bodyMedium: const TextStyle(fontSize: 14, height: 1.45),
          bodySmall: const TextStyle(
              fontSize: 12.5, height: 1.4, color: AppColors.textSecondary),
          labelLarge:
              const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
          labelSmall: const TextStyle(
              fontSize: 11.5, fontWeight: FontWeight.w500,
              color: AppColors.textSecondary),
        ),

    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      foregroundColor: AppColors.textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
        letterSpacing: -0.2,
      ),
      systemOverlayStyle: SystemUiOverlayStyle.dark,
    ),

    cardTheme: CardThemeData(
      color: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: const BorderSide(color: AppColors.border),
      ),
    ),

    dividerTheme: const DividerThemeData(
      color: AppColors.border,
      thickness: 1,
      space: 1,
    ),

    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.brand,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),

    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.textPrimary,
        side: const BorderSide(color: AppColors.borderStrong),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),

    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.brand,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      isDense: true,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      hintStyle: const TextStyle(color: AppColors.textTertiary, fontSize: 14),
      labelStyle: const TextStyle(color: AppColors.textSecondary, fontSize: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        borderSide: const BorderSide(color: AppColors.brand, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        borderSide: const BorderSide(color: AppColors.danger),
      ),
    ),

    chipTheme: ChipThemeData(
      backgroundColor: AppColors.surfaceMuted,
      side: const BorderSide(color: AppColors.border),
      labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm)),
    ),

    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.textPrimary,
      contentTextStyle: const TextStyle(color: Colors.white, fontSize: 14),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm)),
    ),

    listTileTheme: const ListTileThemeData(
      iconColor: AppColors.textSecondary,
      textColor: AppColors.textPrimary,
    ),

    progressIndicatorTheme:
        const ProgressIndicatorThemeData(color: AppColors.brand),

    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: AppColors.textPrimary,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      textStyle: const TextStyle(color: Colors.white, fontSize: 12),
    ),
  );
}
