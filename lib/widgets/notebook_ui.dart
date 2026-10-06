import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// ---------- Hand-writing / notebook accents ----------
///
/// A small kit of hand-drawn decorations used to give the "줄노트" (ruled
/// notebook) skin a real note-taking feel:
///
///   * [HandHighlight] — a fluorescent-marker swipe painted *behind* text.
///   * [HandAsterisk]  — a sketchy hand-drawn asterisk (별표) marker.
///   * [HandCheck]     — a wobbly hand-drawn checkbox + check.
///   * [WashiTape]     — a translucent tape strip for topping labels.
///
/// All of them respect the active skin palette and the hand-writing state so
/// they only add flavour when the notebook look is on.

/// A fluorescent highlighter swipe behind [child].
class HandHighlight extends StatelessWidget {
  final Widget child;
  final Color? color;
  final double opacity;
  final EdgeInsets padding;

  const HandHighlight({
    super.key,
    required this.child,
    this.color,
    this.opacity = 1.0,
    this.padding = const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _HighlighterPainter(color ?? const Color(0xFFFFE066), opacity),
      child: Padding(padding: padding, child: child),
    );
  }
}

class _HighlighterPainter extends CustomPainter {
  final Color color;
  final double opacity;
  _HighlighterPainter(this.color, this.opacity);

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()
      ..color = color.withValues(alpha: 0.55 * opacity)
      ..style = PaintingStyle.fill;
    final h = size.height;
    final y = h * 0.60;
    final thick = h * 0.46;

    final path = Path()
      ..moveTo(-3, y + thick * 0.30)
      ..quadraticBezierTo(
          size.width * 0.2, y - thick * 0.28, size.width * 0.5, y)
      ..quadraticBezierTo(
          size.width * 0.8, y + thick * 0.24, size.width + 3, y - thick * 0.12)
      ..lineTo(size.width + 3, y + thick)
      ..quadraticBezierTo(size.width * 0.8, y + thick * 1.12,
          size.width * 0.5, y + thick * 0.86)
      ..quadraticBezierTo(
          size.width * 0.2, y + thick * 0.7, -3, y + thick)
      ..close();
    canvas.drawPath(path, fill);

    // A second lighter swipe gives the chisel-tip marker texture.
    final swipe = Paint()
      ..color = color.withValues(alpha: 0.28 * opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = h * 0.16
      ..strokeCap = StrokeCap.round;
    final p2 = Path()
      ..moveTo(0, y + thick * 0.62)
      ..quadraticBezierTo(
          size.width * 0.5, y + thick * 0.34, size.width, y + thick * 0.66);
    canvas.drawPath(p2, swipe);
  }

  @override
  bool shouldRepaint(covariant _HighlighterPainter old) =>
      old.color != color || old.opacity != opacity;
}

/// A hand-drawn asterisk (별표). Each [seed] gives a slightly different sketch.
class HandAsterisk extends StatelessWidget {
  final double size;
  final Color? color;
  final int seed;
  const HandAsterisk({super.key, this.size = 14, this.color, this.seed = 7});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _AsteriskPainter(color ?? p.teal, seed),
    );
  }
}

class _AsteriskPainter extends CustomPainter {
  final Color color;
  final int seed;
  _AsteriskPainter(this.color, this.seed);

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(seed);
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width * 0.44;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.10
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    const rays = 6;
    for (var i = 0; i < rays; i++) {
      final a = (i / rays) * 2 * math.pi + (rnd.nextDouble() - 0.5) * 0.24;
      final wob = 0.9 + rnd.nextDouble() * 0.28;
      final tip = Offset(c.dx + math.cos(a) * r * wob,
          c.dy + math.sin(a) * r * wob);
      final mid = Offset(
        c.dx + math.cos(a) * r * 0.4 + (rnd.nextDouble() - 0.5) * 2.0,
        c.dy + math.sin(a) * r * 0.4 + (rnd.nextDouble() - 0.5) * 2.0,
      );
      canvas.drawPath(
        Path()
          ..moveTo(c.dx, c.dy)
          ..quadraticBezierTo(mid.dx, mid.dy, tip.dx, tip.dy),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _AsteriskPainter old) =>
      old.color != color || old.seed != seed;
}

/// A wobbly hand-drawn checkbox (and optional tick).
class HandCheck extends StatelessWidget {
  final double size;
  final Color? color;
  final bool checked;
  const HandCheck({super.key, this.size = 20, this.color, this.checked = true});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _CheckPainter(color ?? p.indigo, checked),
    );
  }
}

class _CheckPainter extends CustomPainter {
  final Color color;
  final bool checked;
  _CheckPainter(this.color, this.checked);

  @override
  void paint(Canvas canvas, Size size) {
    final box = Paint()
      ..color = color.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.075
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final m = size.width * 0.15;
    final square = Path()
      ..moveTo(m * 0.9, m * 0.7)
      ..lineTo(size.width - m, m * 0.9)
      ..lineTo(size.width - m * 0.6, size.height - m)
      ..lineTo(m * 0.6, size.height - m * 0.85)
      ..close();
    canvas.drawPath(square, box);

    if (checked) {
      final check = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * 0.14
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(
        Path()
          ..moveTo(size.width * 0.22, size.height * 0.52)
          ..lineTo(size.width * 0.42, size.height * 0.74)
          ..lineTo(size.width * 0.84, size.height * 0.24),
        check,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CheckPainter old) =>
      old.color != color || old.checked != checked;
}

/// A translucent "washi tape" strip, handy for dressing up a label.
class WashiTape extends StatelessWidget {
  final Widget child;
  final Color? color;
  const WashiTape({super.key, required this.child, this.color});

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: -0.03,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: (color ?? p.indigo).withValues(alpha: 0.18),
          border: Border(
            top: BorderSide(
                color: (color ?? p.indigo).withValues(alpha: 0.35), width: 0.7),
            bottom: BorderSide(
                color: (color ?? p.indigo).withValues(alpha: 0.35), width: 0.7),
          ),
        ),
        child: child,
      ),
    );
  }
}
