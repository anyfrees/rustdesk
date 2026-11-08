import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_support.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the actual desktop title shows the published product name', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox(
        width: 300, child: NnuSupportTitle()))));
    expect(find.text('RustDesk VIP支持专业版'), findsOneWidget);
    expect(find.byTooltip('RustDesk VIP支持专业版'), findsOneWidget);
    expect(find.text('VIP技术支持定制版本'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
