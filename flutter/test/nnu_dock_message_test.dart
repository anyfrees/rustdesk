import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_dock_message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('short messages shrink around the measured text', (tester) async {
    final sizes = <Size>[];
    for (final text in ['好', '收到，马上处理', '这是一条较长的消息，需要换行显示。' * 8]) {
      late Size measured;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(
        builder: (context) {
          measured = NnuDockMessageBubble.measure(context, text, 260);
          return Center(child: SizedBox.fromSize(size: measured,
            child: NnuDockMessageBubble(text: text, onLeft: true,
              animation: const AlwaysStoppedAnimation(1), onOpen: () {})));
        },
      ))));
      sizes.add(measured);
      expect(tester.getSize(find.byType(NnuDockMessageBubble)), measured);
      expect(measured.width, lessThanOrEqualTo(260));
      expect(measured.height, lessThanOrEqualTo(76));
      expect(tester.takeException(), isNull);
    }
    expect(sizes[0].width, lessThan(sizes[1].width));
    expect(sizes[1].width, lessThan(sizes[2].width));
    expect(sizes[0].height, lessThan(sizes[2].height));
    final compact = const Rect.fromLTWH(900, 100, 86, 86);
    final short = NnuDockMessagePlacement(const Rect.fromLTWH(0, 0, 1000, 600), compact, sizes.first);
    expect(short.bounds.width, sizes.first.width + 94);
    expect(short.bubbleHeight, sizes.first.height);
    expect(short.bounds.center.dy, compact.center.dy);
    for (final dpi in [1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 3.0]) {
      final actualWidth = (short.bounds.width * dpi).truncate() / dpi;
      expect(NnuDockMessagePlacement.hasBubbleSpace(actualWidth), isTrue,
          reason: 'short message after native pixel rounding at $dpi');
    }
    expect(NnuDockMessagePlacement.hasBubbleSpace(86), isFalse);
  });

  test('message opens toward the monitor interior and leaves the avatar fixed',
      () {
    for (final area in [
      const Rect.fromLTWH(0, 0, 1920, 1080),
      const Rect.fromLTWH(-1280, -200, 1280, 720),
      const Rect.fromLTWH(0, 0, 320, 240)
    ]) {
      for (final left in [true, false]) {
        for (final top in [area.top, area.bottom - 86]) {
          final compact = Rect.fromLTWH(
              left ? area.left + 4 : area.right - 90, top, 86, 86);
          final message = NnuDockMessagePlacement(area, compact);
          expect(message.onLeft, !left);
          expect(area.contains(message.bounds.topLeft), isTrue);
          expect(message.bounds.right, lessThanOrEqualTo(area.right));
          expect(message.bounds.bottom, lessThanOrEqualTo(area.bottom));
          final avatar = message.bounds.topLeft +
              Offset(message.onLeft ? message.bounds.width - 43 : 43, 43);
          expect(avatar, compact.center);
        }
      }
    }
  });

  testWidgets('long and scaled messages fit, update, and open chat on click',
      (tester) async {
    var opened = 0;
    for (final scale in [1.0, 1.5, 2.0, 3.0]) {
      for (final left in [true, false]) {
        await tester.pumpWidget(MaterialApp(
            home: Scaffold(
                body: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: Center(
              child: SizedBox(
            width: 190,
            height: 76,
            child: NnuDockMessageBubble(
                text: '消息内容很长，需要完整查看时点击进入聊天。' * 8,
                onLeft: left,
                animation: const AlwaysStoppedAnimation(1),
                onOpen: () => opened++),
          )),
        ))));
        expect(tester.takeException(), isNull);
        final ink = tester.widget<InkWell>(find.byType(InkWell));
        expect(ink.mouseCursor, SystemMouseCursors.click);
        await tester.tap(find.byType(InkWell));
      }
    }
    expect(opened, 8);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 260,
                height: 76,
                child: NnuDockMessageBubble(
                    text: '最新消息',
                    onLeft: true,
                    animation: const AlwaysStoppedAnimation(1),
                    onOpen: () {})))));
    expect(find.text('最新消息'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
