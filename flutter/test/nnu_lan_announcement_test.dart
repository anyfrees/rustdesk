import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_lan_card.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_announcement.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
      'announcement preview has one ordinary space between title and body',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            bottomNavigationBar: NnuAnnouncementBar(
                notice: NnuAnnouncement(
                    '  nnu.cn提醒您：　 ', '　 接受远程协助前\n  请先确认对方身份。  ')))));
    expect(find.text('nnu.cn提醒您： 接受远程协助前 请先确认对方身份。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('active LAN card only shows addresses, without redundant labels',
      (tester) async {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: const Scaffold(
              body: SizedBox(
                  width: 200,
                  child: MediaQuery(
                      data: MediaQueryData(textScaler: TextScaler.linear(1.6)),
                      child: NnuLanCard(
                          enabled: true,
                          addresses: ['172.17.12.7', '10.10.10.100']))))));
      expect(find.text('局域网连接'), findsOneWidget);
      expect(find.text('172.17.12.7'), findsOneWidget);
      expect(find.text('10.10.10.100'), findsOneWidget);
      expect(find.textContaining('仍需访问验证'), findsNothing);
      expect(find.textContaining('对方输入'), findsNothing);
      expect(find.textContaining('暂未连接服务器'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  test('default port omits suffix and custom port remains explicit', () {
    expect(nnuLanEndpoint('192.168.1.20', 21118), '192.168.1.20');
    expect(nnuLanEndpoint('192.168.1.20', 32100), '192.168.1.20:32100');
    expect(NnuAnnouncement.parse('{"schema":1,"announcement":null}'), isNull);
    expect(
        () => NnuAnnouncement.parse(
            '{"schema":1,"announcement":{"title":"draft","body":"text"}}'),
        throwsFormatException);
  });

  testWidgets(
      'LAN card wraps addresses at sidebar width and respects stopped state',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                    width: 200,
                    child: MediaQuery(
                        data: const MediaQueryData(
                            textScaler: TextScaler.linear(1.6)),
                        child: const NnuLanCard(
                            enabled: true,
                            stopped: true,
                            port: 32100,
                            addresses: [
                              '192.168.100.200',
                              '10.20.30.40'
                            ])))))));
    expect(find.text('192.168.100.200:32100'), findsNothing);
    expect(find.text('服务已停止，暂不可连接'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'empty bar collapses and long announcement opens selectable full text',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Widget page(NnuAnnouncement? notice) => MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!),
        home:
            Scaffold(bottomNavigationBar: NnuAnnouncementBar(notice: notice)));
    await tester.pumpWidget(page(null));
    expect(tester.getSize(find.byType(NnuAnnouncementBar)).height, 0);
    final body = '<b>纯文本</b>\n${'维护通知。' * 300}';
    await tester.pumpWidget(page(NnuAnnouncement('管理员公告', body)));
    await tester.tap(find.byIcon(Icons.campaign_outlined));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });
}
