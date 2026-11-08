import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_password_connection.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only a cancelled visible password request retains its last avatar for exit', () {
    final peer = Client(9, false, false, false, 'A', '123', false, false, false);
    Client? cancelled({bool dock = true, bool visible = true, List<Client> clients = const []}) =>
      nnuCancelledPasswordDock(peer, clients, wasDock: dock, visiblePasswordMode: visible);
    expect(cancelled(), same(peer));
    peer.disconnected = true;
    expect(cancelled(clients: [peer]), same(peer));
    expect(cancelled(dock: false), isNull);
    expect(cancelled(visible: false), isNull);
    expect(cancelled(clients: [Client(10, false, false, false, 'B', '456', false, false, false)]), isNull);
    peer.authorized = true;
    expect(cancelled(), isNull);
  });

  test('cancel fades monotonically before hiding and never hides a newer request', () async {
    final opacity = <double>[];
    var hidden = false;
    expect(await nnuFadeCancelledPasswordDock(reducedMotion: false,
      stillCurrent: () => true, setOpacity: (value) async => opacity.add(value),
      hide: () async { expect(opacity.last, 0); hidden = true; }), true);
    expect(hidden, true);
    expect(opacity.first, greaterThan(.9));
    expect(opacity.last, 0);
    expect(opacity, orderedEquals([...opacity]..sort((a, b) => b.compareTo(a))));
    var current = true;
    hidden = false;
    expect(await nnuFadeCancelledPasswordDock(reducedMotion: false,
      stillCurrent: () => current, setOpacity: (_) async { current = false; },
      hide: () async { hidden = true; }), false);
    expect(hidden, false);
    opacity.clear();
    expect(await nnuFadeCancelledPasswordDock(reducedMotion: true,
      stillCurrent: () => true, setOpacity: (value) async => opacity.add(value),
      hide: () async { hidden = true; }), true);
    expect(opacity, [0]);
  });

  testWidgets('exiting card keeps its material without waiting text or clickable actions', (tester) async {
    final peer = Client(9, false, false, false, 'A', '123', false, false, false);
    for (final size in [const Size(342, 244), const Size(213, 160)]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body:
        NnuPasswordConnectionCard(client: peer, name: 'A', onDisconnect: () {}))));
      expect(find.text('拒绝连接').hitTestable(), findsOneWidget);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body:
        NnuPasswordConnectionCard(client: peer, name: 'A', exiting: true,
          onDisconnect: () => fail('cancelled requests cannot be acted on')))));
      expect(find.text('等待密码验证').hitTestable(), findsNothing);
      expect(find.text('拒绝连接').hitTestable(), findsNothing);
      expect(find.byType(NnuPasswordConnectionCard), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.binding.setSurfaceSize(null);
  });
}
