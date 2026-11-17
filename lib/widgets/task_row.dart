import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../theme/app_theme.dart';
import 'notebook_ui.dart';

/// A single task row in the main list.
/// Left: checkbox + title (+ note). Right: quick-assign category chips.
///
/// ## Density is a design decision, not a smaller font
/// Every measurement below is read from [SurfaceSpec] rather than hard-coded.
/// The row used to bake in `13.5` for the title, a `26` checkbox and a mandatory
/// chip strip — which meant a "dense" theme could only ever differ by colour.
/// Now a design can genuinely choose what a row costs:
///
///   * `titleSize` / `metaSize` — how big the two lines of text are
///   * `rowDivider` — a 1px rule instead of a 4–16px gap
///   * `showAssignChips` — the per-row chip strip, ~32px of the row's height
///   * `showMeta`, `showNote` — whether those lines earn their space at all
///
/// Nothing removed here is lost: the detail screen always has every field. This
/// widget only decides what earns a place in the list.
class TaskRow extends StatelessWidget {
  final Task task;
  final Category category;
  final List<Category> assignTargets;
  final VoidCallback onToggle;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final void Function(Category) onAssign;

  /// Alternating tint index, supplied by the list so zebra striping can work
  /// without the row having to know its own position.
  final int stripeIndex;

  const TaskRow({
    super.key,
    required this.task,
    required this.category,
    required this.assignTargets,
    required this.onToggle,
    required this.onTap,
    required this.onDelete,
    required this.onAssign,
    this.stripeIndex = 0,
  });

