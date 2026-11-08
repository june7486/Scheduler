import 'package:flutter/material.dart';

import 'design_language.dart';

export 'design_language.dart';

/// A resolved colour palette for one skin at one brightness (light or dark).
///
/// A palette is **only colour**. Geometry, depth, and spacing belong to the
/// design language ([AppDesign]) and are deliberately not stored here: that is
/// what lets four very different structures reuse the same six colourways.
///
/// [indigo] is the primary accent, the rest stay low-key. Each palette also
/// carries its skin [id] + [emoji] so the picker can render it standalone.
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
  static const String defaultId = 'midnight';

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
String _designId = AppDesigns.defaultId;
Brightness _brightness = Brightness.light;
bool _handwriting = true;
String _fontKey = 'system'; // see AppFonts.ids
double _fontScale = 1.0;

/// The active design language (structure) — the "theme" in the new sense.
AppDesign get design => AppDesigns.of(_designId);

/// The active colourway (the palette chosen inside that design).
String get currentSkinId => _skinId;

/// The active design id.
String get currentDesignId => _designId;

/// Convenience: the geometry currently in effect.
SurfaceSpec get sx => design.surface;

/// Whether the current design wants the hand-writing look by default.
bool get designPrefersHandwriting => design.prefersHandwriting;

/// The catalogue of selectable app fonts.
///
/// [id]      — the persisted key (`Store.fontKey`).
/// [family]  — the registered font family, or null for the platform default.
/// [fallback]— a font stack used when [family] is null (e.g. Segoe UI on
///             Windows, then the bundled NanumGothic so Hangul always renders).
/// [hand]    — true for the hand-writing fonts (they get a size boost + the
///             highlighter feel, since pen scripts look smaller at a glance).
class AppFont {
  final String id;
  final String? family;
  final List<String> fallback;
  final bool hand;
  const AppFont(this.id, {this.family, this.fallback = const [], this.hand = false});
}

class AppFonts {
  /// Hand-writing (pen) scripts.
  static const String pen = 'pen'; // NanumPenScript
  static const String gaegu = 'gaegu'; // Gaegu

  /// Typographic families bundled with the app (all open-source).
  static const String gothic = 'gothic'; // NanumGothic
  static const String myeongjo = 'myeongjo'; // NanumMyeongjo (serif)
  static const String dodum = 'dodum'; // Gowun Dodum
  static const String jua = 'jua'; // Jua (rounded)
  static const String dohyeon = 'dohyeon'; // Do Hyeon (display)
  static const String black = 'black'; // Black Han Sans (poster)

  /// The system / Windows default stack (Segoe UI first, then a bundled
  /// Hangul-capable fallback so Korean text is never left to tofu).
  static const String system = 'system';

  static const List<String> ids = [
    system,
    pen,
    gaegu,
    gothic,
    myeongjo,
    dodum,
    jua,
    dohyeon,
    black,
  ];

  static const Map<String, AppFont> _byId = {
    system: AppFont(system, family: null, fallback: [
      'Segoe UI', 'Malgun Gothic', '맑은 고딕', 'Apple SD Gothic Neo', 'NanumGothic', 'Roboto', 'Arial',
    ]),
    pen: AppFont(pen, family: 'NanumPen', hand: true),
    gaegu: AppFont(gaegu, family: 'Gaegu', hand: true),
    gothic: AppFont(gothic, family: 'NanumGothic'),
    myeongjo: AppFont(myeongjo, family: 'NanumMyeongjo'),
    dodum: AppFont(dodum, family: 'GowunDodum'),
    jua: AppFont(jua, family: 'Jua'),
    dohyeon: AppFont(dohyeon, family: 'DoHyeon'),
    black: AppFont(black, family: 'BlackHanSans'),
  };

  static AppFont of(String id) => _byId[id] ?? _byId[system]!;
  static bool isHand(String id) => of(id).hand;
  static bool contains(String id) => _byId.containsKey(id);
}

/// The palette currently in effect.
AppPalette get p => AppSkins.forId(_skinId, _brightness);
Brightness get globalBrightness => _brightness;

/// The user's font choice (see [Store.fontKey]).
String get currentFontKey => _fontKey;

/// Global text-size multiplier (0.85 – 1.35).
double get fontScale => _fontScale;

/// Whether the hand-writing (pen) look is currently applied. This is the case
/// whenever a hand-writing font is selected (pen / gaegu), or the legacy
/// "auto + handwriting" toggle is on.
bool get handwritingOn =>
    AppFonts.isHand(_fontKey) ||
    (_fontKey == 'auto' && (_handwriting || design.prefersHandwriting));

/// The currently selected font definition.
AppFont get currentFont => AppFonts.of(_fontKey);

/// The active font family (null ⇒ the platform default family).
String? get fontFamily => currentFont.family;

/// The fallback stack for the active font (empty when a family is set).
List<String> get fontFamilyFallback => currentFont.fallback;

/// Convenience: the body font family used across the app. `kind == 'mark'`
/// keeps returning the rounder Gaegu accent when a hand-writing look is on.
String? handFamily([String kind = 'pen']) {
  if (kind == 'mark') return handwritingOn ? 'Gaegu' : currentFont.family;
  return currentFont.family;
}

/// Extra size multiplier applied on top of the user's slider. Hand-writing
/// scripts (NanumPen / Gaegu) have a small x-height and read noticeably
/// smaller than typographic fonts, so we bump them up so they stay legible.
double get handwritingBoost => handwritingOn ? 1.22 : 1.0;

/// The effective text-scale actually applied to the whole app — the user's
/// slider value, plus the hand-writing legibility boost.
double get effectiveFontScale =>
    _fontScale * handwritingBoost * design.typeScale;

