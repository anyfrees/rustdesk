import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_action_button.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('new action labels stay centered in every state and text scale',
      (tester) async {
    for (final scale in [1.0, 1.6]) {
      for (final label in ['检查更新', '检查中…', '发现新版本', '知道了', '下载并校验', '打开安装包', '打开文件位置']) {
        await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 168,
                  child: NnuActionButton(
                    label: label,
                    onPressed: label == '检查中…' ? null : () {},
                    outlined: true,
                  ),
                ),
              ),
            ),
          ),
        ));
        final button = tester.getRect(find.byType(TextButton));
        final text = tester.getRect(find.text(label));
        expect((text.center - button.center).distance, lessThan(0.5),
            reason: '$label at text scale $scale');
        expect(button.height, greaterThanOrEqualTo(36));
        expect(tester.takeException(), isNull);
      }
    }
  });
}
