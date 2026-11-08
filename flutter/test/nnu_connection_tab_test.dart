import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_connection_tab.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_test/flutter_test.dart';

class _UnusedSession implements FFI {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  QualityMonitorModel monitor() =>
      QualityMonitorModel(WeakReference<FFI>(_UnusedSession()));

  Widget tab(QualityMonitorModel quality,
          {bool direct = true,
          String id = '1069705511',
          double width = 800,
          double scale = 1,
          bool chinese = false,
          Brightness brightness = Brightness.light}) =>
      MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: MediaQuery(
          data: MediaQueryData(
              size: Size(width, 600), textScaler: TextScaler.linear(scale)),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                height: 28,
                child: NnuConnectionTab(
                  remoteId: id,
                  deviceName: '家跳板机@desktop-q597s7v',
                  direct: direct,
                  routeLabel: nnuConnectionRouteLabel(chinese
                      ? (direct ? '直接连接' : '中继连接')
                      : (direct ? 'Direct connection' : 'Relay connection')),
                  delayLabel: chinese ? '延迟' : 'Latency',
                  networkLabel: chinese ? '网络状态' : 'Network status',
                  unmeasuredLabel: chinese ? '待测量' : 'Measuring…',
                  qualityLabels: chinese
                      ? const ['极佳', '优秀', '良好', '一般', '较差', '极差']
                      : const [
                          'Exceptional',
                          'Excellent',
                          'Good',
                          'Fair',
                          'Poor',
                          'Very poor'
                        ],
                  connectionDetails:
                      'Encrypted connection\nFingerprint: fixture',
                  quality: quality,
                  leading: const Padding(
                    padding: EdgeInsets.only(right: 5),
                    child: Icon(Icons.desktop_windows_outlined, size: 18),
                  ),
                  securityIcon: const Padding(
                    padding: EdgeInsets.only(right: 5),
                    child: Icon(Icons.verified_user_outlined, size: 18),
                  ),
                  trailing: const SizedBox(width: 4),
                ),
              ),
            ),
          ),
        ),
      );

  testWidgets('title uses measured delay while quality overlay is hidden',
      (tester) async {
    final quality = monitor();
    await tester.pumpWidget(tab(quality));
    expect(quality.show, isFalse);
    expect(find.text('1069705511'), findsOneWidget);
    expect(find.text('— ms', findRichText: true), findsOneWidget);
    expect(
        tester.widgetList<Tooltip>(find.byType(Tooltip)).any(
            (t) => t.message?.contains('Network status: Measuring…') == true),
        isTrue);
    quality.updateQualityStatus({'delay': '0'});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('<1 ms', findRichText: true), findsOneWidget);
    final subMillisecondColor = DefaultTextStyle.of(
            tester.element(find.text('<1 ms', findRichText: true)))
        .style
        .color;
    quality.updateQualityStatus({'delay': '18'});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('18 ms', findRichText: true), findsOneWidget);
    Color? delayColor(String text) =>
        DefaultTextStyle.of(tester.element(find.text(text, findRichText: true)))
            .style
            .color;
    final low = delayColor('18 ms');
    expect(subMillisecondColor, low);
    quality.updateQualityStatus({'delay': '146', 'fps': '{}'});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('146 ms', findRichText: true), findsOneWidget);
    final medium = delayColor('146 ms');
    expect(medium, isNot(low));
    quality.updateQualityStatus({'delay': '181'});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(delayColor('181 ms'), isNot(anyOf(low, medium)));
    quality.resetDelay();
    await tester.pump();
    expect(find.text('— ms', findRichText: true), findsOneWidget);
    expect(find.text('181 ms', findRichText: true), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    quality.dispose();
  });

  testWidgets('route changes and device name stays in hover details',
      (tester) async {
    final quality = monitor()..updateQualityStatus({'delay': '46'});
    await tester.pumpWidget(tab(quality));
    final directColor = tester.widget<Text>(find.text('Direct')).style!.color;
    await tester.pumpWidget(tab(quality, direct: false));
    expect(find.text('Direct'), findsNothing);
    expect(find.text('Relay'), findsOneWidget);
    expect(tester.widget<Text>(find.text('Relay')).style!.color,
        isNot(directColor));
    expect(find.text('家跳板机@desktop-q597s7v'), findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(600, 200));
    await mouse.moveTo(tester.getCenter(find.text('1069705511')));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('家跳板机@desktop-q597s7v'), findsOneWidget);
    await mouse.removePointer();
    await tester.pumpWidget(tab(quality, chinese: true));
    for (final sample in const {
      0: '极佳',
      20: '极佳',
      21: '优秀',
      50: '优秀',
      51: '良好',
      80: '良好',
      81: '一般',
      120: '一般',
      121: '较差',
      180: '较差',
      181: '极差',
    }.entries) {
      quality.updateQualityStatus({'delay': '${sample.key}'});
      await tester.pump();
      final details = tester
          .widgetList<Tooltip>(find.byType(Tooltip))
          .firstWhere(
              (t) => t.message?.contains('Fingerprint: fixture') == true)
          .message!;
      expect(
          details, contains('延迟: ${sample.key == 0 ? '<1' : sample.key} ms'));
      expect(details, contains('网络状态: ${sample.value}'));
      expect(details, isNot(contains('Delay:')));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    quality.dispose();
  });

  testWidgets('long IDs fit title bars at narrow widths and large text sizes',
      (tester) async {
    final quality = monitor()..updateQualityStatus({'delay': '9999'});
    for (final width in [320.0, 800.0, 1920.0]) {
      for (final scale in [1.0, 1.5, 2.0]) {
        for (final brightness in [Brightness.light, Brightness.dark]) {
          await tester.pumpWidget(tab(quality,
              width: width,
              scale: scale,
              brightness: brightness,
              id: 'long-custom-device-id@custom-server'));
          expect(tester.takeException(), isNull,
              reason: '$width width, $scale text scale, $brightness');
          final bounds = tester.getRect(find.byType(NnuConnectionTab));
          expect(bounds.width, lessThanOrEqualTo(width));
          expect(bounds.height, lessThanOrEqualTo(28));
          expect(find.text('9999 ms', findRichText: true), findsOneWidget);
        }
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
    quality.dispose();
  });
}
