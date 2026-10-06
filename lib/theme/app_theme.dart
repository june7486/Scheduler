import 'package:flutter/material.dart';

/// The decorative treatment painted *behind* the app content for a skin.
enum SkinDeco {
  /// Flat solid canvas (default).
  plain,

  /// Ruled notebook paper with a red margin line.
  ruled,

  /// Graph / grid paper.
  grid,

  /// Soft diagonal two-tone gradient.
  gradient,
}

/// A resolved colour palette for one skin at one brightness (light or dark).
///
/// [indigo] is the primary accent, the rest stay low-key. Each palette also
/// carries its skin [id] + [emoji] and its background [deco] so the whole look
/// travels together.
class AppPalette {
  final String id;
  final String emoji;
  final Color indigo; // primary accent
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
  final SkinDeco deco;

  const AppPalette({
    required this.id,
    required this.emoji,
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
    this.deco = SkinDeco.plain,
  });

  /// A soft tint of a category colour that stays visible on the surface.
  Color tint(int colorValue, double opacity) =>
      Color(colorValue).withValues(alpha: opacity);
}

/// The catalogue of available skins.
///
/// Each skin provides a light and a dark palette. The whole app re-skins by
/// swapping the active skin id — colours AND the decorative backdrop update
/// together.
class AppSkins {
  static const String defaultId = 'sage';

  /// Ordered list of skin ids (also the picker order).
  static const List<String> ids = [
    'sage',
    'notebook',
    'midnight',
    'ocean',
    'sunset',
    'forest',
  ];

  static const Map<String, AppPalette> _light = {
    // 1) Sage — a quiet, natural paper aesthetic (default).
    'sage': AppPalette(
      id: 'sage',
      emoji: '🌿',
      indigo: Color(0xFF6C7A5D),
      indigoDark: Color(0xFF556149),
      teal: Color(0xFF8D9C7B),
      bg: Color(0xFFE4E6DC),
      card: Color(0xFFFBFAF5),
      ink: Color(0xFF2E2E2D),
      inkSoft: Color(0xFF70746B),
      line: Color(0xFFD3D6C9),
      danger: Color(0xFFB0513C),
      soft: Color(0xFFEDEEE5),
      paper: Color(0xFFF4F2E9),
      tracker: Color(0xFFE2E4D8),
      onAccent: Color(0xFFFFFFFF),
    ),

    // 2) Notebook — cream ruled paper, blue ink headings, red pen accents.
    'notebook': AppPalette(
      id: 'notebook',
      emoji: '📓',
      indigo: Color(0xFF3B5BA5), // blue ink pen
      indigoDark: Color(0xFF2E477F),
      teal: Color(0xFF9B2D20), // red pen
      bg: Color(0xFFF7F4EA), // cream notebook page
      card: Color(0xFFFEFCF6),
      ink: Color(0xFF33322E), // charcoal pen
      inkSoft: Color(0xFF6B675E),
      line: Color(0xFF9DC1DD), // faint blue ruled line
      danger: Color(0xFFB23A2E),
      soft: Color(0xFFF1ECDD),
      paper: Color(0xFFFFFDF7),
      tracker: Color(0xFFE8E2D2),
      onAccent: Color(0xFFFFFFFF),
      deco: SkinDeco.ruled,
    ),

    // 3) Midnight — deep indigo / violet, gradient canvas.
    'midnight': AppPalette(
      id: 'midnight',
      emoji: '🌙',
      indigo: Color(0xFF5B5BD6),
      indigoDark: Color(0xFF4444B0),
      teal: Color(0xFF9A6BD8),
      bg: Color(0xFFEEF0FB),
      card: Color(0xFFFFFFFF),
      ink: Color(0xFF1E2138),
      inkSoft: Color(0xFF666B8A),
      line: Color(0xFFD9DCF0),
      danger: Color(0xFFC0504A),
      soft: Color(0xFFEFF1FA),
      paper: Color(0xFFF6F7FE),
      tracker: Color(0xFFE1E4F6),
      onAccent: Color(0xFFFFFFFF),
      deco: SkinDeco.gradient,
    ),

    // 4) Ocean — cool teal / blue.
    'ocean': AppPalette(
      id: 'ocean',
      emoji: '🌊',
      indigo: Color(0xFF1F7A8C),
      indigoDark: Color(0xFF16606F),
      teal: Color(0xFF3B9DB0),
      bg: Color(0xFFE8F1F2),
      card: Color(0xFFFFFFFF),
      ink: Color(0xFF16333A),
      inkSoft: Color(0xFF5C7C84),
      line: Color(0xFFCDE0E3),
      danger: Color(0xFFCC5A45),
      soft: Color(0xFFEDF5F6),
      paper: Color(0xFFF3F9FA),
      tracker: Color(0xFFD8E8EA),
      onAccent: Color(0xFFFFFFFF),
      deco: SkinDeco.gradient,
    ),

    // 5) Sunset — warm coral / amber.
    'sunset': AppPalette(
      id: 'sunset',
      emoji: '🌅',
      indigo: Color(0xFFC05A3E),
      indigoDark: Color(0xFF9C4530),
      teal: Color(0xFFD98A3D),
      bg: Color(0xFFFBEDE4),
      card: Color(0xFFFFF8F3),
      ink: Color(0xFF3A2620),
      inkSoft: Color(0xFF8A6A5E),
      line: Color(0xFFEEDBCE),
      danger: Color(0xFFB23A2E),
      soft: Color(0xFFF8E7DA),
      paper: Color(0xFFFFF6EF),
      tracker: Color(0xFFF2DFD1),
      onAccent: Color(0xFFFFFFFF),
      deco: SkinDeco.gradient,
    ),

    // 6) Forest — deep calm green.
    'forest': AppPalette(
      id: 'forest',
      emoji: '🌲',
      indigo: Color(0xFF2E6B4F),
      indigoDark: Color(0xFF235339),
      teal: Color(0xFF4E9A6E),
      bg: Color(0xFFE6EFE6),
      card: Color(0xFFFBFDFA),
      ink: Color(0xFF1F2E24),
      inkSoft: Color(0xFF5F7568),
      line: Color(0xFFCFE0D3),
      danger: Color(0xFFB0513C),
      soft: Color(0xFFEDF4ED),
      paper: Color(0xFFF4FAF4),
      tracker: Color(0xFFDCE9DE),
      onAccent: Color(0xFFFFFFFF),
    ),
  };

