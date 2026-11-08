import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/nnu_official_support_badge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('verification statement appears only in the badge hover tooltip', (tester) async {
    const statement = '管理员授予的专业技术支持认证说明';
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Center(
      child: NnuOfficialSupportBadge(badgeColor: 'blue', displayName: '官方认证',
        verifiedLabel: '已通过官方认证', introduction: statement, compact: true),
    ))));
    expect(find.text(statement), findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('官方认证')));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text(statement), findsOneWidget);
    expect(find.textContaining('已通过官方认证'), findsNothing);
    final tooltipSize = tester.getSize(find.text(statement));
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Center(
      child: NnuOfficialSupportBadge(badgeColor: 'blue', displayName: '官方认证',
        verifiedLabel: '已通过官方认证', introduction: '支持', compact: true),
    ))));
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('官方认证')));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getSize(find.text('支持')).width, lessThan(tooltipSize.width));
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('compact badge content shares its center at different text scales', (tester) async {
    for (final scale in [1.0, 1.25, 1.75, 2.0]) {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale), disableAnimations: true),
        child: const NnuOfficialSupportBadge(badgeColor: 'black_gold', displayName: '官方认证',
          verifiedLabel: '已通过官方认证', compact: true),
      )))));
      final icon = tester.getRect(find.byIcon(Icons.verified_outlined));
      final text = tester.getRect(find.text('官方认证'));
      final row = tester.getRect(find.byType(Row));
      expect(icon.center.dy, closeTo(text.center.dy, .5));
      expect(row.center.dx, closeTo((icon.left + text.right) / 2, .5));
      expect(tester.widget<Icon>(find.byIcon(Icons.verified_outlined)).size, 13 * scale);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  Widget badge(String color,
          {bool reducedMotion = false,
          String introduction = '管理员填写的技术支持说明',
          Brightness brightness = Brightness.light}) =>
      MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reducedMotion),
          child: Scaffold(
            body: Center(
              child: NnuOfficialSupportBadge(
                badgeColor: color,
                displayName: '南京师范大学远程帮助',
                verifiedLabel: '通过官方认证',
                introduction: introduction,
              ),
            ),
          ),
        ),
      );

  testWidgets('registered name follows the verified icon with a hover status',
      (tester) async {
    await tester.pumpWidget(badge('black_gold'));
    expect(find.text('南京师范大学远程帮助'), findsOneWidget);
    expect(find.byIcon(Icons.verified_outlined), findsOneWidget);
    expect(find.text('通过官方认证'), findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byIcon(Icons.verified_outlined)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('管理员填写的技术支持说明'), findsOneWidget);
    await mouse.moveTo(Offset.zero);
    await tester.pump(const Duration(milliseconds: 200));
    await mouse.moveTo(tester.getCenter(find.text('南京师范大学远程帮助')));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('管理员填写的技术支持说明'), findsOneWidget);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(badge('black_gold', introduction: '   '));
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('南京师范大学远程帮助')));
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('通过官方认证'), findsNothing);
    expect(find.text('管理员填写的技术支持说明'), findsNothing);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('icon and name stay centered within a narrow card',
      (tester) async {
    const name = '南京师范大学远程帮助 · 合成值班人员';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            key: const ValueKey('card'),
            width: 246,
            child: NnuOfficialSupportBadge(
              badgeColor: 'blue',
              displayName: name,
              verifiedLabel: '通过官方认证',
            ),
          ),
        ),
      ),
    ));
    final group = tester.getRect(find.byType(Row));
    final card = tester.getRect(find.byKey(const ValueKey('card')));
    final icon = tester.getRect(find.byIcon(Icons.verified_outlined));
    final label = tester.getRect(find.text(name));
    expect(group.center.dx, closeTo(card.center.dx, .5));
    expect(icon.right, lessThan(label.left));
    expect(icon.center.dy, closeTo(label.center.dy, .5));
    await tester.pump(const Duration(milliseconds: 900));
    expect(tester.getRect(find.byType(Row)), group);
    expect(tester.getRect(find.text(name)), label);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'four icon colors share one name color and respect reduced motion',
      (tester) async {
    final semantics = tester.ensureSemantics();
    for (final brightness in Brightness.values) {
      final nameColors = <Color?>{};
      final iconColors = <Color?>{};
      for (final color in ['blue', 'red', 'yellow', 'black_gold']) {
        await tester.pumpWidget(
            badge(color, reducedMotion: true, brightness: brightness));
        await tester.pumpAndSettle();
        expect(find.bySemanticsLabel('通过官方认证'), findsOneWidget);
        expect(tester.binding.transientCallbackCount, 0);
        expect(tester.takeException(), isNull);
        final nameColor =
            tester.widget<Text>(find.text('南京师范大学远程帮助')).style?.color;
        expect(nameColor, const Color(0xfff4e4c1));
        nameColors.add(nameColor);
        iconColors.add(
            tester.widget<Icon>(find.byIcon(Icons.verified_outlined)).color);
      }
      expect(nameColors, hasLength(1));
      expect(iconColors, hasLength(4));
    }
    semantics.dispose();
  });
}
