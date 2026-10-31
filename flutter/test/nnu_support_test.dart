import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_support.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('first-use notice can be dismissed and support remains clickable',
      (tester) async {
    var showNotice = true;
    var opened = false;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        return Scaffold(
          bottomNavigationBar: NnuSupportFooter(
            showNotice: showNotice,
            onDismissNotice: () => setState(() => showNotice = false),
            onOpenSupport: () => opened = true,
          ),
        );
      }),
    ));
    expect(find.textContaining('首次使用提示'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.textContaining('首次使用提示'), findsNothing);
    await tester.tap(find.text('nnu.cn 提供服务支持'));
    expect(opened, isTrue);
  });

  testWidgets('narrow layout and large text keep notice and support accessible',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(1.6)),
        child: child!,
      ),
      home: Scaffold(
        appBar: AppBar(title: const NnuSupportTitle()),
        bottomNavigationBar: NnuSupportFooter(
          status: const SizedBox(height: 42, child: Text('就绪')),
          showNotice: true,
          onDismissNotice: () {},
          onOpenSupport: () {},
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.text('知道了'), findsOneWidget);
    expect(find.text('nnu.cn 提供服务支持'), findsOneWidget);
    expect(find.byTooltip(nnuSupportTitle), findsOneWidget);
  });
}
