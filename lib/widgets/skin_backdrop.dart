import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Paints the active skin's decorative backdrop (ruled paper, grid, gradient…)
/// behind the whole app. Wrapped around the app by [MaterialApp.builder] so it
/// also covers non-scaffold routes.
class SkinBackdrop extends StatelessWidget {
  final Widget child;
  const SkinBackdrop({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final palette = p;
    switch (palette.deco) {
      case SkinDeco.ruled:
        return CustomPaint(
          painter: _RuledPainter(palette),
          child: child,
        );
      case SkinDeco.grid:
        return CustomPaint(
          painter: _GridPainter(palette),
          child: child,
        );
      case SkinDeco.gradient:
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                palette.bg,
                Color.lerp(palette.bg, palette.card, 0.55)!,
              ],
            ),
          ),
          child: child,
        );
      case SkinDeco.plain:
        return ColoredBox(color: palette.bg, child: child);
    }
  }
}

/// Cream page with faint blue horizontal rules + a red margin line — the
/// reference "notebook" look.
class _RuledPainter extends CustomPainter {
  final AppPalette p;
  _RuledPainter(this.p);

  @override
  void paint(Canvas canvas, Size size) {
    // Base page.
    canvas.drawRect(Offset.zero & size, Paint()..color = p.bg);

    const spacing = 30.0;
    final rule = Paint()
      ..color = p.line.withValues(alpha: 0.75)
      ..strokeWidth = 1;
    for (double y = spacing; y < size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), rule);
    }

    // Double red margin line on the left.
    final margin = Paint()
      ..color = p.teal.withValues(alpha: 0.55)
      ..strokeWidth = 1.2;
    canvas.drawLine(const Offset(34, 0), Offset(34, size.height), margin);
    canvas.drawLine(const Offset(38, 0), Offset(38, size.height), margin);
  }

  @override
  bool shouldRepaint(covariant _RuledPainter old) => old.p != p;
}

/// Graph-paper grid.
class _GridPainter extends CustomPainter {
  final AppPalette p;
  _GridPainter(this.p);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = p.bg);
    const step = 26.0;
    final g = Paint()
      ..color = p.line.withValues(alpha: 0.6)
      ..strokeWidth = 0.8;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), g);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), g);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) => old.p != p;
}