  @override
  Widget build(BuildContext context) {
    final catColor = Color(category.colorValue);

    // A dense language replaces the card with a rule-separated line. In that
    // mode the row must not paint a card, a border or a shadow: at 1px gaps any
    // of those would visually merge into a grey band and destroy the whole
    // point.
    final lined = sx.rowDivider;
    final zebraOn = sx.zebra && stripeIndex.isOdd;

    // Density hero: one hairline instead of a gap.
    final rowWidget = Container(
      margin: EdgeInsets.symmetric(
        horizontal: lined ? 0 : 12,
        vertical: lined ? 0 : sx.rowGap / 2,
      ),
      decoration: BoxDecoration(
        color: lined
            ? (zebraOn ? p.ink.withValues(alpha: 0.045) : Colors.transparent)
            : (zebraOn ? p.soft : p.card),
        borderRadius: BorderRadius.circular(lined ? 0 : sx.radius),
        border: (lined || sx.borderWidth == 0)
            ? null
            : Border.all(color: p.line, width: sx.borderWidth),
        boxShadow: lined ? const [] : sx.shadows(),
      ),
      foregroundDecoration: (sx.edgeBar && !lined)
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(sx.radius),
              border: Border(
                left: BorderSide(
                  color: task.completed ? p.line : catColor,
                  width: 4,
                ),
              ),
            )
          : null,
      child: Padding(
        padding: sx.pad,
        // mainAxisSize.min 은 장식이 아니다. Column 의 기본값(max)은 부모가
        // 주는 최대 높이를 그대로 차지한다. ListView 안에서는 항목마다 높이가
        // 내용에 맞춰 정해져 문제가 없지만, 이 행을 다른 곳에 넣는 순간
        // (그리고 테스트에서) 화면 전체 높이를 먹어 밀도를 측정할 수 없게 된다.
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (sx.isTable)
              _tableRow(catColor)
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: sx.checkSize,
                    height: sx.checkSize,
                    child: handwritingOn
                        ? GestureDetector(
                            onTap: onToggle,
                            child: Center(
                              child: HandCheck(
                                size: sx.checkSize * 0.85,
                                color: catColor,
                                checked: task.completed,
                              ),
                            ),
                          )
                        : FittedBox(
                            fit: BoxFit.contain,
                            child: Checkbox(
                              value: task.completed,
                              onChanged: (_) => onToggle(),
                              shape: sx.roundCheck
                                  ? const CircleBorder()
                                  : RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(
                                        sx.radiusSmall,
                                      ),
                                    ),
                              side: BorderSide(color: catColor, width: 1.4),
                              activeColor: catColor,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              visualDensity: sx.checkSize < 22
                                  ? VisualDensity.compact
                                  : VisualDensity.standard,
                            ),
                          ),
                  ),
                  SizedBox(width: sx.titleSize < 12 ? 5 : 8),
                  Expanded(
                    child: GestureDetector(
                      onTap: onTap,
                      behavior: HitTestBehavior.opaque,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              if (task.pinned)
                                Padding(
                                  padding: const EdgeInsets.only(right: 3),
                                  child: handwritingOn
                                      ? HandAsterisk(
                                          size: sx.metaSize + 2,
                                          color: p.teal,
                                          seed: task.id.hashCode,
                                        )
                                      : Icon(
                                          Icons.push_pin,
                                          size: sx.metaSize + 2,
                                          color: p.indigo,
                                        ),
                                ),
                              if (task.recurrence != 'none')
                                Padding(
                                  padding: const EdgeInsets.only(right: 3),
                                  child: Icon(
                                    Icons.autorenew,
                                    size: sx.metaSize + 2,
                                    color: p.teal,
                                  ),
                                ),
                              Expanded(
                                child:
                                    (handwritingOn &&
                                        task.pinned &&
                                        !task.completed)
                                    ? HandHighlight(
                                        color: const Color(0xFFFFE066),
                                        child: Text(
                                          task.title,
                                          maxLines: lined ? 1 : 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: _titleStyle(task),
                                        ),
                                      )
                                    : Text(
                                        task.title,
                                        maxLines: lined ? 1 : 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: _titleStyle(task),
                                      ),
                              ),
                            ],
                          ),
                          if (sx.showNote && task.note.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                task.note,
                                maxLines: lined ? 1 : 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: sx.metaSize + 1,
                                  color: p.inkSoft,
                                  height: 1.2,
                                ),
                              ),
                            ),
                          // inlineMeta 와 showMeta 는 배타적으로 쓴다. 둘 다 켜면
                          // 같은 정보가 두 번 그려지므로 여기서 막는다.
                          if (sx.showMeta && !sx.inlineMeta)
                            Padding(
                              padding: EdgeInsets.only(top: lined ? 1 : 3),
                              child: _metaLine(catColor),
                            ),
                        ],
                      ),
                    ),
                  ),
                  // ── 인라인 메타 ──────────────────────────────────────────────
                  // 고밀도의 정직한 방법: 정보를 **빼는** 게 아니라 **접는** 것.
                  // 두 번째 줄은 행마다 ~15px 를 먹는다. 제목 줄은 어차피
                  // 존재하므로, 카테고리 견본과 금액을 그 줄 오른쪽으로 올리면
                  // 같은 정보가 0px 에 표시된다.
                  //
                  // 제목 Expanded 바깥(형제)에 두는 이유: 제목 길이에 따라
                  // 금액이 밀리면 돈 열이 지그재그가 된다. 형제로 두면
                  // 오른쪽 끝에 고정되고, 제목만 말줄임된다.
                  if (sx.inlineMeta && !sx.isTable)
                    Padding(
                      padding: EdgeInsets.only(left: sx.titleSize < 12 ? 6 : 8),
                      child: _inlineMeta(catColor),
                    ),
                  // Material's IconButton enforces a 48px minimum tap target
                  // (40px at compact density), so this single widget — not the
                  // type size — decides the row's height. Dense designs drop it
                  // and rely on the long-press menu, which already has delete.
                  if (sx.showDeleteButton)
                    SizedBox(
                      width: lined ? 26 : 38,
                      child: IconButton(
                        onPressed: onDelete,
                        icon: Icon(
                          Icons.delete_outline,
                          size: lined ? 13 : 18,
                          color: lined ? p.inkSoft : p.danger,
                        ),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        visualDensity: VisualDensity.compact,
                        tooltip: context.tr('delete'),
                      ),
                    ),
                ],
              ),

            // The per-row category strip. Its absence is worth ~32px of every
            // row — the largest single density win available.
            if (sx.showAssignChips) ...[
              SizedBox(height: sx.titleSize < 13 ? 4 : 6),
              SizedBox(
                height: 26,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: assignTargets.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 5),
                  itemBuilder: (_, i) => _assignChip(assignTargets[i]),
                ),
              ),
            ],

            // Table rows never draw the tall pill strip; the extra memberships
            // ride inside the title line instead. See [_miniChips].
          ],
        ),
      ),
    );

    if (!lined) return rowWidget;
    // Hairline between rows: 1px of ink instead of 0–16px of nothing.
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.line, width: 0.7)),
      ),
      child: rowWidget,
    );
  }

  /// The categories this task is filed under **besides** the primary one.
  ///
  /// The primary category already owns a whole column in a table row, so
  /// repeating it would be noise. What is missing from the picture — and what
  /// the user asked for — is the *second* membership: this task is also filed
  /// under 금전출납.
  List<Category> get _extraAssigned => [
        for (final c in assignTargets)
          if (c.id != category.id && task.isInCategory(c.id)) c,
      ];

  /// Additional category memberships, folded onto the title line.
  ///
  /// ## Why this is not a separate line
  /// The first attempt gave the extra categories their own row under the table
  /// line. It worked, and it cost +14.7px on a 26.7px row — a 55% height
  /// increase in the *dense* themes. That is not "showing multi-select in dense
  /// mode", it is quietly deleting dense mode to make room. Two user requests
  /// cannot be satisfied by cancelling one of them.
  ///
  /// So the tokens ride on the title line instead: zero height cost, and when
  /// space runs out they clip with an ellipsis rather than wrap. The title wins
  /// the fight for width — that is the correct priority in a table whose whole
  /// purpose is scanning many rows.
  ///
  /// A coloured dot leads each token: two categories that read alike
  /// (은행업무 / 금전출납) are told apart by colour before the letters are read.
  Widget _miniChips() {
    final items = _extraAssigned;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0)
            Text(
              '·',
              style: TextStyle(
                fontSize: sx.metaSize - 1,
                color: p.inkSoft,
                height: 1.0,
              ),
            ),
          if (i > 0) const SizedBox(width: 4),
          Container(
            width: (sx.metaSize * 0.40).clamp(3.0, 4.5),
            height: (sx.metaSize * 0.40).clamp(3.0, 4.5),
            margin: const EdgeInsets.only(right: 3),
            decoration: BoxDecoration(
              color: Color(items[i].colorValue),
              shape: BoxShape.circle,
            ),
          ),
          Flexible(
            child: Text(
              catLabel(items[i]),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: sx.metaSize - 0.5,
                height: 1.0,
                color: p.inkSoft,
                letterSpacing: 0.1,
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// `compactCategory` is the middle gear between a full `📁 이름` chip and no
  /// category information: a small colour swatch plus the first two characters,
  /// which still tells the categories apart at a glance.
  ///
  /// A row laid out as **columns**, which is the whole point of a dense table.
  ///
  /// The difference from the ordinary row is not size, it is *structure*. An
  /// ordinary row reads left to right once: checkbox, title, a couple of things
  /// appended to the title. A table gives each kind of fact its own column, so
  /// the eye can travel **down** one column and compare like with like — every
  /// category, every amount, every due date. That vertical scan is the
  /// information a table adds, and no amount of shrink-to-fit reproduces it.
  ///
  /// Column widths come from [SurfaceSpec] so a design can choose its own
  /// emphasis (ledger favours money, matrix favours category) instead of every
  /// table being the same table recoloured.
  Widget _tableRow(Color catColor) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // 1) 완료 표시. 폭을 고정해야 아래 행들과 세로로 맞는다.
        SizedBox(
          width: sx.checkSize,
          height: sx.checkSize,
          child: handwritingOn
              ? GestureDetector(
                  onTap: onToggle,
                  child: Center(
                    child: HandCheck(
                      size: sx.checkSize * 0.85,
                      color: catColor,
                      checked: task.completed,
                    ),
                  ),
                )
              : FittedBox(
                  fit: BoxFit.contain,
                  child: Checkbox(
                    value: task.completed,
                    onChanged: (_) => onToggle(),
                    shape: sx.roundCheck
                        ? const CircleBorder()
                        : RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(sx.radiusSmall),
                          ),
                    side: BorderSide(color: catColor, width: 1.4),
                    activeColor: catColor,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: sx.checkSize < 22
                        ? VisualDensity.compact
                        : VisualDensity.standard,
                  ),
                ),
        ),
        SizedBox(width: sx.titleSize < 12 ? 5 : 7),

        // 2) 분류 열. 고정 폭 + 한 줄 고정. 이 폭이 없으면 '열'이 아니라
        //    그냥 '제목 앞에 붙은 글자'가 되어 표로 읽히지 않는다.
        if (sx.colCategory > 0)
          SizedBox(
            width: sx.colCategory,
            child: Align(
              alignment: Alignment.centerLeft,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: _categoryMark(catColor),
              ),
            ),
          ),

        // 3) 제목 열 — 남는 폭을 전부 쓰고, 한 줄에서 말줄임한다.
        //    표에서 두 줄짜리 셀은 행 높이를 무너뜨리므로 허용하지 않는다.
        Expanded(
          child: GestureDetector(
            onTap: onTap,
            behavior: HitTestBehavior.opaque,
            child: Row(
              children: [
                if (task.pinned)
                  Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: Icon(
                      Icons.push_pin,
                      size: sx.metaSize,
                      color: p.indigo,
                    ),
                  ),
                if (task.recurrence != 'none')
                  Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: Icon(
                      Icons.autorenew,
                      size: sx.metaSize,
                      color: p.teal,
                    ),
                  ),
                Expanded(
                  child: Text(
                    task.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _titleStyle(task),
                  ),
                ),
                // 노트가 남아 있고 이 테마가 노트를 허용하면, 제목 **뒤에
                // 흐리게** 붙인다. 줄을 하나 더 쓰지 않으면서 '무엇에 대한
                // 일인지'를 잃지 않는 방법.
                if (sx.showNote && task.note.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      task.note,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: sx.metaSize + 1,
                        color: p.inkSoft,
                        height: 1.2,
                      ),
                    ),
                  ),
                ],
                // 두 번째 이후 분류. 제목 줄에 얹으므로 행 높이가 늘지 않는다.
                // 표에서 '분류를 두 개에 넣는 기능'이 사라졌던 문제를 이렇게
                // 되돌린다 — 줄을 늘리지 않고 정보만 더한다.
                if (sx.miniChips && _extraAssigned.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Flexible(flex: 2, child: _miniChips()),
                ],
              ],
            ),
          ),
        ),

        // 4) 금액 열 — 우측 정렬 + 등폭 숫자. 이 조합이 '돈 열'을 만든다.
        if (sx.colAmount > 0) ...[
          const SizedBox(width: 4),
          SizedBox(
            width: sx.colAmount,
            child: Align(
              alignment: Alignment.centerRight,
              child: task.amount == null
                  ? const SizedBox.shrink()
                  : FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: _amountText(),
                    ),
            ),
          ),
        ],

        // 5) 상태 열 — 완료 표시는 이미 체크박스에 있으므로, 여기서는
        //    '지연'처럼 눈에 안 보이는 사실을 짧게 알린다.
        if (sx.colState > 0) ...[
          const SizedBox(width: 2),
          SizedBox(width: sx.colState, child: _stateMark(catColor)),
        ],
      ],
    );
  }

  /// The trailing state column: overdue, urgent, or nothing.
  ///
  /// A column that is usually empty looks like a bug, so it is sized and given
  /// a faint rule in the header to look deliberate. What it must never do is
  /// change the row's height.
  Widget _stateMark(Color catColor) {
    final due = task.dueDate;
    if (due == null) return const SizedBox.shrink();
    final overdue = !task.completed && due.isBefore(DateTime.now());
    if (!overdue) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerRight,
      child: Icon(Icons.error_outline, size: sx.metaSize + 1, color: p.danger),
    );
  }

  /// The column header strip, drawn once above the whole list.
  ///
  /// It lives here rather than in the list because it has to share the *exact*
  /// same column widths as the rows — any duplication of those numbers would
  /// drift the moment a design tweaks one of them.
  static Widget tableHeader(BuildContext context) {
    final s = sx;
    return Container(
      height: s.tableHeaderHeight,
      padding: EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: p.ink.withValues(alpha: 0.05),
        border: Border(bottom: BorderSide(color: p.line, width: 0.8)),
      ),
      child: Row(
        children: [
          SizedBox(width: s.checkSize),
          SizedBox(width: s.titleSize < 12 ? 5 : 7),
          if (s.colCategory > 0)
            SizedBox(
              width: s.colCategory,
              child: Text(
                context.tr('col_category'),
                style: _headerStyle(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          Expanded(
            child: Text(
              context.tr('col_task'),
              style: _headerStyle(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          if (s.colAmount > 0)
            SizedBox(
              width: s.colAmount,
              child: Text(
                context.tr('col_amount'),
                style: _headerStyle(),
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (s.colState > 0) ...[
            const SizedBox(width: 2),
            SizedBox(width: s.colState),
          ],
        ],
      ),
    );
  }

  static TextStyle _headerStyle() => TextStyle(
    fontSize: sx.metaSize - 0.5,
    fontWeight: FontWeight.w800,
    color: p.inkSoft,
    letterSpacing: sx.upperMeta ? 0.8 : 0.3,
    height: 1.0,
  );

  /// The category mark, factored out because both the second line
  /// ([_metaLine]) and the folded title line ([_inlineMeta]) need exactly the
  /// same object. Two copies would drift.
  ///
  /// `compactCategory` is the middle gear between a full `📁 이름` chip and no
  /// category information at all: a colour swatch plus the first two
  /// characters, which still tells the categories apart at a glance.
  Widget _categoryMark(Color catColor) {
    final label = catLabel(category);
    final upper = sx.upperMeta;
    final short = label.characters.take(2).toString();
    if (sx.compactCategory) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: catColor.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Text(
          upper ? short.toUpperCase() : short,
          style: TextStyle(
            fontSize: sx.metaSize - 0.5,
            color: ct(catColor),
            fontWeight: FontWeight.w700,
            height: 1.1,
          ),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0.5),
      decoration: BoxDecoration(
        color: catColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        '${category.emoji} ${upper ? label.toUpperCase() : label}',
        style: TextStyle(
          fontSize: sx.metaSize - 0.5,
          color: ct(catColor),
          fontWeight: FontWeight.w600,
          height: 1.1,
        ),
      ),
    );
  }

  /// The money, always with tabular figures so a column of amounts reads
  /// straight down instead of wobbling.
  Widget _amountText() => Text(
    '₩${_fmt(task.amount!)}',
    // 돈은 절대 두 줄이 되면 안 된다. 줄바꿈은 행 높이를 무너뜨리고 동시에
    // '열'이라는 착각을 깬다. 자리가 모자라면 글자를 줄이지, 줄을 늘리지 않는다.
    maxLines: 1,
    softWrap: false,
    style: TextStyle(
      fontSize: sx.metaSize,
      color: p.inkSoft,
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
      height: 1.1,
    ),
  );

  /// The secondary line: category, amount, and (when the design asks for it)
  /// nothing at all.
  Widget _metaLine(Color catColor) {
    return Row(
      children: [
        if (handwritingOn && task.categoryId == 'memo')
          Padding(
            padding: const EdgeInsets.only(right: 5),
            child: HandAsterisk(
              size: sx.metaSize + 1,
              color: p.teal,
              seed: task.title.hashCode,
            ),
          ),
        _categoryMark(catColor),
        if (task.amount != null) ...[
          const SizedBox(width: 6),
          if (sx.amountGutter) const Spacer(),
          _amountText(),
        ],
      ],
    );
  }

  /// The folded meta: everything [_metaLine] shows, on the title line.
  ///
  /// Deliberately a `mainAxisSize.min` Row of *fixed-size* pieces. Nothing here
  /// may be taller than the title's line box, or the fold would cost more height
  /// than the line it replaced and the whole idea collapses.
  Widget _inlineMeta(Color catColor) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The memo handwriting mark earns its place even folded: it is the only
        // hint that the row is a memo rather than a dated task.
        if (handwritingOn && task.categoryId == 'memo')
          Padding(
            padding: const EdgeInsets.only(right: 3),
            child: HandAsterisk(
              size: sx.metaSize,
              color: p.teal,
              seed: task.title.hashCode,
            ),
          ),
        _categoryMark(catColor),
        if (task.amount != null) ...[const SizedBox(width: 5), _amountText()],
      ],
    );
  }

  Widget _assignChip(Category c) {
    final selected = task.isInCategory(c.id);
    final col = Color(c.colorValue);
    return GestureDetector(
      onTap: () => onAssign(c),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: sx.solidChips && selected
              ? col.withValues(alpha: 0.85)
              : selected
              ? col.withValues(alpha: 0.16)
              : p.card,
          borderRadius: BorderRadius.circular(
            sx.pillChips ? 20 : sx.radiusSmall,
          ),
          border: Border.all(
            color: selected ? col : p.line,
            width: selected ? 1.2 : 0.8,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected)
              Padding(
                padding: const EdgeInsets.only(right: 3),
                child: Icon(Icons.check, size: 10, color: ct(col)),
              ),
            Text(
              '${c.emoji} ${catLabel(c)}',
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? ct(col) : p.inkSoft,
              ),
            ),
          ],
        ),
      ),
    );
  }

  TextStyle _titleStyle(Task task) => TextStyle(
    fontSize: handwritingOn ? sx.titleSize + 3 : sx.titleSize,
    height: 1.22,
    fontFamily: handFamily(),
    fontWeight: design.titleWeight,
    color: p.ink,
    decoration: task.completed ? TextDecoration.lineThrough : null,
    decorationColor: p.inkSoft,
  );

  String _fmt(double v) {
    final s = v.toStringAsFixed(0);
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}
