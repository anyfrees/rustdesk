import 'dart:math' as math;

import 'package:flutter/material.dart';

const nnuOfficialSupportTypography = TextStyle(
  fontFamily: 'DouyinSans',
  fontFamilyFallback: [
    'Microsoft YaHei UI',
    'PingFang SC',
    'Noto Sans CJK SC',
    'Noto Sans',
    'Roboto',
    'sans-serif',
  ],
);

class NnuOfficialSupportPalette {
  const NnuOfficialSupportPalette(this.accent);

  final Color accent;

  static NnuOfficialSupportPalette forColor(String color) => switch (color) {
        'red' => const NnuOfficialSupportPalette(Color(0xffff5e73)),
        'yellow' => const NnuOfficialSupportPalette(Color(0xffffdd3d)),
        'black_gold' => const NnuOfficialSupportPalette(Color(0xffffc25c)),
        _ => const NnuOfficialSupportPalette(Color(0xff3db5ff)),
      };
}

class NnuOfficialSupportBadge extends StatefulWidget {
  const NnuOfficialSupportBadge({
    super.key,
    required this.badgeColor,
    required this.displayName,
    required this.verifiedLabel,
    this.introduction = '',
    this.alignment = Alignment.center,
    this.compact = false,
  });

  final String badgeColor;
  final String displayName;
  final String verifiedLabel;
  final String introduction;
  final AlignmentGeometry alignment;
  final bool compact;

  @override
  State<NnuOfficialSupportBadge> createState() =>
      _NnuOfficialSupportBadgeState();
}

class _NnuOfficialSupportBadgeState extends State<NnuOfficialSupportBadge>
    with SingleTickerProviderStateMixin {
  late final _shine = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 7),
  );
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (_reduceMotion) {
      _shine.stop();
    } else if (!_shine.isAnimating) {
      _shine.repeat();
    }
  }

  @override
  void dispose() {
    _shine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = NnuOfficialSupportPalette.forColor(widget.badgeColor);
    return Align(
      alignment: widget.alignment,
      widthFactor: widget.compact ? 1 : null,
      child: Tooltip(
        message: widget.introduction.trim(),
        height: 0,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        excludeFromSemantics: true,
        waitDuration: const Duration(milliseconds: 350),
        child: RepaintBoundary(
          child: Stack(
            children: [
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: widget.compact ? 7 : 8,
                    vertical: 4),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xff4a4337), Color(0xff302d27)],
                  ),
                  border: Border.all(color: const Color(0xffead8b2)),
                  borderRadius: BorderRadius.circular(widget.compact ? 30 : 6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Semantics(
                      label: widget.verifiedLabel,
                      image: true,
                      child: Icon(Icons.verified_outlined,
                          size: MediaQuery.textScalerOf(context).scale(
                              widget.compact ? 13 : 18), color: palette.accent),
                    ),
                    SizedBox(width: widget.compact ? 4 : 6),
                    Flexible(
                      child: Text(
                        widget.displayName,
                        maxLines: widget.compact ? 1 : 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        textWidthBasis: TextWidthBasis.longestLine,
                        textHeightBehavior: const TextHeightBehavior(
                          applyHeightToFirstAscent: false,
                          applyHeightToLastDescent: false),
                        style: theme.textTheme.labelLarge
                            ?.merge(nnuOfficialSupportTypography)
                            .copyWith(
                                color: const Color(0xfff4e4c1),
                                fontSize: widget.compact ? 12 : 15,
                                fontWeight: FontWeight.w500,
                                height: 1.15),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(widget.compact ? 30 : 6),
                    child: CustomPaint(
                      painter: _SupportLabelShine(_shine, !_reduceMotion),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SupportLabelShine extends CustomPainter {
  _SupportLabelShine(this.animation, this.animate) : super(repaint: animation);

  final Animation<double> animation;
  final bool animate;

  @override
  void paint(Canvas canvas, Size size) {
    if (!animate || animation.value >= .34) return;
    const sheen = Color(0xfffff0d1);
    const strength = .16;
    final phase = animation.value / .34;
    final progress = Curves.easeInOutSine.transform(phase);
    final opacity = math.sin(math.pi * phase);
    final band = Rect.fromLTWH((-1 + progress * 3) * size.width,
        -size.height * .4, size.width * .85, size.height * 1.8);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            sheen.withOpacity(0),
            sheen.withOpacity(strength * .2 * opacity),
            sheen.withOpacity(strength * opacity),
            sheen.withOpacity(strength * .2 * opacity),
            sheen.withOpacity(0),
          ],
          stops: const [0, .3, .5, .7, 1],
        ).createShader(band),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(.5), const Radius.circular(5.5)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = .7
        ..color = sheen.withOpacity(strength * opacity),
    );
  }

  @override
  bool shouldRepaint(_SupportLabelShine oldDelegate) =>
      oldDelegate.animate != animate;
}
