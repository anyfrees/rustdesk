import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_announcement.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_announcement_style.dart';

void main() {
  test('versioned list supports styles and preserves legacy compatibility', () {
    final data = {
      'schema': 2,
      'interval_seconds': 5,
      'announcements': [
        {
          'id': 'a',
          'title': '公告一',
          'body': '纯文本',
          'theme': 'glass',
          'icon': 'shield',
          'motion': 'breathe',
          'published_at': 123
        },
        {
          'id': 'b',
          'title': '公告二',
          'body': '维护通知',
          'theme': 'future',
          'icon': 'future',
          'motion': 'future',
          'published_at': 123
        },
      ]
    };
    final batch = NnuAnnouncementBatch.parse(jsonEncode(data));
    expect(batch.notices.first.theme, 'glass');
    expect(batch.notices.last.theme, 'clean');
    expect(batch.intervalSeconds, 5);
    expect(
        NnuAnnouncementBatch.parse('{"schema":1,"announcement":null}').notices,
        isEmpty);
    expect(
        () => NnuAnnouncementBatch.parse(
            jsonEncode({...data, 'interval_seconds': 1})),
        throwsFormatException);
  });

  testWidgets('custom titles and icon colors render on all themes',
      (tester) async {
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final theme in nnuNoticeThemes.keys) {
      final notice = NnuAnnouncement.fromJson({
        'id': 'custom',
        'title': '自定义标题',
        'body': '公告正文',
        'published_at': 123,
        'theme': theme,
        'title_font': 'serif',
        'title_size': 18,
        'title_weight': 'bold',
        'title_color': '#26785B',
        'icon_color': '#85510B',
        'icon': 'shield'
      });
      await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
              child: Scaffold(
                  bottomNavigationBar: NnuAnnouncementCarousel(notices: [
                notice,
                NnuAnnouncement('另一条', '正文', id: 'b', theme: theme)
              ])))));
      expect(notice.titleFont, 'serif');
      expect(nnuNoticeTitleStyle(notice, const TextStyle()).fontWeight,
          FontWeight.w700);
      expect(find.byIcon(Icons.verified_user_outlined), findsOneWidget);
      expect(tester.takeException(), isNull, reason: theme);
      await tester.pumpWidget(const SizedBox());
    }
    expect(nnuNoticeColor('#FFFFFF', Colors.blue, Colors.white), Colors.black);
    final fallback = NnuAnnouncement.fromJson({
      'title': '标题',
      'body': '正文',
      'published_at': 1,
      'title_size': 999,
      'title_font': 'future',
      'title_color': 'url(evil)'
    });
    expect(fallback.hasCustomTitle, isFalse);
  });

  testWidgets(
      'carousel keeps the same visible card bounds across contrasting notices',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        bottomNavigationBar: NnuAnnouncementCarousel(notices: [
          NnuAnnouncement('官方防诈提醒', '接受远程协助前请先核对对方身份。',
              id: 'safety', theme: 'obsidian'),
          NnuAnnouncement('友情提示', '请通过邮件反馈问题。', id: 'tip'),
        ]),
      ),
    ));
    final surface = find.descendant(
      of: find.byType(NnuStyledAnnouncement),
      matching: find.byType(Material),
    ).first;
    final first = tester.getRect(surface);
    await tester.tap(find.byTooltip('下一条公告'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.textContaining('友情提示'), findsOneWidget);
    expect(tester.getRect(surface), first);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'all themes rotate multiple notices without narrow layout overflow',
      (tester) async {
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final theme in nnuNoticeThemes.keys) {
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.6)),
              child: child!),
          home: Scaffold(
              bottomNavigationBar: NnuAnnouncementCarousel(
                  key: ValueKey(theme),
                  intervalSeconds: 5,
                  notices: [
                NnuAnnouncement('第一条通知', '核实身份，保留访问认证。', id: 'a', theme: theme),
                NnuAnnouncement('第二条通知', '维护时同一局域网仍可尝试 IP 连接。',
                    id: 'b', theme: theme),
              ]))));
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.textContaining('第二条通知'), findsWidgets, reason: theme);
      expect(tester.takeException(), isNull, reason: theme);
      await tester.tap(find.byTooltip('暂停轮播'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 15));
      expect(find.textContaining('第二条通知'), findsWidgets, reason: theme);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets(
      'full text pauses rotation and reduced motion keeps messages readable',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!),
        home: Scaffold(
            bottomNavigationBar:
                NnuAnnouncementCarousel(intervalSeconds: 5, notices: const [
          NnuAnnouncement('第一条', '原始全文\n保留换行', id: 'a', theme: 'glass'),
          NnuAnnouncement('第二条', '另一条消息', id: 'b', theme: 'titanium'),
        ]))));
    await tester.tap(find.textContaining('原始全文'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 15));
    expect(find.byType(SelectableText), findsOneWidget);
    expect(tester.widget<SelectableText>(find.byType(SelectableText)).data,
        '原始全文\n保留换行');
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下一条公告'));
    await tester.pump();
    expect(find.textContaining('第二条'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
