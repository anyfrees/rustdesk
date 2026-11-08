import 'dart:math' as math;
import 'package:flutter/material.dart';

class NnuDockMessagePlacement {
  NnuDockMessagePlacement(Rect workArea, Rect compact,
      [Size preferred = const Size(260, 76)])
      : onLeft = compact.center.dx >= workArea.center.dx,
        bounds = _bounds(workArea, compact, preferred),
        bubbleHeight = preferred.height;

  final bool onLeft;
  final Rect bounds;
  final double bubbleHeight;
  bool get canShow => bounds.width >= 150;
  static bool hasBubbleSpace(double windowWidth) => windowWidth > 94;

  static Rect _bounds(Rect area, Rect compact, Size preferred) {
    final left = compact.center.dx >= area.center.dx;
    final available =
        left ? compact.right - area.left : area.right - compact.left;
    final width = math.min(preferred.width + 94, available);
    return Rect.fromLTWH(left ? compact.right - width : compact.left,
        compact.top, width, compact.height);
  }
}

class NnuDockMessageBubble extends StatelessWidget {
  const NnuDockMessageBubble(
      {super.key,
      required this.text,
      required this.onLeft,
      required this.animation,
      required this.onOpen});

  final String text;
  final bool onLeft;
  final Animation<double> animation;
  final VoidCallback onOpen;

  static TextStyle textStyle(BuildContext context) =>
      (Theme.of(context).textTheme.bodyMedium ?? const TextStyle()).copyWith(
        fontSize: 13, height: 1.4,
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xffdef6ee) : const Color(0xff28545a));

  static Size measure(BuildContext context, String text, double maxWidth) {
    final scaler = MediaQuery.textScalerOf(context);
    final lines = (56 / (scaler.scale(13) * 1.4)).floor().clamp(1, 3);
    final width = maxWidth.clamp(56.0, 260.0);
    final painter = TextPainter(
      text: TextSpan(text: text, style: textStyle(context)),
      textDirection: Directionality.of(context), textScaler: scaler,
      maxLines: lines, ellipsis: '…', textWidthBasis: TextWidthBasis.longestLine,
    )..layout(maxWidth: width - 34);
    final result = Size((painter.width + 34).ceilToDouble().clamp(56, width),
        (painter.height + 22).ceilToDouble().clamp(34, 76));
    painter.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final shape = NnuSpeechBubbleBorder(
        onLeft: onLeft,
        side: BorderSide(
            color: dark ? const Color(0xff527c7c) : const Color(0xffb4dcd7)));
    final alignment = onLeft ? Alignment.centerRight : Alignment.centerLeft;
    return FadeTransition(
      opacity: animation,
      child: ScaleTransition(
        alignment: alignment,
        scale: Tween<double>(begin: .9, end: 1).animate(animation),
        child: Semantics(
          button: true,
          liveRegion: true,
          label: text,
          child: Material(
            color: dark ? const Color(0xff213e42) : const Color(0xffedfaf7),
            shape: shape,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              customBorder: shape,
              mouseCursor: SystemMouseCursors.click,
              onTap: onOpen,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                    onLeft ? 12 : 20, 10, onLeft ? 20 : 12, 10),
                child: LayoutBuilder(builder: (context, constraints) {
                  final line = MediaQuery.textScalerOf(context).scale(13) * 1.4;
                  return Align(
                      alignment: Alignment.centerLeft,
                      child: Text(text,
                          maxLines: (constraints.maxHeight / line)
                              .floor()
                              .clamp(1, 3),
                          overflow: TextOverflow.ellipsis,
                          style: textStyle(context)));
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class NnuSpeechBubbleBorder extends OutlinedBorder {
  const NnuSpeechBubbleBorder({required this.onLeft, super.side});
  final bool onLeft;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.width);
  @override
  ShapeBorder scale(double t) =>
      NnuSpeechBubbleBorder(onLeft: onLeft, side: side.scale(t));
  @override
  NnuSpeechBubbleBorder copyWith({BorderSide? side}) =>
      NnuSpeechBubbleBorder(onLeft: onLeft, side: side ?? this.side);
  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect.deflate(side.width), textDirection: textDirection);
  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    final body = Rect.fromLTRB(rect.left + (onLeft ? 0 : 8), rect.top,
        rect.right - (onLeft ? 8 : 0), rect.bottom);
    final base = onLeft ? body.right - 1 : body.left + 1;
    final tip = onLeft ? rect.right : rect.left;
    final triangle = Path()
      ..moveTo(base, rect.center.dy - 7)
      ..lineTo(tip, rect.center.dy)
      ..lineTo(base, rect.center.dy + 7)
      ..close();
    return Path.combine(
        PathOperation.union,
        Path()
          ..addRRect(RRect.fromRectAndRadius(body, const Radius.circular(16))),
        triangle);
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style != BorderStyle.none) {
      canvas.drawPath(
          getOuterPath(rect.deflate(side.width / 2)), side.toPaint());
    }
  }
}
