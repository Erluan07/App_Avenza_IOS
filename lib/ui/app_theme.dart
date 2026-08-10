/// Sistema de diseño de la app.
///
/// Pensado para uso en campo: contraste alto para leerse bajo sol directo,
/// superficies neutras (no el tinte violáceo que Material 3 pone por defecto,
/// que sobre cartografía distrae), y objetivos táctiles amplios para dedos con
/// guantes. Un verde topográfico como color primario y un ámbar cálido para las
/// herramientas y estados activos, que resalta sobre el verde del mapa.
library;

import 'package:flutter/material.dart';

/// Colores propios de la app que no encajan en el `ColorScheme` de Material.
///
/// Se exponen como [ThemeExtension] para que cambien solos entre claro y
/// oscuro y los widgets los lean del tema, sin colores incrustados.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.measure,
    required this.accuracyGood,
    required this.accuracyMedium,
    required this.accuracyPoor,
    required this.recording,
  });

  /// Ámbar de las herramientas de medición y trazado en curso.
  final Color measure;

  /// Semáforo de precisión del GPS.
  final Color accuracyGood;
  final Color accuracyMedium;
  final Color accuracyPoor;

  /// Rojo del punto de grabación activa.
  final Color recording;

  @override
  AppColors copyWith({
    Color? measure,
    Color? accuracyGood,
    Color? accuracyMedium,
    Color? accuracyPoor,
    Color? recording,
  }) =>
      AppColors(
        measure: measure ?? this.measure,
        accuracyGood: accuracyGood ?? this.accuracyGood,
        accuracyMedium: accuracyMedium ?? this.accuracyMedium,
        accuracyPoor: accuracyPoor ?? this.accuracyPoor,
        recording: recording ?? this.recording,
      );

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other == null) return this;
    return AppColors(
      measure: Color.lerp(measure, other.measure, t)!,
      accuracyGood: Color.lerp(accuracyGood, other.accuracyGood, t)!,
      accuracyMedium: Color.lerp(accuracyMedium, other.accuracyMedium, t)!,
      accuracyPoor: Color.lerp(accuracyPoor, other.accuracyPoor, t)!,
      recording: Color.lerp(recording, other.recording, t)!,
    );
  }

  static const light = AppColors(
    measure: Color(0xFFE8590C),
    accuracyGood: Color(0xFF2E7D32),
    accuracyMedium: Color(0xFFED6C02),
    accuracyPoor: Color(0xFFC62828),
    recording: Color(0xFFD32F2F),
  );

  static const dark = AppColors(
    measure: Color(0xFFFF922B),
    accuracyGood: Color(0xFF66BB6A),
    accuracyMedium: Color(0xFFFFA726),
    accuracyPoor: Color(0xFFEF5350),
    recording: Color(0xFFFF5252),
  );
}

/// Atajo para leer los colores propios: `context.appColors.measure`.
extension AppColorsX on BuildContext {
  AppColors get appColors => Theme.of(this).extension<AppColors>()!;
}

abstract final class AppTheme {
  /// Verde bosque: base del color primario en ambos modos.
  static const Color _seed = Color(0xFF1F6E43);

  /// Radios consistentes. Los contenedores grandes son más redondeados que los
  /// controles, para dar jerarquía sin que nada se vea inflado.
  static const double radiusSmall = 10;
  static const double radiusMedium = 14;
  static const double radiusLarge = 20;

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;

    // Se parte de un esquema armónico y se neutralizan las superficies: el
    // tinte violáceo de M3 se ve bien en una app de redes sociales, pero sobre
    // un mapa compite con el contenido.
    final base = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: brightness,
    );

    final neutralSurface = isDark ? const Color(0xFF15181A) : Colors.white;
    final scheme = base.copyWith(
      surface: neutralSurface,
      surfaceContainerLowest:
          isDark ? const Color(0xFF101315) : const Color(0xFFFFFFFF),
      surfaceContainerLow:
          isDark ? const Color(0xFF181C1E) : const Color(0xFFF6F7F5),
      surfaceContainer:
          isDark ? const Color(0xFF1C2022) : const Color(0xFFF0F2EF),
      surfaceContainerHigh:
          isDark ? const Color(0xFF23282A) : const Color(0xFFE9ECE8),
      surfaceContainerHighest:
          isDark ? const Color(0xFF2A2F31) : const Color(0xFFE2E6E1),
    );

    final textTheme = _textTheme(scheme);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: textTheme,
      splashFactory: InkSparkle.splashFactory,
      extensions: [isDark ? AppColors.dark : AppColors.light],

      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 2,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge,
      ),

      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
      ),

      // 52 px de alto: cómodo de tocar con guantes o al caminar.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 52),
          textStyle: textTheme.labelLarge,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSmall),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 52),
          textStyle: textTheme.labelLarge,
          side: BorderSide(color: scheme.outline),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSmall),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 44),
          textStyle: textTheme.labelLarge,
        ),
      ),

      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 3,
        highlightElevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
        ),
      ),

      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          selectedBackgroundColor: scheme.primary,
          selectedForegroundColor: scheme.onPrimary,
          minimumSize: const Size(0, 48),
        ),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        side: BorderSide.none,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
        ),
        labelStyle: textTheme.labelMedium,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        modalElevation: 8,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(radiusLarge)),
        ),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLarge),
        ),
      ),

      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
      ),

      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
        ),
      ),

      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.6),
        space: 1,
        thickness: 1,
      ),

      popupMenuTheme: PopupMenuThemeData(
        surfaceTintColor: Colors.transparent,
        color: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
        ),
      ),
    );
  }

  /// Escala tipográfica con un poco más de peso en los títulos que la de
  /// Material por defecto: en exteriores un texto fino se pierde.
  static TextTheme _textTheme(ColorScheme scheme) {
    final base = Typography.material2021(platform: TargetPlatform.android)
        .black
        .apply(
          bodyColor: scheme.onSurface,
          displayColor: scheme.onSurface,
        );

    return base.copyWith(
      titleLarge: base.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
      ),
      titleMedium: base.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      titleSmall: base.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      labelLarge: base.labelLarge?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
      ),
    );
  }
}
