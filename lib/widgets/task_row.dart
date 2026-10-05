import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../theme/app_theme.dart';

/// A single task row in the main list.
/// Left: checkbox + title (+ note). Right: quick-assign category chips.
class TaskRow extends StatelessWidget {
  final Task task;
  final Category category;
  final List<Category> assignTargets;
  final VoidCallback onToggle;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final void Function(Category) onAssign;

  const TaskRow({
    super.key,
    required this.task,
    required this.category,
    required this.assignTargets,
    required this.onToggle,
    required this.onTap,
    required this.onDelete,
    required this.onAssign,
  });

  @override
  Widget build(BuildContext context) {
    final catColor = Color(category.colorValue);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.line),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A000000),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 26,
                  height: 26,
                  child: Checkbox(
                    value: task.completed,
                    onChanged: (_) => onToggle(),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                    side: BorderSide(color: catColor, width: 1.4),
                    activeColor: catColor,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                const SizedBox(width: 8),
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
                              const Padding(
                                padding: EdgeInsets.only(right: 4),
                                child: Icon(
                                  Icons.push_pin,
                                  size: 12,
                                  color: p.indigo,
                                ),
                              ),
                            if (task.recurrence != 'none')
                              const Padding(
                                padding: EdgeInsets.only(right: 4),
                                child: Icon(
                                  Icons.autorenew,
                                  size: 12,
                                  color: p.teal,
                                ),
                              ),
                            Expanded(
                              child: Text(
                                task.title,
                                style: TextStyle(
                                  fontSize: 13.5,
                                  height: 1.25,
                                  fontWeight: FontWeight.w600,
                                  color: p.ink,
                                  decoration: task.completed
                                      ? TextDecoration.lineThrough
                                      : null,
                                  decorationColor: p.inkSoft,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (task.note.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              task.note,
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: p.inkSoft,
                                height: 1.2,
                              ),
                            ),
                          ),
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 1.5,
                                ),
                                decoration: BoxDecoration(
                                  color: catColor.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                child: Text(
                                  '${category.emoji} ${catLabel(category)}',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: catColor,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              if (task.amount != null) ...[
                                const SizedBox(width: 6),
                                Text(
                                  '₩${_fmt(task.amount!)}',
                                  style: const TextStyle(
                                    fontSize: 10.5,
                                    color: p.inkSoft,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  onPressed: onDelete,
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 18,
                    color: p.danger,
                  ),
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Delete',
                ),
              ],
            ),
            // Quick category assignment chips (the "select a tab on the right
            // to instantly reclassify" behaviour).
            const SizedBox(height: 6),
            SizedBox(
              height: 26,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: assignTargets.length,
                separatorBuilder: (_, __) => const SizedBox(width: 5),
                itemBuilder: (_, i) {
                  final c = assignTargets[i];
                  final selected = c.id == task.categoryId;
                  final col = Color(c.colorValue);
                  return GestureDetector(
                    onTap: () => onAssign(c),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: selected
                            ? col.withValues(alpha: 0.16)
                            : p.card,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: selected ? col : p.line,
                          width: selected ? 1.2 : 0.8,
                        ),
                      ),
                      child: Text(
                        '${c.emoji} ${catLabel(c)}',
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: selected ? col : p.inkSoft,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

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
