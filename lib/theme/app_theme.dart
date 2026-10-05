import 'package:flutter/material.dart';

/// A resolved colour palette for one brightness (light or dark).
///
/// The design blends Style 1 (Modern Material — indigo/blue, cards, soft
/// shadows) with Style 3 (Minimal/Muji — whitespace, thin dividers, refined
/// small typography). Indigo is the accent; the rest stays quiet.
class AppPalette {
  final Color indigo;
  final Color indigoDark;
  final Color teal;
  final Color bg;
  final Color card;
  final Color ink;
  final Color inkSoft;
  final Color line;
  final Color danger;
  final Color soft; // input fill / subtle surface
  final Color paper; // print-like surface
  final Color tracker; // bar-graph track
  final Color onAccent; // text/icon on top of the accent colour

  const AppPalette({
    required this.indigo,
    required this.indigoDark,
    required this.teal,
    required this.bg,
    required this.card,
    required this.ink,
    required this.inkSoft,
    required this.line,
    required this.danger,
    required this.soft,
    required this.paper,
    required this.tracker,
    required this.onAccent,
  });

  static const light = AppPalette(
    indigo: Color(0xFF3F51B5),
    indigoDark: Color(0xFF303F9F),
    teal: Color(0xFF00897B),
    bg: Color(0xFFF7F8FC),
    card: Color(0xFFFFFFFF),
    ink: Color(0xFF1F2233),
    inkSoft: Color(0xFF5A5F73),
    line: Color(0xFFE3E6EF),
    danger: Color(0xFFE53935),
    soft: Color(0xFFF2F3F8),
    paper: Color(0xFFFAF9F6),
    tracker: Color(0xFFEDEFF5),
    onAccent: Color(0xFFFFFFFF),
  );

  static const dark = AppPalette(
    indigo: Color(0xFF8C9EFF),
    indigoDark: Color(0xFF5C6BC0),
    teal: Color(0xFF4DB6AC),
    bg: Color(0xFF111219),
    card: Color(0xFF1C1E27),
    ink: Color(0xFFECEDF5),
    inkSoft: Color(0xFF9EA3B8),
    line: Color(0xFF2B2D3A),
    danger: Color(0xFFEF5350),
    soft: Color(0xFF262833),
    paper: Color(0xFF1B1D26),
    tracker: Color(0xFF2A2C39),
    onAccent: Color(0xFF0E0F14),
  );

  /// A soft tint of a category colour that stays visible on the surface.
  Color tint(int colorValue, double opacity) =>
      Color(colorValue).withValues(alpha: opacity);
}

/// Global palette accessor, kept in sync with the active brightness by the
/// app root and the MaterialApp builder. Lets widgets read theme colours via
/// `p.ink`, `p.card`, … without threading a palette parameter everywhere.
AppPalette _p = AppPalette.light;
AppPalette get p => _p;

/// Updates the global palette (called by the app root on theme changes).
void setGlobalPalette(AppPalette palette) => _p = palette;

/// Returns a legible variant of a category [base] colour for use as a
/// *foreground* (text / icon). Bright yellows and oranges are darkened in
/// light mode (black text stays readable) and lightened in dark mode.
Color colorTone(Color base, Brightness b) {
  final h = HSLColor.fromColor(base);
  final l = b == Brightness.dark
      ? h.lightness.clamp(0.66, 0.82)
      : h.lightness.clamp(0.26, 0.46);
  return h.withLightness(l).toColor();
}

/// Convenience accessor: `context.ac` returns the palette for the *effective*
/// brightness (so it works automatically with ThemeMode.system).
extension AppColorsX on BuildContext {
  AppPalette get ac => Theme.of(this).brightness == Brightness.dark
      ? AppPalette.dark
      : AppPalette.light;
}

class AppTheme {
  static ThemeData build(Brightness brightness) {
    final p = brightness == Brightness.dark
        ? AppPalette.dark
        : AppPalette.light;
    final base = brightness == Brightness.dark
        ? ThemeData.dark(useMaterial3: true)
        : ThemeData.light(useMaterial3: true);

    return base.copyWith(
      scaffoldBackgroundColor: p.bg,
      colorScheme: base.colorScheme.copyWith(
        brightness: brightness,
        primary: p.indigo,
        secondary: p.teal,
        surface: p.card,
        error: p.danger,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: p.card,
        foregroundColor: p.ink,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: p.ink,
          fontSize: 16,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
      cardTheme: CardThemeData(
        color: p.card,
        elevation: 1,
        shadowColor: brightness == Brightness.dark
            ? const Color(0x33000000)
            : const Color(0x14000000),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        margin: EdgeInsets.zero,
      ),
      dividerTheme: DividerThemeData(color: p.line, thickness: 0.7, space: 1),
      dialogTheme: DialogThemeData(backgroundColor: p.card),
      bottomSheetTheme: BottomSheetThemeData(backgroundColor: p.card),
      textTheme: base.textTheme.apply(bodyColor: p.ink, displayColor: p.ink),
      iconTheme: IconThemeData(color: p.inkSoft),
      listTileTheme: ListTileThemeData(iconColor: p.inkSoft, textColor: p.ink),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.soft,
        hintStyle: TextStyle(color: p.inkSoft),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: p.indigo, width: 1.4),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: p.indigo,
          foregroundColor: p.onAccent,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    );
  }

  /// Maps a category colour value to a soft tinted background.
  static Color tint(int colorValue, double opacity) =>
      Color(colorValue).withValues(alpha: opacity);
}
