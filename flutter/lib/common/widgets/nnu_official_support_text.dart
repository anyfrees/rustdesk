import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

class NnuOfficialSupportText extends StatefulWidget {
  const NnuOfficialSupportText(
    this.text, {
    super.key,
    this.style,
    this.textAlign = TextAlign.start,
    this.maxLines = 2,
  });

  final String text;
  final TextStyle? style;
  final TextAlign textAlign;
  final int maxLines;

  @override
  State<NnuOfficialSupportText> createState() => _NnuOfficialSupportTextState();
}

class _NnuOfficialSupportTextState extends State<NnuOfficialSupportText> {
  final _textKey = GlobalKey();
  final _tooltipKey = GlobalKey<TooltipState>();
  bool _clipped = false;

  bool _checkOverflow() {
    final paragraph = _textKey.currentContext?.findRenderObject();
    final clipped = paragraph is RenderParagraph && paragraph.didExceedMaxLines;
    if (_clipped != clipped) setState(() => _clipped = clipped);
    return clipped;
  }

  void _showOnLongPress() {
    if (!_checkOverflow()) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _tooltipKey.currentState?.ensureTooltipVisible();
    });
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => _checkOverflow(),
        onHover: (_) => _checkOverflow(),
        child: GestureDetector(
          onLongPress: _showOnLongPress,
          child: Tooltip(
            key: _tooltipKey,
            message: _clipped ? widget.text : '',
            excludeFromSemantics: true,
            waitDuration: const Duration(milliseconds: 650),
            child: Text(
              widget.text,
              key: _textKey,
              style: widget.style,
              textAlign: widget.textAlign,
              maxLines: widget.maxLines,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      );
}
