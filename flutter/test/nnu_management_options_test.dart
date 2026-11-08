import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_management_options.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
      'administrator can request protection and optional crash recovery',
      (tester) async {
    final actions = <String>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NnuManagementOptions(
      protected: false,
      recovery: false,
      enabled: true,
      busy: false,
      onAction: actions.add,
    ))));
    expect(
        tester
            .widgetList<Checkbox>(find.byType(Checkbox))
            .every((tile) => tile.value == false),
        isTrue);
    await tester.tap(find.text('退出和卸载时验证 PIN'));
    await tester.tap(find.text('意外退出后自动恢复'));
    expect(actions, ['enable', 'recovery-enable']);
    expect(find.byType(TextButton), findsNothing);
    expect(find.textContaining('独立'), findsNothing);
  });

  testWidgets('locked settings stay disabled and narrow text does not overflow',
      (tester) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var changed = false;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
      child: NnuManagementOptions(
          protected: true,
          recovery: true,
          enabled: false,
          busy: false,
          onAction: (_) => changed = true),
    ))));
    await tester.tap(find.text('退出和卸载时验证 PIN'));
    await tester.tap(find.text('意外退出后自动恢复'));
    expect(changed, isFalse);
    expect(tester.takeException(), isNull);
  });
}
