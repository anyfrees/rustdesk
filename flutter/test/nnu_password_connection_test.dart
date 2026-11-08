import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_password_connection.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('visible password requests stay in the same dock after authorization', () {
    final peer = Client(9, false, false, false, 'Peer', '123', false, false, false);
    Client? dock({String mode = 'password', bool hidden = false, List<Client>? clients}) =>
        nnuPasswordConnectionDock(clients ?? [peer], approveMode: mode, hidden: hidden);
    expect(dock(), same(peer));
    expect(peer.trustedConnectedAt, isNull);
    expect(dock(hidden: true), isNull);
    expect(dock(mode: 'click'), isNull);
    expect(dock(mode: 'both'), isNull);
    expect(dock(clients: [peer, Client(10, false, false, false, 'B', '456', false, false, false)]), isNull);
    peer.authorized = true;
    expect(dock(), same(peer));
    peer.nnuVoiceOnly = true;
    expect(dock(), isNull);
    peer.nnuVoiceOnly = false;
    peer.isFileTransfer = true;
    expect(dock(), isNull);
    peer.isFileTransfer = false;
    peer.disconnected = true;
    expect(dock(), isNull);
  });

  testWidgets('pending card can only reject, successful password changes its action in place', (tester) async {
    final peer = Client(9, false, false, false, 'Peer', '123', false, false, false);
    var closes = 0;
    Future<void> show() => tester.pumpWidget(MaterialApp(home: Scaffold(body:
      Center(child: SizedBox(width: 342, height: 244, child:
        NnuPasswordConnectionCard(client: peer, name: 'Peer', onDisconnect: () => closes++))))));
    await show();
    expect(find.text('等待密码验证'), findsOneWidget);
    expect(find.text('已连接'), findsNothing);
    expect(find.text('拒绝连接').hitTestable(), findsOneWidget);
    expect(find.text('接受远程'), findsNothing);
    expect(find.byIcon(Icons.chat_bubble_outline_rounded), findsNothing);
    await tester.tap(find.text('拒绝连接'));
    expect(closes, 1);
    peer.authorized = true;
    await show();
    await tester.pumpAndSettle();
    expect(find.text('等待密码验证'), findsNothing);
    expect(find.text('已连接'), findsOneWidget);
    expect(find.text('断开连接').hitTestable(), findsOneWidget);
    expect(find.text('拒绝连接'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('verified pending profile and reject action fit small displays and enlarged text', (tester) async {
    final peer = Client(9, false, false, false, 'Peer', '123', false, false, false)
      ..officialSupport = const NnuOfficialSupportIdentity('官方认证', '管理员填写的认证说明', 'black_gold', accountName: 'IT_SERVER');
    for (final size in [const Size(342, 244), const Size(320, 244)]) {
      for (final scale in [1.0, 2.0]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpWidget(MaterialApp(home: Scaffold(body: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale), disableAnimations: true),
          child: NnuPasswordConnectionCard(client: peer, name: 'IT_SERVER', onDisconnect: () {})))));
        expect(find.text('IT_SERVER'), findsOneWidget);
        expect(find.text('拒绝连接').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.binding.setSurfaceSize(null);
  });
}
