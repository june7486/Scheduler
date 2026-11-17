import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../services/store.dart';
import '../theme/app_theme.dart';

/// Theme switching, from the toolbar, while looking at the actual list.
///
/// The skin settings screen also changes the theme, but it covers the app with
/// its own surface: you pick a design, close the panel, judge it, reopen the
/// panel, pick another. Choosing a *look* is inherently a comparison, and that
/// loop destroys the comparison.
///
/// This menu sits over the live list instead. The list stays visible behind it,
/// and every tap applies immediately (the store notifies, `main.dart` rebuilds
/// the whole app), so the preview is not a preview — it is the thing itself.
class DesignQuickPicker extends StatelessWidget {
  const DesignQuickPicker({super.key});

  static const double _panelWidth = 262;

  /// Height of one design row inside the menu.
  ///
  /// `PopupMenuItem` defaults to 48px which wastes space for a list built of
  /// 26px miniatures; 42 is the smallest value that still clears the 40px
  /// minimum touch target after the menu's own insets.
  static const double _rowHeight = 42;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<Store>();
    // The toolbar button shows the *current* design's emoji, so the button
    // itself answers "which theme am I looking at?" without opening anything.
    final current = AppDesigns.of(store.designKey);

    return PopupMenuButton<String>(
      tooltip: context.tr('design_quick_pick'),
      position: PopupMenuPosition.under,
      offset: const Offset(0, 6),
      constraints: const BoxConstraints(
        minWidth: _panelWidth,
        maxWidth: _panelWidth,
        // A phone screen cannot show nine 42px rows plus a header; the menu
        // scrolls instead of overflowing.
        maxHeight: 420,
      ),
      color: p.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: p.line),
      ),
      // Taps are handled by the menu itself via [onSelected], NOT by the row.
      //
      // This matters: an earlier version put the whole panel inside a single
      // `PopupMenuItem(enabled: false)` and hung an InkWell on the rows. A
      // disabled PopupMenuItem swallows pointer events for its entire subtree,
      // so the panel looked perfect and did absolutely nothing when tapped.
      // Giving each design a real menu item is the only shape where the tap
      // reaches the code.
      onSelected: (id) => store.setDesignKey(id),
      itemBuilder: (context) => [
        // Header: a label, so it is legitimately disabled and untappable.
        PopupMenuItem<String>(
          enabled: false,
          padding: EdgeInsets.zero,
          height: 40,
          child: _PickerHeader(),
        ),
        for (final id in AppDesigns.ids)
          PopupMenuItem<String>(
            value: id,
            padding: EdgeInsets.zero,
            height: _rowHeight,
            child: _QuickRow(id: id, selected: store.designKey == id),
          ),
      ],
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: p.soft,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: p.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(current.emoji, style: const TextStyle(fontSize: 13)),
            const SizedBox(width: 3),
            Icon(Icons.expand_more_rounded, size: 15, color: p.inkSoft),
          ],
        ),
      ),
    );
  }
}

class _PickerHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            context.tr('design_quick_pick'),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: p.ink,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            context.tr('design_quick_pick_hint'),
            style: TextStyle(fontSize: 9.5, height: 1.3, color: p.inkSoft),
          ),
        ],
      ),
    );
  }
}

class _QuickRow extends StatelessWidget {
  const _QuickRow({required this.id, required this.selected});

  final String id;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final d = AppDesigns.of(id);
    final s = d.surface;
    // A table design is worth labelling as table: it changes what the row *is*,
    // not merely how tight it is.
    final isTable = s.isTable;

    return Container(
      color: selected ? p.indigo.withValues(alpha: 0.09) : Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          // Miniature: real row count for this spec, so the density claim is
          // visible before you commit to it.
          _QuickMiniature(spec: s),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  context.tr('design_$id'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    color: p.ink,
                  ),
                ),
                const SizedBox(height: 1),
                Row(
                  children: [
                    if (isTable)
                      _Tag(text: context.tr('badge_table'), color: p.indigo),
                    if (s.showAssignChips)
                      _Tag(text: context.tr('badge_chips'), color: p.inkSoft),
                    Text(
                      '${s.densityScore.toStringAsFixed(1)}×',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        color: p.inkSoft,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (selected)
            Icon(Icons.check_circle, size: 15, color: p.indigo)
          else
            const SizedBox(width: 15),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 3),
      padding: const EdgeInsets.symmetric(horizontal: 3.5, vertical: 0.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(2.5),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 8, fontWeight: FontWeight.w800, color: color),
      ),
    );
  }
}

/// A 32×26 scale model of a row stack, drawn from the same numbers the real list
/// uses. Terminal shows eight rules, Paper shows three — which is the only
/// honest way to say "this one is denser" in a menu row.
class _QuickMiniature extends StatelessWidget {
  const _QuickMiniature({required this.spec});
  final SurfaceSpec spec;

  @override
  Widget build(BuildContext context) {
    final rowHeight = (100 / spec.densityScore).clamp(4.0, 40.0);
    final unit = rowHeight * 0.42;
    final rows = (26 / (unit + (spec.rowGap * 0.15))).floor().clamp(1, 8);
    final lined = spec.rowDivider || spec.isTable;

    return Container(
      width: 32,
      height: 26,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(spec.radius.clamp(0, 6).toDouble()),
        border: Border.all(color: p.line, width: 0.7),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Table designs get a header bar even in miniature — that strip is the
          // visual signature of a table.
          if (spec.showTableHeader)
            Container(height: 4, color: p.ink.withValues(alpha: 0.10)),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1.5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < rows; i++)
                    Expanded(
                      child: Container(
                        margin: EdgeInsets.only(bottom: lined ? 0 : 1.2),
                        decoration: BoxDecoration(
                          color: spec.zebra && i.isOdd
                              ? p.indigo.withValues(alpha: 0.14)
                              : null,
                          border: lined
                              ? Border(
                                  bottom: BorderSide(
                                    color: p.ink.withValues(alpha: 0.20),
                                    width: 0.5,
                                  ),
                                )
                              : null,
                        ),
                        child: Row(
                          children: [
                            if (spec.isTable)
                              Container(
                                width: 4,
                                height: 1.4,
                                color: i.isEven
                                    ? p.indigo.withValues(alpha: 0.55)
                                    : p.teal.withValues(alpha: 0.55),
                              ),
                            Expanded(
                              child: FractionallySizedBox(
                                alignment: Alignment.centerLeft,
                                widthFactor: 0.35 + ((i * 17) % 50) / 100,
                                child: Container(
                                  height: (unit * 0.20).clamp(0.8, 2.0),
                                  color: p.ink.withValues(alpha: 0.32),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
