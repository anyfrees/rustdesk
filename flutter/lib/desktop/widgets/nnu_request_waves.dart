import 'dart:math' as math;

import 'package:flutter/material.dart';

class NnuRequestWaves extends StatefulWidget {
  const NnuRequestWaves({super.key, required this.child});

  final Widget child;

  @override
  State<NnuRequestWaves> createState() => _NnuRequestWavesState();
}

class _NnuRequestWavesState extends State<NnuRequestWaves>
    with SingleTickerProviderStateMixin {
  late final _phase = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 3800));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _phase.stop();
    } else if (!_phase.isAnimating) {
      _phase.repeat();
    }
  }

  @override
  void dispose() {
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: CustomPaint(
          painter: _RequestWavesPainter(
              _phase, !MediaQuery.disableAnimationsOf(context)),
          child: widget.child,
        ),
      );
}

class _RequestWavesPainter extends CustomPainter {
  _RequestWavesPainter(this.phase, this.animate) : super(repaint: phase);

  final Animation<double> phase;
  final bool animate;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.shortestSide <= 32) return;
    final base = (Offset.zero & size).deflate(16);
    final edge =
        RRect.fromRectAndRadius(base.inflate(.6), const Radius.circular(24.6));
    canvas.drawRRect(
        edge,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.4
          ..color = const Color(0x30388fe3)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    canvas.drawRRect(
        edge,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = const Color(0xa33987e3));
    if (!animate) return;
    for (final delay in [0.0, .5]) {
      final t = (phase.value + delay) % 1;
      final opacity = math.sin(math.pi * t) * .82;
      final rect = base.inflate(Curves.easeOutCubic.transform(t) * 12);
      final shape = RRect.fromRectAndRadius(rect, Radius.circular(24 + t * 10));
      final shader = SweepGradient(
        transform: GradientRotation(phase.value * math.pi * 2),
        colors: const [
          Color(0xff2874e8),
          Color(0xff2b9ded),
          Color(0xff456ef0),
          Color(0xff2b9ded),
          Color(0xff2874e8),
        ].map((color) => color.withOpacity(opacity)).toList(),
      ).createShader(rect);
      canvas.drawRRect(
          shape,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.2
            ..shader = shader);
    }
  }

  @override
  bool shouldRepaint(covariant _RequestWavesPainter old) =>
      old.phase != phase || old.animate != animate;
}