/// Selects the active skin (colourway). Called by the app root from the store.
void setSkin(String id) {
  _skinId = AppSkins.ids.contains(id) ? id : AppSkins.defaultId;
}

/// Selects the active design language (structure). Called by the app root.
void setDesign(String id) {
  _designId = AppDesigns.contains(id) ? id : AppDesigns.defaultId;
}

/// User preference for the hand-writing look on non-notebook skins.
void setHandwriting(bool on) => _handwriting = on;

/// Applies the user's font family / size choice (called by the app root).
void setFontPrefs(String key, double scale) {
  _fontKey = AppFonts.contains(key) ? key : 'system';
  _fontScale = scale.clamp(0.85, 1.6);
}

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
  /// Builds the Material theme for [skinId] (colourway) inside the active
  /// [AppDesign] (structure).
  ///
  /// Geometry comes from the design, colour from the palette. Nothing here
  /// hard-codes a radius or a shadow: every surface decision is read from
  /// `design.surface`, which is what makes one dataset look like four
  /// different products.
  static ThemeData build(String skinId, Brightness brightness) {
    final p = AppSkins.forId(skinId, brightness);
    final d = design;
    final s = d.surface;
    final base = brightness == Brightness.dark
        ? ThemeData.dark(useMaterial3: true)
        : ThemeData.light(useMaterial3: true);

    // Designs with their own backdrop let the scaffold show through so the
    // decoration is visible behind list content.
    final transparentCanvas = d.deco != SkinDeco.plain;

    final fontArgs = (
      family: fontFamily,
      fallback: fontFamilyFallback.isEmpty ? null : fontFamilyFallback,
    );

    final border = s.borderWidth <= 0
        ? BorderSide.none
        : BorderSide(color: p.line, width: s.borderWidth);

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
        backgroundColor: s.headerBand ? p.soft : p.card,
        foregroundColor: s.headerAccentTitle ? p.indigo : p.ink,
        elevation: s.elevation > 0.4 ? 1 : 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        shape: s.headerRule
            ? Border(bottom: BorderSide(color: p.line, width: s.borderWidth))
            : null,
        titleTextStyle: TextStyle(
          color: s.headerAccentTitle ? p.indigo : p.ink,
          fontSize: (handwritingOn ? 21 : 17) * d.typeScale,
          fontFamily: fontArgs.family,
          fontFamilyFallback: fontArgs.fallback,
          fontWeight: s.headerAccentTitle ? FontWeight.w800 : FontWeight.w600,
          letterSpacing: s.tracking,
        ),
      ),
      cardTheme: CardThemeData(
        color: p.card,
        elevation: s.elevation,
        shadowColor: Colors.black.withValues(alpha: 0.16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(s.radius),
          side: border,
        ),
        margin: EdgeInsets.zero,
      ),
      dividerTheme: DividerThemeData(
        color: p.line,
        thickness: s.borderWidth <= 0 ? s.ruleWidth : s.borderWidth,
        space: 1,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(s.radiusLarge),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(s.radiusLarge),
          ),
        ),
      ),
      textTheme: base.textTheme.apply(
        bodyColor: p.ink,
        displayColor: p.ink,
        fontFamily: fontArgs.family,
        fontFamilyFallback: fontArgs.fallback,
      ),
      primaryTextTheme: base.primaryTextTheme.apply(
        bodyColor: p.ink,
        displayColor: p.ink,
        fontFamily: fontArgs.family,
        fontFamilyFallback: fontArgs.fallback,
      ),
      iconTheme: IconThemeData(color: p.inkSoft),
      listTileTheme: ListTileThemeData(
        iconColor: p.inkSoft,
        textColor: p.ink,
        shape: s.radius > 0
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(s.radiusSmall),
              )
            : const RoundedRectangleBorder(),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: s.solidChips ? p.soft : Colors.transparent,
        side: border,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(
            s.pillChips ? s.radiusSmall * 4 : s.radiusSmall,
          ),
        ),
        labelStyle: TextStyle(
          color: p.ink,
          fontFamily: fontArgs.family,
          fontFamilyFallback: fontArgs.fallback,
          letterSpacing: s.tracking,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.soft,
        hintStyle: TextStyle(color: p.inkSoft),
        contentPadding: EdgeInsets.symmetric(
          horizontal: 14,
          vertical: s.headerHeight < 70 ? 10 : 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(s.radiusSmall),
          borderSide: border,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(s.radiusSmall),
          borderSide: border,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(s.radiusSmall),
          borderSide: BorderSide(
            color: p.indigo,
            width: s.borderWidth <= 0 ? 2 : 1.4,
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: p.indigo,
          foregroundColor: p.onAccent,
          elevation: s.elevation > 0.3 ? s.elevation : 0,
          padding: EdgeInsets.symmetric(
            horizontal: 18,
            vertical: s.headerHeight < 70 ? 10 : 12,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(s.radiusSmall),
          ),
          textStyle: TextStyle(
            fontSize: (handwritingOn ? 17 : 14) * d.typeScale,
            fontFamily: fontArgs.family,
            fontFamilyFallback: fontArgs.fallback,
            fontWeight: FontWeight.w600,
            letterSpacing: s.tracking * 0.5,
          ),
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: s.roundCheck
            ? const CircleBorder()
            : RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(s.radiusSmall),
              ),
      ),
    );

    return theme;
  }

  /// Maps a category colour value to a soft tinted background.
  static Color tint(int colorValue, double opacity) =>
      Color(colorValue).withValues(alpha: opacity);
}
