import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_update_button.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_update_footer.dart';

void main() {
  testWidgets('inline download progress animates toward the measured value',
      (tester) async {
    Widget footer(double progress) => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 150,
              child: NnuUpdateFooter(
                label: '检查更新',
                status: '正在下载',
                progress: progress,
                working: true,
                onPressed: null,
              ),
            ),
          ),
        );
    double? value() => tester
        .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
        .value;

    await tester.pumpWidget(footer(.2));
    expect(value(), .2);
    expect(tester.getRect(find.byType(LinearProgressIndicator)),
        tester.getRect(find.byType(TextButton)));
    await tester.pumpWidget(footer(.8));
    await tester.pump(const Duration(milliseconds: 70));
    expect(value(), allOf(greaterThan(.2), lessThan(.8)));
    expect(find.text('正在下载 80%'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpAndSettle();
    expect(value(), .8);
    await tester.pumpWidget(footer(.9999));
    expect(find.text('正在下载 99%'), findsOneWidget);
    await tester.pumpWidget(footer(1));
    expect(find.text('正在下载 100%'), findsOneWidget);
  });

  testWidgets(
      'narrow footer keeps only a centered update button at large text scales',
      (tester) async {
    for (final scale in [1.0, 1.5, 2.0]) {
      await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
            body: Center(
                child: SizedBox(
          width: 150,
          child: NnuUpdateButton(
              installed: true,
              installedPackageName: () => 'client.msi',
              hasActiveSession: () => false),
        ))),
      )));
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.text('自动下载并安装'), findsNothing);
      final button = tester.getRect(find.byType(TextButton));
      final label = tester.getRect(find.text('检查更新'));
      expect((button.center - label.center).distance, lessThan(0.5));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
