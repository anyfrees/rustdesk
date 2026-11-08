import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_connection_window_option.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
      'connection window defaults visible and can be hidden and restored',
      (tester) async {
    var visible = true;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StatefulBuilder(
      builder: (context, setState) => NnuConnectionWindowOption(
        showWindow: visible,
        enabled: true,
        passwordOnly: true,
        onChanged: (value) => setState(() => visible = value),
      ),
    ))));
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    await tester.tap(find.text('连接时显示连接管理窗口'));
    await tester.pump();
    expect(visible, isFalse);
    await tester.tap(find.text('连接时显示连接管理窗口'));
    await tester.pump();
    expect(visible, isTrue);
  });

  testWidgets('approval and locked settings cannot hide the connection window',
      (tester) async {
    for (final passwordOnly in [false, true]) {
      var changed = false;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: NnuConnectionWindowOption(
        showWindow: false,
        enabled: false,
        passwordOnly: passwordOnly,
        onChanged: (_) => changed = true,
      ))));
      await tester.tap(find.text('连接时显示连接管理窗口'));
      expect(changed, isFalse);
      if (!passwordOnly) {
        expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
        expect(find.byType(Tooltip), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    }
  });
}
