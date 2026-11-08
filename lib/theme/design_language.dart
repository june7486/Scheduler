import 'package:flutter/material.dart';

/// Decorative background treatment. Lives here (not with the palettes) because
/// it is a property of the *design language*, not of a colour choice.
enum SkinDeco { plain, ruled, grid, gradient, mesh, dotted }

/// How a design language shapes a surface.
///
/// Layout *intent* is unchanged across themes — what changes is the geometry:
/// corner sharpness, borders, depth, spacing, and how chips/checkboxes/headers
/// are drawn. This is the difference between "another shade of blue" and
/// "another architect drew the same building".
class SurfaceSpec {
  /// Corner radius for primary cards / rows.
  final double radius;

  /// Radius for small things (chips, badges, inputs).
  final double radiusSmall;

  /// Radius for sheets / dialogs / large panels.
  final double radiusLarge;

  /// 1 = a hairline edge. 0 = borderless, shaped only by fill.
  final double borderWidth;

  /// A rule thicker than the hairline, used by the editorial language.
  final double ruleWidth;

  /// Whether a leading colour bar is painted on rows.
  final bool edgeBar;

  /// The colour used for that bar (usually the category colour).
  final bool edgeBarUsesCategory;

  /// 0..1 — how much shadow to cast. 0 = flat.
  final double elevation;

  /// Extra inner breathing room inside cards.
  final EdgeInsets pad;

  /// Gap between list rows.
  final double rowGap;

  /// Height of the app header block.
  final double headerHeight;

  /// Horizontal padding inside the app header.
  final double headerPadX;

  /// True when the header sits on a coloured band (not the page background).
  final bool headerBand;

  /// True when the header title is drawn in the accent colour.
  final bool headerAccentTitle;

  /// Draw a bottom hairline under the header.
  final bool headerRule;

  /// Filled circle (dot) vs. square box for completion.
  final bool roundCheck;

  /// Pill-shaped category chips.
  final bool pillChips;

  /// Chip background filled solid (true) or only tinted (false).
  final bool solidChips;

  /// Header title case: 'normal' keeps the label, 'upper' shouts it.
  final String headerCase;

  /// Letter-spacing applied to small caps labels.
  final double tracking;

  const SurfaceSpec({
    required this.radius,
    required this.radiusSmall,
    required this.radiusLarge,
    this.borderWidth = 1,
    this.ruleWidth = 1,
    this.edgeBar = false,
    this.edgeBarUsesCategory = true,
    this.elevation = 0.4,
    this.pad = const EdgeInsets.fromLTRB(10, 8, 8, 8),
    this.rowGap = 8,
    this.headerHeight = 88,
    this.headerPadX = 16,
    this.headerBand = false,
    this.headerAccentTitle = false,
    this.headerRule = false,
    this.roundCheck = false,
    this.pillChips = true,
    this.solidChips = false,
    this.headerCase = 'normal',
    this.tracking = 0,
  });

  /// The box shadow for this language at a given strength multiplier.
  List<BoxShadow> shadows([double multiplier = 1]) {
    if (elevation <= 0 || multiplier <= 0) return const [];
    final a = (elevation * 0.14 * multiplier).clamp(0.0, 0.28);
    return [
      BoxShadow(
        color: Colors.black.withValues(alpha: a),
        blurRadius: 10 * elevation * multiplier,
        offset: Offset(0, 2 * elevation * multiplier),
      ),
    ];
  }
}

/// One design language: a name, a geometry, and its own decoration.
///
/// A [AppDesign] never contains colours — those arrive from the selected
/// palette. That separation is the whole point: the same source renders in
/// six colours and four completely different visual languages.
class AppDesign {
  final String id;
  final String emoji;

  /// 'flat' | 'soft' | 'desktop' | 'editorial' — drives icon + defaults.
  final String family;

  final SurfaceSpec surface;
  final SkinDeco deco;

  /// Multiplier applied to the user's text scale.
  final double typeScale;

  /// Whether the design leans on the hand-writing fonts by default.
  final bool prefersHandwriting;

  /// Weight used for task titles in this language.
  final FontWeight titleWeight;

  /// Weight used for section labels.
  final FontWeight labelWeight;

  const AppDesign({
    required this.id,
    required this.emoji,
    required this.family,
    required this.surface,
    this.deco = SkinDeco.plain,
    this.typeScale = 1.0,
    this.prefersHandwriting = false,
    this.titleWeight = FontWeight.w600,
    this.labelWeight = FontWeight.w700,
  });
}

