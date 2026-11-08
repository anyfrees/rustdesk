import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/nnu_official_support_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const short = '完整显示的简介';
  const long =
      '这是一段用于验证完整认证简介的文字，只有在当前宽度和字号下被截断时，悬停或长按才显示全文。窗口变宽后能完整显示，就不再弹出重复提示。';
  Widget content(String text, double width) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: NnuOfficialSupportText(text,
                  style: const TextStyle(fontSize: 13)),
            ),
          ),
        ),
      );

  testWidgets('hover shows full text only while its rendered lines are clipped',
      (tester) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    for (final example in [
      (short, 150.0, 1),
      (long, 150.0, 2),
      (long, 700.0, 1)
    ]) {
      await mouse.moveTo(Offset.zero);
      await tester.pumpWidget(content(example.$1, example.$2));
      await mouse.moveTo(tester.getCenter(find.byType(NnuOfficialSupportText)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
      expect(find.text(example.$1), findsNWidgets(example.$3));
      expect(tester.takeException(), isNull);
    }
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'long press reveals truncated text and leaves complete text alone',
      (tester) async {
    for (final example in [(short, 1), (long, 2)]) {
      await tester.pumpWidget(content(example.$1, 150));
      await tester.longPress(find.text(example.$1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text(example.$1), findsNWidgets(example.$2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
