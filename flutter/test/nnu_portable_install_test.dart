import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_portable_install.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const description =
      '你正在运行未安装版本，由于 UAC 限制，作为被控端，会在某些情况下无法控制鼠标键盘，或者录制屏幕，请点击下面的按钮将 RustDesk 安装到系统，从而规避上述问题。';

  testWidgets(
      'installation notice moves below the connection card at narrow widths',
      (tester) async {
    for (final (width, scale) in [(900.0, 1.0), (640.0, 1.0), (580.0, 1.0), (493.0, 1.0), (320.0, 1.0), (900.0, 2.0), (320.0, 2.0)]) {
      await tester.binding.setSurfaceSize(Size(width, 1000));
      await tester.pumpWidget(MaterialApp(
        key: ValueKey((width, scale)),
          builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
          home: Scaffold(
              body: NnuInstallPlacement(
        connection: const SizedBox(key: Key('connection'), height: 190),
        notice: NnuPortableInstallCard(
            description: description,
            installLabel: '安装',
            install: () async => 'installed'),
      ))));
      final connection = tester.getRect(find.byKey(const Key('connection')));
      final notice = tester.getRect(find.byType(NnuPortableInstallCard));
      if (width >= 480 * scale) {
        expect(notice.left, greaterThanOrEqualTo(connection.right));
      } else {
        expect(notice.top, greaterThanOrEqualTo(connection.bottom));
      }
      expect(notice.right, lessThanOrEqualTo(width));
      expect(tester.takeException(), isNull);
    }
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Win10 default pane keeps the first device below the toolbar visible',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(493, 430));
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: NnuPortableConnectionBody(
        connection: const SizedBox(height: 172, child: Text('控制远程桌面')),
        notice: NnuPortableInstallCard(description: description,
          installLabel: '安装', install: () async => 'failed'),
        peers: const Column(children: [
          SizedBox(height: 48, child: Text('会话工具栏')),
          SizedBox(key: Key('first-device'), height: 100, child: Text('最近设备')),
        ]),
      ),
    )));
    expect(tester.getRect(find.byKey(const Key('first-device'))).bottom,
        lessThanOrEqualTo(430));
    expect(tester.getRect(find.widgetWithText(OutlinedButton, '安装')).bottom,
        lessThanOrEqualTo(250));
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('default portable window shows the entire install card and small windows can scroll',
      (tester) async {
    for (final (width, height, scale) in [
      (600.0, 430.0, 1.0),
      (800.0, 500.0, 1.0),
      (500.0, 430.0, 1.0),
      (320.0, 240.0, 2.0),
      (600.0, 300.0, 1.5),
    ]) {
      await tester.binding.setSurfaceSize(Size(width, height));
      await tester.pumpWidget(MaterialApp(
        key: ValueKey((width, height, scale)),
        theme: ThemeData(outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(backgroundColor: Colors.grey.shade200))),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
        home: Scaffold(body: NnuPortableConnectionBody(
          connection: const SizedBox(height: 190, child: Text('连接')),
          notice: NnuPortableInstallCard(description: description,
            installLabel: '安装', install: () async => 'failed'),
          peers: const Column(children: [
            SizedBox(height: 80, child: Text('会话工具栏')),
            Expanded(child: Center(child: Text('最近会话'))),
          ]),
        )),
      ));
      final button = find.widgetWithText(OutlinedButton, '安装', skipOffstage: false);
      if (width == 600 && scale == 1) {
        expect(tester.getRect(button).bottom, lessThanOrEqualTo(height));
        expect(tester.getRect(find.byType(NnuPortableInstallCard)).bottom,
            lessThanOrEqualTo(height));
      }
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      expect(tester.getRect(button).bottom, lessThanOrEqualTo(height));
      expect(tester.getRect(button).left, greaterThanOrEqualTo(0));
      expect(tester.getRect(button).right, lessThanOrEqualTo(width));
      final widget = tester.widget<OutlinedButton>(button);
      expect(widget.style!.backgroundColor!.resolve({}), Colors.transparent);
      expect(widget.onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    }
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets(
      'silent installation blocks duplicate clicks and permits retry after failure',
      (tester) async {
    var calls = 0;
    var result = Completer<String>();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
      width: 300,
      child: NnuPortableInstallCard(
          description: description,
          installLabel: '安装',
          install: () {
            calls++;
            return result.future;
          }),
    ))));
    await tester.tap(find.text('安装'));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.tap(find.text('正在安装…'));
    expect(calls, 1);
    result.complete('failed');
    await tester.pumpAndSettle();
    expect(find.text('安装未完成或已取消授权，请重试。'), findsOneWidget);
    result = Completer<String>();
    await tester.tap(find.text('安装'));
    result.complete('installed');
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text(description), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