  static const Map<String, AppPalette> _dark = {
    'sage': AppPalette(
      id: 'sage',
      emoji: '🌿',
      indigo: Color(0xFFA7B892),
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
    ),

    'notebook': AppPalette(
      id: 'notebook',
      emoji: '📓',
      indigo: Color(0xFF8FB4F0), // blue ink (night)
      indigoDark: Color(0xFF6E93D6),
      teal: Color(0xFFE8907F), // red pen (night)
      bg: Color(0xFF1C1B18), // dark paper
      card: Color(0xFF252420),
      ink: Color(0xFFEDE9DD),
      inkSoft: Color(0xFFA9A497),
      line: Color(0xFF3A4256), // dim blue rule
      danger: Color(0xFFE08A75),
      soft: Color(0xFF2E2C26),
      paper: Color(0xFF232219),
      tracker: Color(0xFF302E27),
      onAccent: Color(0xFF14140F),
      deco: SkinDeco.ruled,
    ),

    'midnight': AppPalette(
      id: 'midnight',
      emoji: '🌙',
      indigo: Color(0xFF9B9BF5),
      indigoDark: Color(0xFF7E7EE6),
      teal: Color(0xFFC29BF0),
      bg: Color(0xFF0E1020),
      card: Color(0xFF1A1D33),
      ink: Color(0xFFE7E9F7),
      inkSoft: Color(0xFF9AA0C4),
      line: Color(0xFF2C3050),
      danger: Color(0xFFE08A75),
      soft: Color(0xFF1F233D),
      paper: Color(0xFF191C30),
      tracker: Color(0xFF232744),
      onAccent: Color(0xFF0B0D18),
      deco: SkinDeco.gradient,
    ),

    'ocean': AppPalette(
      id: 'ocean',
      emoji: '🌊',
      indigo: Color(0xFF6FD3E0),
      indigoDark: Color(0xFF4FB4C2),
      teal: Color(0xFF8FE0D0),
      bg: Color(0xFF0A1A1F),
      card: Color(0xFF12262C),
      ink: Color(0xFFDDEBEE),
      inkSoft: Color(0xFF8FAEB5),
      line: Color(0xFF203D45),
      danger: Color(0xFFE08A75),
      soft: Color(0xFF173037),
      paper: Color(0xFF102229),
      tracker: Color(0xFF1B373D),
      onAccent: Color(0xFF06232A),
      deco: SkinDeco.gradient,
    ),

    'sunset': AppPalette(
      id: 'sunset',
      emoji: '🌅',
      indigo: Color(0xFFF0A080),
      indigoDark: Color(0xFFD9835F),
      teal: Color(0xFFE8B86A),
      bg: Color(0xFF201310),
      card: Color(0xFF2C1A16),
      ink: Color(0xFFF4E4DC),
      inkSoft: Color(0xFFC09E90),
      line: Color(0xFF43291F),
      danger: Color(0xFFE08A75),
      soft: Color(0xFF35201A),
      paper: Color(0xFF291713),
      tracker: Color(0xFF3A231D),
      onAccent: Color(0xFF241009),
      deco: SkinDeco.gradient,
    ),

    'forest': AppPalette(
      id: 'forest',
      emoji: '🌲',
      indigo: Color(0xFF7FC79B),
      indigoDark: Color(0xFF5FA87C),
      teal: Color(0xFF9BD8B0),
      bg: Color(0xFF0E1712),
      card: Color(0xFF16241B),
      ink: Color(0xFFE2EFE5),
      inkSoft: Color(0xFF93AC9C),
      line: Color(0xFF233A2B),
      danger: Color(0xFFE08A75),
      soft: Color(0xFF1B2C21),
      paper: Color(0xFF132018),
      tracker: Color(0xFF1F3226),
      onAccent: Color(0xFF0A150E),
    ),
  };

