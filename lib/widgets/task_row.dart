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
                if (sx.inlineMeta)
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
            // row — the largest single density win available, which is why the
            // dense designs all switch it off.
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

  /// The secondary line: category, amount, and (when the design asks for it)
  /// nothing at all.
  ///
  /// `compactCategory` is the middle gear between a full `📁 이름` chip and no
  /// category information: a small colour swatch plus the first two characters,
  /// which still tells the categories apart at a glance.
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
