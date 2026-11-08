import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_session_ended.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_hbb/common/widgets/nnu_official_support_badge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only a sole disconnected verified desktop session uses the ending card', () {
    final client = Client(7, true, false, false, 'Support', '123', true, true, true)
      ..officialSupport = const NnuOfficialSupportIdentity('官方认证', '说明', 'black_gold');
    expect(nnuTrustedEndedClient([client]), isNull);
    expect(nnuTrustedEndedClient([], previousDock: client), same(client));
    expect(nnuTrustedEndedClient([], previousDock: client, showWindow: false), isNull);
    expect(nnuTrustedEndedClient([client], previousDock: client), isNull);
    client.disconnected = true;
    expect(nnuTrustedEndedClient([client]), same(client));
    client.isFileTransfer = true;
    expect(nnuTrustedEndedClient([client]), isNull);
    client.isFileTransfer = false;
    expect(nnuTrustedEndedClient([client, client]), isNull);
    client.officialSupport = null;
    expect(nnuTrustedEndedClient([client]), isNull);
  });

  testWidgets('ending avatar waits for arrival then reveals the centered card', (tester) async {
    final reveal = ValueNotifier(false);
    const identity = NnuOfficialSupportIdentity('官方认证', '', 'blue', accountName: 'Support');
    await tester.binding.setSurfaceSize(nnuSessionEndedSize);
    await tester.pumpWidget(MaterialApp(home: Scaffold(backgroundColor: Colors.transparent,
      body: NnuSessionEndTransition(identity: identity, revealed: reveal,
        child: NnuSessionEnded(identity: identity, peerId: '123', onClose: () {})))));
    expect(find.text('远程协助已结束'), findsNothing);
    expect(tester.getCenter(find.byType(NnuSessionEndTransition)),
        nnuSessionEndedSize.center(Offset.zero));
    reveal.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('远程协助已结束'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '关闭').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    reveal.dispose();
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('ending card is compact, closes, and remains scrollable at large text sizes', (tester) async {
    var closes = 0;
    for (final scale in [1.0, 2.0]) {
      await tester.binding.setSurfaceSize(nnuSessionEndedSize);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale), disableAnimations: true),
        child: NnuSessionEnded(identity: const NnuOfficialSupportIdentity('官方认证', '认证说明', 'black_gold', accountName: 'IT_SERVER'),
          peerId: '1247744734', onClose: () => closes++),
      ))));
      expect(find.text('远程协助已结束'), findsOneWidget);
      expect(find.text('00:00:00'), findsNothing);
      final badge = tester.getRect(find.byType(NnuOfficialSupportBadge));
      final name = tester.getRect(find.text('IT_SERVER'));
      expect(name.right, lessThan(badge.left));
      expect(badge.center.dy, closeTo(name.center.dy, .5));
      if (scale == 1.0) {
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(name.center);
        await tester.pump(const Duration(milliseconds: 800));
        expect(find.text('认证说明'), findsNothing);
        expect(find.text('通过官方认证'), findsNothing);
        await mouse.moveTo(badge.center);
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.text('认证说明'), findsOneWidget);
        await mouse.removePointer();
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(find.byIcon(Icons.chat_bubble_outline), findsNothing);
      final close = find.widgetWithText(FilledButton, '关闭');
      await tester.ensureVisible(close);
      await tester.pump();
      await tester.tap(close);
      expect(tester.takeException(), isNull);
    }
    expect(closes, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.binding.setSurfaceSize(null);
  });
}