  static AppPalette lightFor(String id) =>
      _light[id] ?? _light[defaultId]!;

  static AppPalette darkFor(String id) => _dark[id] ?? _dark[defaultId]!;

  static AppPalette forId(String id, Brightness b) =>
      b == Brightness.dark ? darkFor(id) : lightFor(id);

  /// Emoji badge for a skin id (used in the picker before a theme is active).
  static String emojiFor(String id) => lightFor(id).emoji;
}

// ---------------- Global active theme ----------------
//
// Widgets read colours via the `p` accessor (e.g. `p.ink`, `p.card`) without
// threading a palette through every constructor. The app root keeps these in
// sync with the selected skin + the effective brightness.

String _skinId = AppSkins.defaultId;
Brightness _brightness = Brightness.light;
bool _handwriting = true;

/// The palette currently in effect.
AppPalette get p => AppSkins.forId(_skinId, _brightness);
Brightness get globalBrightness => _brightness;
String get currentSkinId => _skinId;

/// Whether the hand-writing (pen) look is currently applied. Defaults on, so
/// the notebook skin reads like real note-taking out of the box; the user can
/// turn it off from the skin picker.
bool get handwritingOn => _handwriting;

/// A hand-writing font family for a given purpose:
///   * `'pen'`  → Nanum Pen (thin, fast felt-tip) — used for body + titles.
///   * `'mark'` → Gaegu (rounder, heavier) — used for accents / asterisks.
/// Returns `null` when the hand-writing look is disabled so callers can keep
/// the default Material font.
String? handFamily([String kind = 'pen']) {
  if (!handwritingOn) return null;
  return kind == 'mark' ? 'Gaegu' : 'NanumPen';
}

/// Selects the active skin (called by the app root from the store).
void setSkin(String id) {
  _skinId = AppSkins.ids.contains(id) ? id : AppSkins.defaultId;
}

/// User preference for the hand-writing look on non-notebook skins.
void setHandwriting(bool on) => _handwriting = on;

/// Updates the effective brightness (called by the MaterialApp builder).
void setGlobalBrightness(Brightness b) => _brightness = b;

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
  AppPalette get ac => p;
}

class AppTheme {
  static ThemeData build(String skinId, Brightness brightness) {
    final p = AppSkins.forId(skinId, brightness);
    final base = brightness == Brightness.dark
        ? ThemeData.dark(useMaterial3: true)
        : ThemeData.light(useMaterial3: true);

    // Non-flat skins paint their own backdrop behind the app, so let the
    // scaffold show through.
    final transparentCanvas = p.deco != SkinDeco.plain;

    final theme = base.copyWith(
      scaffoldBackgroundColor:
          transparentCanvas ? Colors.transparent : p.bg,
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
          fontSize: handwritingOn ? 20 : 16,
          fontFamily: handFamily(),
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
          textStyle: TextStyle(
            fontSize: handwritingOn ? 16 : 13,
            fontFamily: handFamily(),
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    );

    // Hand-writing (pen) feel — swap the whole text theme to a Korean
    // hand-writing family so the notebook skin reads like real note-taking.
    if (handwritingOn) {
      final hand = handFamily('pen')!;
      return theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamily: hand),
        primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: hand),
      );
    }
    return theme;
  }

  /// Maps a category colour value to a soft tinted background.
  static Color tint(int colorValue, double opacity) =>
      Color(colorValue).withValues(alpha: opacity);
}
