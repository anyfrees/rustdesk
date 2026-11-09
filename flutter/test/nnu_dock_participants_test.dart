import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_dock_message.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_dock_participants.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'participant colors stay distinct when the operator changes or a peer leaves',
      () {
    final colors = NnuDockParticipantColors()
      ..retain([1, 9, 17, 2, 8, 3, 5, 4]);
    final before = {
      for (final id in [1, 9, 17, 2, 8, 3, 5, 4]) id: colors.colorFor(id)
    };
    expect(before.values.toSet(), hasLength(8));
    colors.retain([17, 9, 2, 8, 3, 5, 4, 22]);
    for (final id in [17, 9, 2, 8, 3, 5, 4]) {
      expect(colors.colorFor(id), before[id]);
    }
    expect(colors.colorFor(22), before[1]);
  });

  test(
      'short messages from every peer queue in arrival order without duplicate notifications',
      () {
    final queue = NnuDockMessageQueue();
    final historical = Object();
    queue.markSeen(1, historical);
    queue.add(NnuDockNotice(1, historical, '旧记录'));
    expect(queue.take({1, 2}), isNull);
    final first = NnuDockNotice(2, Object(), '好');
    queue.add(first);
    queue.add(first);
    queue.add(NnuDockNotice(1, Object(), '好'));
    queue.add(NnuDockNotice(2, Object(), '好'));
    expect(queue.take({1, 2}), same(first));
    final next = queue.take({1, 2})!;
    expect(next.connectionId, 1);
    queue.retry(next);
    expect(queue.take({1, 2}), same(next));
    expect(queue.take({1, 2})!.connectionId, 2);
    expect(queue.take({1, 2}), isNull);
    queue.add(NnuDockNotice(2, Object(), '已退出'));
    queue.add(NnuDockNotice(1, Object(), '收到'));
    expect(queue.take({1})!.text, '收到');
    expect(queue.take({1}), isNull);
    for (var i = 0; i < 40; i++) {
      queue.add(NnuDockNotice(1, Object(), '$i'));
    }
    expect(queue.take({1})!.text, '16');
  });

  testWidgets(
      'sender-tinted bubbles fit short and long messages in both themes and open the sender chat',
      (tester) async {
    final colors = NnuDockParticipantColors()..retain([1, 2]);
    var opened = 0;
    final backgrounds = <Color>{};
    for (final dark in [false, true]) {
      for (final scale in [1.0, 2.0, 3.0]) {
        for (final id in [1, 2]) {
          final text = id == 1 ? '小王：好' : '另一位用户：${'这是测试消息。' * 20}';
          await tester.pumpWidget(MaterialApp(
            theme: ThemeData(
                brightness: dark ? Brightness.dark : Brightness.light),
            home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Scaffold(body: Builder(builder: (context) {
                  final measured =
                      NnuDockMessageBubble.measure(context, text, 260);
                  expect(measured.width, lessThanOrEqualTo(260));
                  expect(measured.height, lessThanOrEqualTo(76));
                  return Center(
                      child: SizedBox.fromSize(
                          size: measured,
                          child: NnuDockMessageBubble(
                              text: text,
                              onLeft: id == 1,
                              animation: const AlwaysStoppedAnimation(1),
                              accent: colors.colorFor(id),
                              onOpen: () => opened = id)));
                }))),
          ));
          await tester.pumpAndSettle();
          final material = tester.widget<Material>(find
              .descendant(
                  of: find.byType(NnuDockMessageBubble),
                  matching: find.byType(Material))
              .first);
          backgrounds.add(material.color!);
          final ink = tester.widget<Text>(find.text(text)).style!.color!;
          final l1 = ink.computeLuminance(),
              l2 = material.color!.computeLuminance();
          expect(((l1 > l2 ? l1 : l2) + .05) / ((l1 < l2 ? l1 : l2) + .05),
              greaterThan(4.5));
          await tester.tap(find.byType(NnuDockMessageBubble));
          expect(opened, id);
          expect(tester.takeException(), isNull);
        }
      }
    }
    expect(backgrounds, hasLength(4));
  });
}