/// The catalogue of design languages.
///
/// These are genuinely different structures, not recolours:
///
/// * **paper** — the original hand-written notebook. Generous radius, soft
///   shadows, ruled page, handwriting welcome.
/// * **studioe** — flat Swiss modernism. Almost no radius, hairline rules, no
///   shadow at all, tiny tracked caps. Ink does the work, not effects.
/// * **desk** — a dense work surface. Compact rows, crisp 8px corners, a
///   category edge bar on every row, banded header. Built for scanning.
/// * **gazette** — editorial print. Zero radius, thick top/bottom rules,
///   serif-ish weight, wide drop caps, no shadows, no tint. Newspaper logic.
class AppDesigns {
  static const String defaultId = 'paper';

  static const List<String> ids = ['paper', 'studioe', 'desk', 'gazette'];

  static const Map<String, AppDesign> _byId = {
    // 1) PAPER — the hand-written notebook. Warm, round, forgiving.
    'paper': AppDesign(
      id: 'paper',
      emoji: '📝',
      family: 'soft',
      deco: SkinDeco.ruled,
      typeScale: 1.0,
      prefersHandwriting: true,
      titleWeight: FontWeight.w600,
      surface: SurfaceSpec(
        radius: 12,
        radiusSmall: 6,
        radiusLarge: 18,
        borderWidth: 1,
        elevation: 0.55,
        pad: EdgeInsets.fromLTRB(10, 8, 8, 8),
        rowGap: 8,
        headerHeight: 92,
        headerPadX: 16,
        roundCheck: false,
        pillChips: true,
        tracking: 0,
      ),
    ),

    // 2) STUDIO — Swiss modernist. Rectilinear, flat, typographic.
    'studioe': AppDesign(
      id: 'studioe',
      emoji: '◼️',
      family: 'flat',
      deco: SkinDeco.dotted,
      typeScale: 0.97,
      titleWeight: FontWeight.w700,
      labelWeight: FontWeight.w800,
      surface: SurfaceSpec(
        radius: 0,
        radiusSmall: 0,
        radiusLarge: 0,
        borderWidth: 1,
        ruleWidth: 2,
        elevation: 0,
        pad: EdgeInsets.fromLTRB(14, 12, 12, 12),
        rowGap: 0,
        headerHeight: 76,
        headerPadX: 18,
        headerAccentTitle: true,
        headerRule: true,
        solidChips: true,
        pillChips: false,
        headerCase: 'upper',
        tracking: 1.4,
      ),
    ),

    // 3) DESK — dense work surface. Edge bars, banded header, tight rows.
    'desk': AppDesign(
      id: 'desk',
      emoji: '🗂️',
      family: 'desktop',
      deco: SkinDeco.mesh,
      typeScale: 1.0,
      titleWeight: FontWeight.w600,
      surface: SurfaceSpec(
        radius: 8,
        radiusSmall: 5,
        radiusLarge: 12,
        borderWidth: 1,
        elevation: 0.25,
        pad: EdgeInsets.fromLTRB(8, 6, 6, 6),
        rowGap: 4,
        headerHeight: 64,
        headerPadX: 12,
        headerBand: true,
        edgeBar: true,
        roundCheck: true,
        tracking: 0.2,
      ),
    ),

    // 4) GAZETTE — editorial print. Rules instead of boxes.
    'gazette': AppDesign(
      id: 'gazette',
      emoji: '📰',
      family: 'editorial',
      deco: SkinDeco.plain,
      typeScale: 1.02,
      titleWeight: FontWeight.w600,
      labelWeight: FontWeight.w700,
      surface: SurfaceSpec(
        radius: 0,
        radiusSmall: 0,
        radiusLarge: 0,
        borderWidth: 0,
        ruleWidth: 2,
        elevation: 0,
        pad: EdgeInsets.fromLTRB(4, 10, 4, 12),
        rowGap: 0,
        headerHeight: 104,
        headerPadX: 12,
        headerRule: true,
        headerAccentTitle: false,
        solidChips: false,
        pillChips: false,
        headerCase: 'normal',
        tracking: 0.6,
      ),
    ),
  };

  static AppDesign of(String id) => _byId[id] ?? _byId[defaultId]!;

  static bool contains(String id) => _byId.containsKey(id);

  static String emojiFor(String id) => of(id).emoji;
}
