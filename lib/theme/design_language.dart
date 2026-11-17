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
///
/// ## Density
/// The fields below `rowGap` are the *information-density* axis. They were added
/// when the dense designs arrived, because "how many rows fit on a phone" is not
/// a colour decision and cannot be faked with a smaller radius.
///
/// Every one of them defaults to the behaviour the older designs already had, so
/// adding them changed nothing on screen. That is deliberate: Paper, Studio E,
/// Desk and Gazette must look exactly as they did before.
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

  // ---------------- density ----------------
  //
  // Everything below defaults to "what the four original designs did", so a
  // design that says nothing here keeps its old appearance bit for bit.

  /// Task title size in logical pixels, before the user's font scale.
  ///
  /// The row used to hard-code 13.5, which meant a dense language had no way to
  /// ask for smaller type. 8.5–9 is legible on a phone and roughly doubles how
  /// many rows a glance can take in.
  final double titleSize;

  /// The secondary line (note / badges / amounts).
  final double metaSize;

  /// Checkbox / completion mark box.
  final double checkSize;

  /// Whether rows carry the per-row category assignment strip.
  ///
  /// It is the single most expensive element in a row — a whole horizontal
  /// scroll of chips costs ~32px of height on every row. Dense languages drop it
  /// and rely on the category badge to say where a task lives; the editor still
  /// allows reassignment, so nothing becomes impossible, it just stops being one
  /// tap away. That is the trade a dense view is asking for.
  final bool showAssignChips;

  /// Draw a hairline between rows instead of a gap.
  ///
  /// The cheapest way to add density: a 1px rule costs 1px, a gap costs 4–16.
  final bool rowDivider;

  /// Show the secondary metadata line (category, amount, due date) at all.
  ///
  /// Never used to hide information that exists nowhere else — the task detail
  /// screen always has it. This only decides whether it earns a line here.
  final bool showMeta;

  /// Show the note under the title on the list row.
  ///
  /// For the densest languages the note is truncated away; it is still one tap
  /// deep. Two lines of note per row is exactly what turns a "dense" view into a
  /// normal one.
  final bool showNote;

  /// Right-align the money amount, ledger style, and give it a fixed gutter.
  final bool amountGutter;

  /// Draw the category as a short colour swatch (2 characters) rather than a
  /// full chip with emoji. Sits between "full chip" and "nothing".
  final bool compactCategory;

  /// Alternating row tint, so the eye can track a line across a wide table.
  final bool zebra;

  /// Uppercase the small metadata labels (a log/terminal feel).
  final bool upperMeta;

  /// Put the category swatch and the amount on the *title line*, to the right of
  /// the title, instead of giving them a second line.
  ///
  /// This is the honest way to be dense: not "show less", but "show the same in
  /// less space". A second line costs ~15px on every row; an inline swatch costs
  /// nothing because the title line is already there. The amount keeps its
  /// tabular alignment so a money column still reads straight down.
  ///
  /// Requires [showMeta] to be false — otherwise the information renders twice.
  final bool inlineMeta;

  /// ── Table geometry ─────────────────────────────────────────────────────
  ///
  /// A *dense* list and a *table* are not the same thing, and confusing the two
  /// is how "dense" themes end up as just "smaller lists".
  ///
  /// A compressed list still answers one question per row: *what*. A table
  /// answers three at a glance: *what, where, how much* — because the columns
  /// line up and the eye can run down one of them. That vertical scan is the
  /// actual information gain, and it cannot be produced by shrinking fonts.
  ///
  /// These fields describe column geometry. All of them default to "not a
  /// table", so every design that says nothing here keeps its old rendering.
  /// A design either uses the table columns or the inline row, never both.

  /// Draw the column header strip above the list.
  ///
  /// Without a header, aligned columns are just ragged text. The header is what
  /// turns three text fragments into three *named* columns.
  final bool showTableHeader;

  /// Header strip height. Small on purpose: it is a label, not a title bar.
  final double tableHeaderHeight;

  /// Width of the category column. Zero means "no category column".
  final double colCategory;

  /// Width of the amount column, right-aligned so digits stack.
  final double colAmount;

  /// Width of the trailing state column (a completion mark, pin, recurrence).
  final double colState;

  /// Draw the per-row delete button.
  ///
  /// Material's IconButton enforces a 48px (dense: 40px) minimum tap target, so
  /// this one widget sets the row's height no matter how small the type gets.
  /// That is the right default — a delete you can actually hit — but it makes a
  /// true dense row impossible.
  ///
  /// Turning it off costs nothing functionally: deletion is already in the
  /// long-press menu (which is where a destructive action belongs anyway). The
  /// dense designs use this to trade a redundant button for rows half the height.
  final bool showDeleteButton;

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
    this.titleSize = 13.5,
    this.metaSize = 10,
    this.checkSize = 26,
    this.showAssignChips = true,
    this.rowDivider = false,
    this.showMeta = true,
    this.showNote = true,
    this.amountGutter = false,
    this.compactCategory = false,
    this.zebra = false,
    this.upperMeta = false,
    this.showDeleteButton = true,
    this.inlineMeta = false,
    this.showTableHeader = false,
    this.tableHeaderHeight = 18,
    this.colCategory = 0,
    this.colAmount = 0,
    this.colState = 0,
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

  /// True when this design lays rows out as columns rather than as a line of
  /// text with things appended to it.
  bool get isTable => colCategory > 0 || colAmount > 0;

  /// A rough score for "how many rows fit on one screen", higher is denser.
  ///
  /// Used by the design picker to label a language honestly, and by the tests to
  /// assert that a design claiming to be dense actually is. It is an estimate,
  /// not a measurement — but an unchecked claim is how "dense" themes end up
  /// looking identical to the normal one.
  double get densityScore {
    final perRow =
        pad.top +
        pad.bottom +
        rowGap +
        titleSize * 1.25 +
        (showNote ? metaSize * 1.6 : 0) +
        (showMeta ? metaSize * 1.7 : 0) +
        (showAssignChips ? 32 : 0) +
        (rowDivider ? 1 : 0) +
        (showDeleteButton ? 12 : 0);
    // 표 머리글은 한 번만 그리므로 '행당 비용'에 넣으면 안 된다. 넣으면
    // 표 테마가 실제보다 훨씬 덜 조밀한 것처럼 점수가 깎인다.
    // inlineMeta 도 별도 줄을 쓰지 않으므로 점수를 깎지 않는다.
    return 100 / perRow;
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

  static const List<String> ids = [
    'paper',
    'studioe',
    'desk',
    'gazette',
    // ---- 고밀도 (dense) 계열 ----
    'ledger',
    'terminal',
    'compact',
    'matrix',
    'chrono',
  ];

  /// The dense designs, in the order the picker shows them under their heading.
  static const List<String> denseIds = [
    'ledger',
    'terminal',
    'compact',
    'matrix',
    'chrono',
  ];

  static bool isDense(String id) => denseIds.contains(id);

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

    // =====================================================================
    // 고밀도 (DENSE) 계열 — "한 화면에 최대한 많은 정보"
    // =====================================================================
    //
    // 다섯 개는 서로 다른 *정보 전략*이지 색만 다른 변형이 아니다. 각 테마가
    // 어떤 정보를 남기고 무엇을 포기했는지가 이름에 담겨 있다.
    //
    // 공통 원칙: 사용자가 어디를 눌러도 정보를 잃지 않는다. 목록에서 뺀 것은
    // 상세 화면에 그대로 있다. 밀도는 "정보 삭제"가 아니라 "한 화면에 담는
    // 양"의 문제다.

    // 5) LEDGER — 회계 장부. 숫자가 1등 시민이다.
    'ledger': AppDesign(
      id: 'ledger',
      emoji: '📊',
      family: 'dense',
      deco: SkinDeco.plain,
      typeScale: 0.90,
      titleWeight: FontWeight.w600,
      labelWeight: FontWeight.w800,
      surface: SurfaceSpec(
        radius: 3,
        radiusSmall: 2,
        radiusLarge: 8,
        borderWidth: 0, // 장부에는 테두리가 없다. 선 하나로 구분한다.
        ruleWidth: 1,
        elevation: 0,
        pad: EdgeInsets.fromLTRB(8, 3, 8, 3),
        rowGap: 0,
        headerHeight: 56,
        headerPadX: 10,
        headerBand: true,
        headerRule: true,
        roundCheck: false,
        pillChips: false,
        solidChips: false,
        tracking: 0.2,
        // --- 밀도 ---
        titleSize: 11.5,
        metaSize: 9,
        checkSize: 20,
        rowDivider: true, // 헤어라인 한 줄이 여백을 대신한다
        showAssignChips: false, // 칩 띠 제거 = 행당 32px 회수
        showNote: false,
        showMeta: true, // 분류·금액은 반드시 남긴다
        amountGutter: true, // 금액 우측 정렬 + 고정 폭
        compactCategory: true, // 이모지+이름 대신 색 견본
        zebra: true, // 줄무늬로 가로 추적
        upperMeta: false,
        showDeleteButton: false,
        showTableHeader: true,
        tableHeaderHeight: 20,
        colCategory: 46,
        colAmount: 84,
        colState: 14,
        inlineMeta: false,
      ),
    ),

    // 6) TERMINAL — 로그 뷰어. 밀도가 가장 높고, 색이 유일한 장식이다.
    'terminal': AppDesign(
      id: 'terminal',
      emoji: '⬛',
      family: 'dense',
      deco: SkinDeco.grid,
      typeScale: 0.88,
      titleWeight: FontWeight.w500,
      labelWeight: FontWeight.w700,
      surface: SurfaceSpec(
        radius: 0, // 각도 없는 순수 격자
        radiusSmall: 0,
        radiusLarge: 0,
        borderWidth: 0,
        ruleWidth: 1,
        elevation: 0,
        pad: EdgeInsets.fromLTRB(6, 1, 6, 1),
        rowGap: 0,
        headerHeight: 46,
        headerPadX: 8,
        headerBand: true,
        headerAccentTitle: true,
        headerRule: true,
        roundCheck: false,
        pillChips: false,
        solidChips: true,
        headerCase: 'upper',
        tracking: 0.9,
        // --- 밀도 (최고) ---
        titleSize: 10.5,
        metaSize: 8,
        checkSize: 16,
        rowDivider: true,
        showAssignChips: false,
        showNote: false,
        showMeta: true,
        amountGutter: true,
        compactCategory: false,
        zebra: false,
        upperMeta: true, // 소문자 대신 대문자 = 로그 느낌 + 라인 높이 절약
        showDeleteButton: false,
        showTableHeader: true,
        tableHeaderHeight: 16,
        colCategory: 40,
        colAmount: 72,
        colState: 12,
        inlineMeta: false,
      ),
    ),

    // 7) COMPACT — 순수 밀도. 장식은 전부 걷어내고 이름과 체크만 남긴다.
    'compact': AppDesign(
      id: 'compact',
      emoji: '▤',
      family: 'dense',
      deco: SkinDeco.plain,
      typeScale: 0.95,
      titleWeight: FontWeight.w500,
      surface: SurfaceSpec(
        radius: 2,
        radiusSmall: 2,
        radiusLarge: 6,
        borderWidth: 0,
        ruleWidth: 1,
        elevation: 0,
        pad: EdgeInsets.fromLTRB(6, 2, 4, 2),
        rowGap: 0,
        headerHeight: 48,
        headerPadX: 8,
        headerRule: true,
        roundCheck: true,
        pillChips: false,
        solidChips: false,
        tracking: 0,
        // --- 밀도 ---
        // 이 테마의 결단: 두 번째 줄을 없애고 그 정보를 **열**로 세운다.
        // 처음에는 메타를 그냥 지웠는데, 그러면 '정보 많은 테마'가 아니라
        // '빈 미니멀 테마'가 된다. 정보는 빼는 게 아니라 자리를 옮기는 것.
        titleSize: 11,
        metaSize: 8.5,
        checkSize: 16,
        rowDivider: true,
        showAssignChips: false,
        showNote: false,
        showMeta: false, // 두 번째 줄 없음 — 대신 열이 그 자리를 맡는다
        amountGutter: true,
        compactCategory: true,
        zebra: false,
        upperMeta: false,
        showDeleteButton: false,
        showTableHeader: true,
        tableHeaderHeight: 17,
        colCategory: 38,
        colAmount: 70,
        colState: 0,
        inlineMeta: false,
      ),
    ),

    // 8) MATRIX — 격자. 구분선이 사방을 감아 표(table)처럼 읽힌다.
    'matrix': AppDesign(
      id: 'matrix',
      emoji: '▦',
      family: 'dense',
      deco: SkinDeco.grid,
      typeScale: 0.91,
      titleWeight: FontWeight.w600,
      labelWeight: FontWeight.w700,
      surface: SurfaceSpec(
        radius: 1,
        radiusSmall: 1,
        radiusLarge: 4,
        borderWidth: 1, // 셀 경계 = 표의 격자
        ruleWidth: 1,
        elevation: 0,
        pad: EdgeInsets.fromLTRB(6, 2, 6, 2),
        rowGap: 0,
        headerHeight: 52,
        headerPadX: 8,
        headerBand: true,
        headerRule: true,
        roundCheck: false,
        pillChips: false,
        solidChips: false,
        headerCase: 'upper',
        tracking: 0.5,
        // --- 밀도 ---
        titleSize: 11,
        metaSize: 8.5,
        checkSize: 17,
        rowDivider: true,
        showAssignChips: false,
        showNote: false,
        showMeta: true,
        amountGutter: true,
        compactCategory: true,
        zebra: true,
        upperMeta: true,
        showDeleteButton: false,
        showTableHeader: true,
        tableHeaderHeight: 19,
        colCategory: 44,
        colAmount: 80,
        colState: 15,
        inlineMeta: false,
      ),
    ),

    // 9) CHRONO — 일정/날짜 우선. 시간 열이 왼쪽에 고정된 느낌으로 읽힌다.
    'chrono': AppDesign(
      id: 'chrono',
      emoji: '⏱',
      family: 'dense',
      deco: SkinDeco.ruled,
      typeScale: 0.93,
      titleWeight: FontWeight.w600,
      labelWeight: FontWeight.w700,
      surface: SurfaceSpec(
        radius: 2,
        radiusSmall: 2,
        radiusLarge: 8,
        borderWidth: 0,
        ruleWidth: 1,
        elevation: 0,
        pad: EdgeInsets.fromLTRB(7, 2, 7, 2),
        rowGap: 0,
        headerHeight: 54,
        headerPadX: 9,
        headerRule: true,
        roundCheck: true,
        pillChips: false,
        solidChips: false,
        tracking: 0.3,
        // --- 밀도 ---
        // 레저(11.5)보다 살짝 크다. 일정은 날짜·요일 글자를 읽어야 하고,
        // 장부는 숫자 정렬로 읽는다. 같은 밀도 숫자를 쓸 이유가 없다.
        titleSize: 12,
        metaSize: 9.5,
        checkSize: 19,
        rowDivider: true,
        showAssignChips: false,
        showNote: false,
        showMeta: true, // 날짜/요일이 이 테마의 존재 이유
        amountGutter: false,
        compactCategory: true,
        zebra: true,
        upperMeta: false,
        showDeleteButton: false,
        showTableHeader: true,
        tableHeaderHeight: 21,
        colCategory: 42,
        colAmount: 76,
        colState: 13,
        inlineMeta: false,
      ),
    ),
  };

  static AppDesign of(String id) => _byId[id] ?? _byId[defaultId]!;

  static bool contains(String id) => _byId.containsKey(id);

  static String emojiFor(String id) => of(id).emoji;
}
