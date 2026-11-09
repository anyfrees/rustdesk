import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/nnu_official_support_badge.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_connection_orbit.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_test/flutter_test.dart';

Client peer(int id) =>
    Client(id, true, false, false, 'Terminal $id', '$id', true, true, true)
      ..officialSupport = NnuOfficialSupportIdentity('官方认证', '', 'black_gold',
          accountName: 'Support $id')
      ..trustedConnectedAt = DateTime.now();

void main() {
  test(
      'multi control keeps eligible desktops, follows input and pins manual inspection',
      () {
    final a = peer(1), b = peer(2), file = peer(3)..isFileTransfer = true;
    List<Client> docks(List<Client> clients,
            {String mode = 'click', bool hidden = false}) =>
        nnuMultipleDockClients(clients, approveMode: mode, hidden: hidden);
    expect(docks([a]), isEmpty);
    expect(docks([b, a]), [a, b]);
    expect(nnuChooseDockClient(docks([b, a]), operating: 2), same(b));
    expect(
        nnuChooseDockClient(docks([b, a]), operating: 2, viewed: 1), same(a));
    a.disconnected = true;
    expect(nnuChooseDockClient(docks([a, b, file]), operating: 2, viewed: 1),
        same(b));
    a.disconnected = false;
    expect(docks([a, b], hidden: true), isEmpty);
    expect(docks([a, file]), [a]);
    file.authorized = false;
    expect(docks([a, file]), isEmpty);
    file.authorized = true;
    b.officialSupport = null;
    expect(docks([a, b]), isEmpty);
    b.authorized = false;
    expect(docks([a, b], mode: 'password'), [a, b]);
    b.nnuVoiceOnly = true;
    expect(docks([a, b], mode: 'password'), [a]);
  });

  testWidgets(
      'satellite avatars remain clickable and promote without losing their targets',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(86, 86));
    final clients = List.generate(10, (i) => peer(i + 1));
    var selected = 1, showAll = 0;
    Future<void> show(int count) => tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NnuConnectionOrbit(
                clients: clients.take(count).toList(),
                selectedId: selected,
                primary: const Center(child: Text('PRIMARY')),
                onSelect: (id) => selected = id,
                onShowAll: () => showAll++))));
    for (final count in [2, 3, 7, 10]) {
      selected = 1;
      await show(count);
      await tester.pumpAndSettle();
      final slots = count > 7 ? 6 : count - 1;
      for (var i = 0; i < (count > 7 ? 5 : count - 1); i++) {
        final point = const Offset(43, 43) + nnuOrbitOffset(i, slots);
        await tester.tapAt(point);
        expect(selected, i + 2);
      }
      if (count > 7) {
        await tester.tapAt(const Offset(43, 43) + nnuOrbitOffset(5, 6));
        expect(showAll, 1);
      }
      await show(count);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
    }
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(
        location: const Offset(43, 43) + nnuOrbitOffset(0, 6));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('all sessions are reachable on small cards and enlarged text',
      (tester) async {
    final clients = List.generate(20, (i) => peer(i + 1));
    var selected = 1;
    for (final scale in [1.0, 2.0]) {
      await tester.binding.setSurfaceSize(const Size(320, 244));
      await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: NnuDockConnectionsCard(
                  clients: clients,
                  selectedId: selected,
                  onSelect: (id) => selected = id,
                  onBack: () {}))));
      await tester.scrollUntilVisible(find.text('Support 20'), 150,
          scrollable: find.byType(Scrollable));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Support 20'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Support 20'));
      expect(selected, 20);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.binding.setSurfaceSize(null);
  });
}
