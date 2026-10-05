import 'package:flutter/material.dart';

/// A resolved colour palette for one brightness (light or dark).
///
/// A serene, natural "paper" aesthetic — a muted sage canvas, warm cream cards
/// and soft charcoal type (referenced from the user's notice-poster palette).
/// [indigo] is the primary accent (a quiet sage-olive); the rest stays low-key.
class AppPalette {
  final Color indigo; // primary accent (sage olive)
  final Color indigoDark;
  final Color teal; // secondary accent
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
    indigo: Color(0xFF6C7A5D), // sage olive
    indigoDark: Color(0xFF556149),
    teal: Color(0xFF8D9C7B), // light sage
    bg: Color(0xFFE4E6DC), // soft sage canvas
    card: Color(0xFFFBFAF5), // warm cream paper
    ink: Color(0xFF2E2E2D), // soft charcoal
    inkSoft: Color(0xFF70746B), // muted olive-gray
    line: Color(0xFFD3D6C9),
    danger: Color(0xFFB0513C), // muted terracotta
    soft: Color(0xFFEDEEE5),
    paper: Color(0xFFF4F2E9),
    tracker: Color(0xFFE2E4D8),
    onAccent: Color(0xFFFFFFFF),
  );

  static const dark = AppPalette(
    indigo: Color(0xFFA7B892), // light sage
    indigoDark: Color(0xFF80906C),
    teal: Color(0xFF9DB08A),
    bg: Color(0xFF171A14),
    card: Color(0xFF22261E),
    ink: Color(0xFFECEDE2),
    inkSoft: Color(0xFFA2A996),
    line: Color(0xFF373C30),
    danger: Color(0xFFE08A75),
    soft: Color(0xFF2C3127),
    paper: Color(0xFF23271E),
    tracker: Color(0xFF2B3026),
    onAccent: Color(0xFF14170F),
  );

  /// A soft tint of a category colour that stays visible on the surface.
  Color tint(int colorValue, double opacity) =>
      Color(colorValue).withValues(alpha: opacity);
}

/// Global palette accessor, kept in sync with the active brightness by the
/// app root and the MaterialApp builder. Lets widgets read theme colours via
/// `p.ink`, `p.card`, … without threading a palette parameter everywhere.
AppPalette _p = AppPalette.light;
Brightness _brightness = Brightness.light;
AppPalette get p => _p;
Brightness get globalBrightness => _brightness;

/// Updates the global palette (called by the app root on theme changes).
void setGlobalPalette(AppPalette palette) {
  _p = palette;
  _brightness = palette == AppPalette.dark
      ? Brightness.dark
      : Brightness.light;
}

/// Legible foreground for a category colour under the active brightness.
/// Bright yellows/oranges are darkened in light mode and lightened in dark
/// mode so category-coloured text stays readable on any background.
Color ct(Color base) => colorTone(base, _brightness);

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
